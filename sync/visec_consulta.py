# -*- coding: utf-8 -*-
"""
visec_consulta.py — Caravanas Pecuaria
Consulta el estado VISEC (https://carne.visec.com.ar) de las caravanas electrónicas del padrón (activas y
salidas) que todavía no lo tienen. Corre todo el día en la PC de la oficina (tarea cada hora, ver INSTALAR_TAREAS.bat).

Flujo (el mismo que se hace a mano en la página, pero con varios lotes a la vez en pestañas distintas):
  1. Pide a Supabase las caravanas pendientes (visec_pendientes): primero las pedidas desde el portal,
     después los machos de PEGSA/BULLTRADE, después el resto.
  2. Entra a VISEC con VISEC_USUARIO / VISEC_CLAVE (sync\\.env). Abre VISEC_PARALELO pestañas y en cada una
     arma un lote (Mis informes > Agregar, descripción "consulta", pega las caravanas, Guardar) y aprieta
     "Ejecutar proceso de validación".
  3. Espera a que cada lote quede FINALIZADO (~1 minuto por caravana, los lotes corren en paralelo).
     Si en el lote figura "ERROR: NO SE PUDO LEER EL CUIT EN ARCA" para un RENSPA, las caravanas que
     VISEC inhabilitó por ese RENSPA quedan como "ERROR ARCA" (no es un resultado real). No se reconsultan
     solas: cuando el RENSPA se arregle, borrar esas filas de visec_consultas y el robot las vuelve a tomar.
  4. Lee en la lupa del lote el estado y la observación de cada caravana (HABILITADA / INHABILITADA /
     NÚMERO INEXISTENTE / ...), lo guarda en Supabase (visec_guardar) y descarta el lote en VISEC.
  5. Apenas termina un lote, en esa misma pestaña arma el siguiente: no hay tiempo ocioso. Sigue hasta que
     no queden pendientes (o hasta VISEC_MAX_MIN si se fija). La tarea de Windows de cada hora solo lo
     vuelve a lanzar si no está corriendo (archivo de bloqueo); así también toma las altas nuevas del padrón
     y las consultas pedidas desde el portal.

Variables en sync\\.env:
  VISEC_USUARIO, VISEC_CLAVE          usuario y clave de VISEC
  VISEC_USUARIO2, VISEC_CLAVE2        segundo usuario (opcional; cada usuario tiene su cola en VISEC: el doble de velocidad)
  VISEC_LOTE=15                       caravanas por lote (opcional; 15 entran en una página de la lupa)
  VISEC_PARALELO=1                    lotes (pestañas) a la vez (opcional; VISEC encola por usuario, con 1 va mejor)
  VISEC_MAX_MIN=0                     minutos máximos por corrida (0 = hasta terminar; la tarea de cada hora lo relanza si murió)
  VISEC_REINTENTOS=2                  reconsultas (otros días) de las que quedaron ERROR ARCA (opcional; lo aplica Supabase)
  VISEC_VISIBLE=0                     poner 1 para ver el navegador (para probar)

Requiere Playwright: correr una vez sync\\INSTALAR_VISEC.bat.
"""
import json
import logging
import os
import re
import sys
import time
from datetime import datetime
from pathlib import Path

import requests
from dotenv import load_dotenv

AQUI = Path(__file__).resolve().parent
load_dotenv(AQUI / ".env")
SB_URL = os.environ.get("SUPABASE_URL", "").rstrip("/")
SB_KEY = os.environ.get("SUPABASE_SERVICE_KEY", "")
VISEC_URL = "https://carne.visec.com.ar"
def _cuentas():
    """Usuarios de VISEC del .env: VISEC_USUARIO/VISEC_CLAVE, VISEC_USUARIO2/VISEC_CLAVE2, VISEC_USUARIO3/... (cada
    usuario tiene su propia cola en VISEC, así que con dos usuarios se consulta el doble)."""
    cs = []
    for suf in ["", "2", "3", "4", "5"]:
        u = os.environ.get("VISEC_USUARIO" + suf, "").strip(); c = os.environ.get("VISEC_CLAVE" + suf, "").strip()
        if u and c:
            cs.append({"usuario": u, "clave": c})
    return cs
CUENTAS = _cuentas()
LOTE = int(os.environ.get("VISEC_LOTE", "15"))      # 15 = una sola página en la lupa de VISEC (un compañero consulta de a 15/20 a mano y le anda)
PARALELO = max(1, int(os.environ.get("VISEC_PARALELO", "1")))   # VISEC parece procesar un lote por usuario a la vez: más pestañas solo hacen cola
MAX_MIN = int(os.environ.get("VISEC_MAX_MIN", "0"))   # 0 = sin límite
REINTENTOS = int(os.environ.get("VISEC_REINTENTOS", "2"))
VISIBLE = os.environ.get("VISEC_VISIBLE", "0") == "1"
SIN_AVANCE_MIN = 60            # si VISEC no muestra avance en el lote durante este tiempo, se da por colgado
TOPE_LOTE_H = 6                # tope absoluto de espera por lote
LOCK = AQUI / "visec_consulta.lock"
STOP = AQUI / "visec_consulta.stop"   # si existe, el robot termina los lotes abiertos y sale (DETENER_VISEC.bat)
MI_MTIME = Path(__file__).stat().st_mtime   # si se reemplaza este archivo, el robot termina lo abierto y sale (se relanza solo)
ERROR_ARCA = "ERROR ARCA"

log = logging.getLogger("visec")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
                    handlers=[logging.StreamHandler(sys.stdout), logging.FileHandler(AQUI / "visec_consulta.log", encoding="utf-8")])


# ───────────────────────── Supabase ─────────────────────────
class Supa:
    def __init__(self):
        if not SB_URL or not SB_KEY:
            raise SystemExit("Faltan SUPABASE_URL / SUPABASE_SERVICE_KEY en sync\\.env")
        self.h = {"apikey": SB_KEY, "Authorization": "Bearer " + SB_KEY, "Content-Type": "application/json"}

    def rpc(self, fn, args=None):
        r = requests.post(f"{SB_URL}/rest/v1/rpc/{fn}", headers=self.h, data=json.dumps(args or {}), timeout=120)
        if r.status_code >= 300:
            raise RuntimeError(f"rpc {fn}: HTTP {r.status_code} {r.text[:300]}")
        return r.json() if r.text else None

    def insert(self, tabla, datos):
        r = requests.post(f"{SB_URL}/rest/v1/{tabla}", headers={**self.h, "Prefer": "return=representation"}, data=json.dumps(datos), timeout=60)
        if r.status_code >= 300:
            raise RuntimeError(f"insert {tabla}: HTTP {r.status_code} {r.text[:300]}")
        return r.json()[0]

    def patch(self, tabla, query, datos):
        r = requests.patch(f"{SB_URL}/rest/v1/{tabla}?{query}", headers={**self.h, "Prefer": "return=minimal"}, data=json.dumps(datos), timeout=60)
        if r.status_code >= 300:
            raise RuntimeError(f"patch {tabla}: HTTP {r.status_code} {r.text[:300]}")


# ───────────────────────── Bloqueo (una corrida a la vez) ─────────────────────────
def _proceso_vivo(pid):
    """¿Sigue corriendo el proceso que dejó el bloqueo? (Windows: tasklist)"""
    try:
        import subprocess
        out = subprocess.run(["tasklist", "/FI", f"PID eq {pid}", "/NH"], capture_output=True, text=True, timeout=20).stdout
        return str(pid) in out and "python" in out.lower()
    except Exception:
        return True   # ante la duda, asumimos que sí


def tomar_bloqueo():
    if LOCK.exists():
        edad_min = (time.time() - LOCK.stat().st_mtime) / 60   # el robot lo toca cada vuelta
        try:
            pid = int(LOCK.read_text().strip() or 0)
        except ValueError:
            pid = 0
        if edad_min < 20 and pid and _proceso_vivo(pid):
            log.info("Ya hay una corrida VISEC en curso (proceso %d, bloqueo de hace %.0f min); salgo", pid, edad_min)
            return False
        log.warning("Bloqueo viejo o de un proceso que ya no existe (pid %s, hace %.0f min); lo piso", pid, edad_min)
    LOCK.write_text(str(os.getpid()))
    return True


def soltar_bloqueo():
    try:
        LOCK.unlink()
    except OSError:
        pass


# ───────────────────────── VISEC (navegador) ─────────────────────────
def texto(page):
    try:
        return page.locator("body").inner_text(timeout=15000)
    except Exception:
        return ""


def esperar_blazor(page, seg=30):
    """Blazor Server tarda en conectar; espera a que desaparezcan los spinners y haya contenido."""
    try:
        page.wait_for_load_state("networkidle", timeout=seg * 1000)
    except Exception:
        pass
    fin = time.time() + seg
    while time.time() < fin:
        if page.locator("[class*=spin]:visible").count() == 0 and texto(page).strip():
            return
        time.sleep(1)


def logueado(page):
    return page.locator("#logout").count() > 0 or "Mis informes" in texto(page)


def _describir_formulario(page):
    """Para el log: qué campos y botones hay en la pantalla (sirve para ajustar el robot si VISEC cambia)."""
    try:
        return page.evaluate("""() => [...document.querySelectorAll('input,button,a')]
            .filter(e => e.offsetParent && !/goog/.test(e.id))
            .map(e => e.tagName.toLowerCase() + '[' + (e.type||'') + (e.id ? ' #'+e.id : '') + (e.name ? ' name='+e.name : '')
                      + (e.placeholder ? ' ph='+e.placeholder : '') + ']' + (e.textContent||'').trim().slice(0,25))
            .slice(0, 40).join(' ; ')""")
    except Exception as e:
        return f"(no pude leer el formulario: {e})"


def login(page, cuenta):
    USUARIO, CLAVE = cuenta["usuario"], cuenta["clave"]
    page.goto(VISEC_URL + "/", wait_until="networkidle")
    esperar_blazor(page, 40)
    if logueado(page):
        log.info("Sesión VISEC ya iniciada (%s)", USUARIO); return
    log.info("Pantalla de ingreso (%s): %s", page.url, _describir_formulario(page))
    try:
        page.screenshot(path=str(AQUI / "visec_login_1.png"))
    except Exception:
        pass
    # Si hay un botón/enlace de "Ingresar" antes del formulario, apretarlo
    if page.locator("input[type=password]").count() == 0:
        ent = page.locator("a:has-text('Ingres'), button:has-text('Ingres'), a:has-text('Iniciar'), button:has-text('Iniciar'), a:has-text('Login'), a:has-text('Acceder')").first
        if ent.count():
            ent.click(); page.wait_for_timeout(2000); esperar_blazor(page, 30)
    pwd = page.locator("input[type=password]").first
    pwd.wait_for(timeout=30000)
    # usuario: el campo de texto/email visible que está antes de la clave
    user = page.locator("input[type=email]:visible, input[type=text]:visible, input:not([type]):visible").first
    user.click(); user.fill(USUARIO)
    pwd.click(); pwd.fill(CLAVE)
    boton = page.locator("button[type=submit]:visible, button:has-text('Ingresar'), button:has-text('Iniciar'), button:has-text('Entrar'), button:has-text('Acceder'), input[type=submit]").first
    if boton.count():
        boton.click()
    else:
        pwd.press("Enter")
    fin = time.time() + 90
    while time.time() < fin:
        page.wait_for_timeout(2000)
        if logueado(page):
            log.info("Sesión VISEC iniciada (%s)", USUARIO); return
    try:
        page.screenshot(path=str(AQUI / "visec_login_2.png"))
    except Exception:
        pass
    log.error("Después de enviar el formulario (%s): %s | texto: %s", page.url, _describir_formulario(page), texto(page).strip().replace("\n", " / ")[:300])
    raise RuntimeError("No se pudo iniciar sesión en VISEC (revisar usuario/clave o si la pantalla cambió; ver visec_login_1.png y visec_login_2.png)")


def abrir_lote(page, informe):
    page.goto(f"{VISEC_URL}/App/LotesConsultas/{informe}", wait_until="networkidle")
    esperar_blazor(page, 60)
    # la pantalla del lote tarda en aparecer (Blazor arma el circuito)
    page.locator("button:has-text('Descartar lote')").first.wait_for(timeout=90000)


def crear_lote(page, numeros):
    page.goto(VISEC_URL + "/App/LotesConsultas/0", wait_until="networkidle")
    esperar_blazor(page, 40)
    page.locator("textarea").first.wait_for(timeout=60000)
    # Descripción: el primer input que sigue a la etiqueta "Descripción" (el buscador del encabezado y el
    # campo de DTE también son input[type=text], por eso no se puede tomar "el primero")
    desc = page.locator("label:has-text('Descripci')").first.locator("xpath=following::input[@type='text'][1]")
    if desc.count() == 0 or not desc.first.is_visible():
        desc = page.locator("input[type=text]:visible:not([placeholder])").first
    desc.click(); desc.fill("consulta")
    ta = page.locator("textarea").first
    ta.click(); ta.fill("\n".join(numeros))
    page.locator("button:has-text('Guardar')").first.click()
    page.wait_for_timeout(2000)
    fin = time.time() + 150          # VISEC a veces tarda más de un minuto en responder al Guardar
    while time.time() < fin:
        m = re.search(r"/App/LotesConsultas/(\d+)", page.url)
        if m and m.group(1) != "0":
            if "Registro guardado" in texto(page) or time.time() > fin - 120:
                return m.group(1)
        time.sleep(2)
    raise RuntimeError("No se pudo guardar el lote (no apareció 'Registro guardado con éxito'): " + texto(page).strip().replace("\n", " / ")[:200])


def ejecutar_validacion(page):
    page.locator("button:has-text('Ejecutar proceso de validación')").first.click()


def estado_lote(page, w):
    """Mira la pantalla del lote: devuelve 'finalizado', 'validando' o 'caido' (circuito Blazor cortado)."""
    txt = texto(page)
    m = re.findall(r"\d{2}:\d{2}:\d{2} - [^\n]+", txt)
    if m and m[-1] != w.get("ultimo"):
        w["ultimo"] = m[-1]; w["ultimo_avance"] = time.time(); log.info("  [%s] %s", w["informe"], m[-1])
    me = re.search(r"ESTADO\s*\n\s*([A-ZÁÉÍÓÚ ]+)", txt)
    if me and me.group(1).strip() != w.get("estado_visec"):
        w["estado_visec"] = me.group(1).strip(); w["ultimo_avance"] = time.time()
        log.info("  [%s] Estado VISEC: %s", w["informe"], w["estado_visec"])
    if re.search(r"ESTADO\s*\n\s*FINALIZADO", txt) and page.locator("[class*=spin]:visible").count() == 0:
        return "finalizado"
    if ("reload" in txt.lower() and "blazor" in txt.lower()) or "Attempting to reconnect" in txt or "Could not reconnect" in txt:
        return "caido"
    return "validando"


def renspas_con_error(page):
    """RENSPAs cuya columna 'CUIT ESTADO' dice ERROR (p. ej. 'NO SE PUDO LEER EL CUIT EN ARCA')."""
    errores = set()
    for tabla in page.locator("table").all():
        try:
            head = tabla.locator("th").all_inner_texts()
        except Exception:
            continue
        if not any("RENSPA" in h.upper() for h in head):
            continue
        for tr in tabla.locator("tbody tr").all():
            celdas = [c.inner_text().strip() for c in tr.locator("td").all()]
            if len(celdas) >= 4 and "ERROR" in celdas[3].upper():
                errores.add(celdas[0])
        break
    return errores


def _siguiente_pagina(cont):
    """Paginador (botones numerados o ul.pagination): aprieta el número siguiente al activo. True si pasó de página."""
    activa = cont.locator(".btn-group button.active, .btn-group .active, ul.pagination li.active, .pagination .active").first
    if activa.count() == 0:
        return False
    try:
        n_act = int(activa.inner_text().strip())
    except ValueError:
        return False
    sig = cont.locator(f".btn-group button:text-is('{n_act + 1}'), ul.pagination li:not(.active) >> text='{n_act + 1}', .pagination >> text='{n_act + 1}'").first
    if sig.count() == 0:
        return False
    sig.click()
    return True


def leer_resultados(page, informe, esperados):
    """Abre la lupa del lote y lee CARAVANA / ESTADO / OBSERVACIONES (paginado)."""
    filas = {}
    try:
        page.locator("label.form-label a:has(i.bx-search-alt), label a:has(i[class*=search])").first.click()
        modal = page.locator(".modal.show, .modal[style*='block']").first
        modal.wait_for(timeout=60000)
        modal.locator("table tbody tr").first.wait_for(timeout=90000)
        for _ in range(500):
            for tr in modal.locator("table tbody tr").all():
                celdas = [c.inner_text().strip() for c in tr.locator("td").all()]
                if len(celdas) >= 2 and re.match(r"^032\d{12}$", celdas[0]):
                    est = celdas[1].upper().replace("NUMERO", "NÚMERO").replace("VALIDACION", "VALIDACIÓN")
                    obs = celdas[2] if len(celdas) > 2 and celdas[2] else None
                    filas[celdas[0]] = {"caravana": celdas[0], "estado": est, "observacion": obs}
            if not _siguiente_pagina(modal):
                break
            page.wait_for_timeout(1500)
    except Exception as e:
        log.warning("  [%s] No pude leer la lupa (%s); leo el listado", informe, e)
    if len(filas) < len(esperados):
        filas.update(leer_listado(page, informe))
    faltan = [n for n in esperados if n not in filas]
    if faltan:
        log.warning("  [%s] %d caravanas del lote no aparecen en el resultado (quedan pendientes): %s…", informe, len(faltan), ", ".join(faltan[:5]))
    return list(filas.values())


def leer_listado(page, informe):
    """Plan B: pantalla Caravanas del informe (NÚMERO / ESPECIE / ESTADO, sin observaciones)."""
    filas = {}
    try:
        page.goto(f"{VISEC_URL}/App/LotesConsultas/Caravanas/{informe}", wait_until="networkidle")
        esperar_blazor(page, 60)
        page.locator("table tbody tr").first.wait_for(timeout=120000)
        for _ in range(500):
            for tr in page.locator("table tbody tr").all():
                celdas = [c.inner_text().strip() for c in tr.locator("td").all()]
                if len(celdas) >= 3 and re.match(r"^032\d{12}$", celdas[0]):
                    est = celdas[2].upper().replace("NUMERO", "NÚMERO").replace("VALIDACION", "VALIDACIÓN")
                    filas[celdas[0]] = {"caravana": celdas[0], "estado": est, "observacion": None}
            if not _siguiente_pagina(page):
                break
            page.wait_for_timeout(1500); esperar_blazor(page, 30)
    except Exception as e:
        log.warning("  [%s] Tampoco pude leer el listado: %s", informe, e)
    return filas


def descartar_lote(page, informe):
    try:
        abrir_lote(page, informe)
        page.locator("button:has-text('Descartar lote')").first.click()
        page.wait_for_timeout(1000)
        conf = page.locator(".modal.show button:has-text('Confirmar'), button:has-text('Confirmar')").first
        if conf.count():
            conf.click(); page.wait_for_timeout(2000)
        log.info("  [%s] Lote descartado", informe)
    except Exception as e:  # no es grave: el informe queda en VISEC
        log.warning("  [%s] No se pudo descartar el lote: %s", informe, e)


def informar_cola(ctx, usuario=""):
    """Diagnóstico: cuántos informes de este usuario hay en cada estado en VISEC (Mis informes, primera página).
    Sirve para ver si quedaron lotes EN PROCESO / EN ESPERA haciendo cola (por ejemplo lotes descartados a medio validar)."""
    pg = ctx.new_page(); pg.set_default_timeout(60000)
    try:
        pg.goto(VISEC_URL + "/App/LotesConsultas", wait_until="networkidle"); esperar_blazor(pg, 60)
        pg.locator("table tbody tr").first.wait_for(timeout=90000)
        filas = []
        for tr in pg.locator("table tbody tr").all():
            c = [x.inner_text().strip() for x in tr.locator("td").all()]
            if len(c) >= 4 and c[0].isdigit():
                filas.append((c[0], c[3].upper(), c[5] if len(c) > 5 else ""))
        cuenta = {}
        for _, est, _ in filas:
            cuenta[est] = cuenta.get(est, 0) + 1
        abiertos = [f"{i} ({e}, {n})" for i, e, n in filas if e not in ("FINALIZADO", "DESCARTADO")]
        log.info("Mis informes en VISEC de %s (1ª página, %d): %s%s", usuario, len(filas), ", ".join(f"{k}={v}" for k, v in sorted(cuenta.items())),
                 (" | sin terminar: " + ", ".join(abiertos)) if abiertos else "")
        return filas
    except Exception as e:
        log.warning("No pude leer Mis informes: %s", e)
        return []
    finally:
        try:
            pg.close()
        except Exception:
            pass


def limpiar_huerfanos(ctx, sb, filas, propios):
    """Lotes de este usuario que quedaron EN PROCESO / EN ESPERA de corridas anteriores (cortadas a mano o caídas).
    VISEC procesa los lotes de un usuario uno detrás de otro, así que estos ocupan la cola delante de los nuevos:
    se les lee lo que tengan, se guarda, y se descartan."""
    huerfanos = [i for i, e, _ in filas if e not in ("FINALIZADO", "DESCARTADO") and i not in propios]
    if not huerfanos:
        return
    log.warning("Hay %d lotes viejos sin terminar en la cola de VISEC (%s): los leo y descarto para liberar la cola",
                len(huerfanos), ", ".join(huerfanos))
    for informe in huerfanos:
        pg = ctx.new_page(); pg.set_default_timeout(60000)
        try:
            abrir_lote(pg, informe)
            filas_l = leer_resultados(pg, informe, [])
            if filas_l:
                n = sb.rpc("visec_guardar", {"p_filas": filas_l, "p_informe": informe}) or 0
                log.info("  [%s] (viejo) guardados %d resultados", informe, n)
        except Exception as e:
            log.warning("  [%s] (viejo) no pude leer los resultados: %s", informe, e)
        descartar_lote(pg, informe)
        try:
            pg.close()
        except Exception:
            pass


# ───────────────────────── Lotes en paralelo, sin tiempo ocioso ─────────────────────────
def nuevo_lote(cuenta, sb, en_curso):
    """Pide pendientes (sin las que ya están en algún lote abierto) y arma un lote en una pestaña nueva del usuario."""
    ctx = cuenta["ctx"]
    pend = sb.rpc("visec_pendientes", {"p_max": LOTE * (PARALELO * len(CUENTAS) + 1)}) or []
    nums = [n for n in pend if n not in en_curso][:LOTE]
    if not nums:
        return None
    page = None
    try:
        page = ctx.new_page(); page.set_default_timeout(60000)
        informe = crear_lote(page, nums)
        abrir_lote(page, informe)
        ejecutar_validacion(page)
        log.info("  [%s] Lote de %d caravanas guardado (%s); validando", informe, len(nums), cuenta["usuario"])
        return {"page": page, "informe": informe, "nums": nums, "fin": None, "cuenta": cuenta,
                "ultimo_avance": time.time(), "tope": time.time() + TOPE_LOTE_H * 3600}
    except Exception as e:
        log.error("  No pude armar un lote (%s); esas %d caravanas quedan para más adelante", e, len(nums))
        if page is not None and not re.search(r"crashed|closed|disconnected", str(e), re.I):
            try:
                if not logueado(page):
                    log.warning("La sesión VISEC de %s se cerró; vuelvo a entrar", cuenta["usuario"])
                    login(page, cuenta)
            except Exception as e2:
                log.warning("No pude volver a entrar a VISEC: %s", e2)
        try:
            if page is not None:
                page.close()
        except Exception:
            pass
        return {"page": None, "informe": None, "nums": nums, "fin": "error", "falla": True, "error": str(e), "cuenta": cuenta}


def cerrar_lote(sb, w):
    """Lee los resultados del lote terminado, los guarda, descarta el lote y cierra la pestaña. Devuelve cuántos guardó."""
    page, informe = w["page"], w["informe"]
    n = 0
    try:
        filas = leer_resultados(page, informe, w["nums"])
        errores = w.get("errores") or set()
        if errores:
            # inhabilitadas por un RENSPA que VISEC no pudo verificar en ARCA: no es un resultado real
            n_err = 0
            for f in filas:
                if f["estado"] == "INHABILITADA" and any(r in (f["observacion"] or "") for r in errores):
                    f["estado"] = ERROR_ARCA; n_err += 1
            if n_err:
                log.warning("  [%s] %d caravanas quedan como %s (RENSPA con problema; no se reconsultan solas)", informe, n_err, ERROR_ARCA)
        n = sb.rpc("visec_guardar", {"p_filas": filas, "p_informe": informe}) or 0
        resumen = {e: sum(1 for f in filas if f["estado"] == e) for e in {f["estado"] for f in filas}}
        log.info("  [%s] Guardados %d resultados: %s", informe, n, ", ".join(f"{k}={v}" for k, v in sorted(resumen.items())))
    except Exception as e:
        log.error("  [%s] No pude leer/guardar los resultados: %s", informe, e)
    descartar_lote(page, informe)
    try:
        page.close()
    except Exception:
        pass
    return n


RECARGA_SEG = 300              # si la pantalla del lote no muestra avance en este tiempo, se recarga (Blazor deja de refrescar)


def revisar(w):
    """Avanza el estado de un lote en validación. Deja w['fin'] = 'ok' / 'timeout' cuando está para leer."""
    page = w["page"]
    ahora = time.time()
    # La pantalla del lote deja de actualizarse sola al rato (el circuito Blazor se queda mudo aunque VISEC
    # siga trabajando): si no hubo novedades en RECARGA_SEG, se recarga para ver el estado real.
    if ahora - w.get("ultimo_avance", ahora) > RECARGA_SEG and ahora - w.get("ultima_recarga", 0) > RECARGA_SEG:
        w["ultima_recarga"] = ahora
        try:
            abrir_lote(page, w["informe"])
        except Exception as e:
            log.warning("  [%s] No pude recargar la pantalla: %s", w["informe"], e)
    try:
        est = estado_lote(page, w)
    except Exception as e:
        log.warning("  [%s] No pude leer la pantalla (%s); recargo", w["informe"], e); est = "caido"
    if est == "caido":
        log.warning("  [%s] Conexión Blazor caída, recargo el lote", w["informe"])
        try:
            abrir_lote(page, w["informe"])
        except Exception as e:
            log.warning("  [%s] No pude recargar: %s", w["informe"], e)
    elif est == "finalizado":
        errores = renspas_con_error(page)
        if errores:
            # Volver a "Ejecutar proceso de validación" en el mismo lote no sirve: VISEC contesta
            # "Caravana validada anteriormente" y repite el resultado. Se marcan ERROR ARCA y se
            # reconsultan en un lote nuevo otro día (hasta VISEC_REINTENTOS veces).
            log.warning("  [%s] VISEC no pudo leer ARCA para %s", w["informe"], ", ".join(sorted(errores)))
        w["fin"] = "ok"; w["errores"] = errores
    elif time.time() > w["tope"]:
        log.warning("  [%s] El lote lleva %d horas sin terminar; leo lo que haya", w["informe"], TOPE_LOTE_H)
        w["fin"] = "timeout"; w["errores"] = set()
    elif w.get("estado_visec") not in ("EN PROCESO", "EN ESPERA", "EN VALIDACIÓN", "CREANDO") \
            and time.time() - w.get("ultimo_avance", time.time()) > SIN_AVANCE_MIN * 60:
        # Mientras VISEC diga EN PROCESO / EN ESPERA (cola de VISEC) / EN VALIDACIÓN se espera: tarda lo que
        # tarda (a la tarde hubo lotes de 15 que demoraron más de una hora en la cola). Solo se abandona
        # si la pantalla no dice nada reconocible durante SIN_AVANCE_MIN.
        log.warning("  [%s] La pantalla no muestra un estado reconocible hace %d min (%r); leo lo que haya", w["informe"], SIN_AVANCE_MIN, w.get("estado_visec"))
        w["fin"] = "timeout"; w["errores"] = set()


def main():
    from playwright.sync_api import sync_playwright
    if not tomar_bloqueo():
        return
    if not CUENTAS:
        raise SystemExit("Faltan VISEC_USUARIO / VISEC_CLAVE en sync\\.env")
    sb = Supa()
    corrida = sb.insert("visec_corridas", {"estado": "corriendo"})["id"]
    inicio = time.time(); total = 0; informes = []
    try:
        if not (sb.rpc("visec_pendientes", {"p_max": 1}) or []):
            sb.patch("visec_corridas", f"id=eq.{corrida}", {"estado": "sin_pendientes", "fin": datetime.now().astimezone().isoformat(), "cantidad": 0})
            log.info("No hay caravanas pendientes de consulta VISEC"); return
        with sync_playwright() as p:
            browser = None

            def abrir_navegador():
                """Un navegador, y un contexto (cookies propias) por usuario de VISEC."""
                b = p.chromium.launch(headless=not VISIBLE, args=["--disable-gpu", "--disable-dev-shm-usage", "--no-sandbox", "--disable-extensions"])
                for cu in list(CUENTAS):
                    cu["ctx"] = b.new_context(viewport={"width": 1400, "height": 900})
                    pg = cu["ctx"].new_page(); pg.set_default_timeout(60000)
                    try:
                        login(pg, cu)
                    except Exception as e:
                        # un usuario que no entra no frena a los demás: se lo deja afuera de esta corrida
                        log.error("El usuario %s no pudo entrar a VISEC (%s); sigo con los demás", cu["usuario"], str(e)[:160])
                        CUENTAS.remove(cu)
                    finally:
                        pg.close()
                    cu["fallas"] = 0
                if not CUENTAS:
                    raise RuntimeError("Ningún usuario de VISEC pudo iniciar sesión (revisar VISEC_USUARIO/VISEC_CLAVE en sync\\.env)")
                return b

            browser = abrir_navegador()
            log.info("Trabajando con %d usuario(s) de VISEC: %s", len(CUENTAS), ", ".join(c["usuario"] for c in CUENTAS))
            for cu in CUENTAS:
                limpiar_huerfanos(cu["ctx"], sb, informar_cola(cu["ctx"], cu["usuario"]), set())
            ultimo_informe_cola = time.time()
            workers = []          # lotes abiertos (uno por pestaña)
            sin_pendientes = False; parada_desde = None
            while True:
                hay_tiempo = MAX_MIN <= 0 or (time.time() - inicio) < MAX_MIN * 60
                if STOP.exists() or Path(__file__).stat().st_mtime != MI_MTIME:
                    if parada_desde is None:
                        parada_desde = time.time()
                        log.info("Pedido de parada (%s): no abro lotes nuevos; termino los abiertos (como mucho 20 min) y salgo; la tarea de cada hora lo relanza",
                                 "visec_consulta.stop" if STOP.exists() else "versión nueva del robot")
                    sin_pendientes = True
                    if STOP.exists() or time.time() - parada_desde > 1200:
                        for w in workers:
                            if w["fin"] is None:
                                log.warning("  [%s] Se lee y descarta como está por la parada", w["informe"])
                                w["fin"] = "parada"; w["errores"] = set()
                # llenar las pestañas libres de cada usuario con lotes nuevos (apenas se libera una, arranca otro lote)
                if hay_tiempo and not sin_pendientes:
                    for cu in CUENTAS:
                        while not sin_pendientes and sum(1 for w in workers if w["cuenta"] is cu) < PARALELO and cu["fallas"] < 6:
                            en_curso = {n for w in workers for n in w["nums"]}
                            w = nuevo_lote(cu, sb, en_curso)
                            if w is None:
                                sin_pendientes = True; break
                            if w.get("falla"):
                                cu["fallas"] += 1
                                if re.search(r"crashed|closed|disconnected", w.get("error", ""), re.I) and not workers:
                                    # se cayó el navegador: lo reabro entero (solo si no hay lotes en curso)
                                    log.warning("El navegador se cayó (%s); lo reinicio", w["error"][:80])
                                    try:
                                        browser.close()
                                    except Exception:
                                        pass
                                    browser = abrir_navegador()
                                else:
                                    time.sleep(30)
                                continue
                            cu["fallas"] = 0
                            workers.append(w)
                if not workers:
                    break
                time.sleep(15)
                LOCK.touch()
                if time.time() - ultimo_informe_cola > 1800:
                    for cu in CUENTAS:
                        limpiar_huerfanos(cu["ctx"], sb, informar_cola(cu["ctx"], cu["usuario"]), {w["informe"] for w in workers})
                    ultimo_informe_cola = time.time()
                for w in workers:
                    if w["fin"] is None:
                        revisar(w)
                # cerrar los terminados (y en la próxima vuelta se abre otro lote en su lugar)
                listos = [w for w in workers if w["fin"] is not None]
                for w in listos:
                    informes.append(w["informe"])
                    total += cerrar_lote(sb, w)
                    workers.remove(w)
                    try:   # avance visible en el portal (Inicio > VISEC)
                        sb.patch("visec_corridas", f"id=eq.{corrida}", {"cantidad": total, "informe": ",".join(informes[-30:]), "detalle": f"{len(informes)} lote(s), corriendo"})
                    except Exception:
                        pass
                    sin_pendientes = False   # pueden haber aparecido pedidos o altas nuevas
            browser.close()
        sb.patch("visec_corridas", f"id=eq.{corrida}", {"estado": "ok", "fin": datetime.now().astimezone().isoformat(), "cantidad": total,
                                                       "informe": ",".join(informes), "detalle": f"{len(informes)} lote(s)"})
        log.info("Listo: %d resultados en %d lote(s)", total, len(informes))
    except Exception as e:
        log.exception("Error en la consulta VISEC")
        sb.patch("visec_corridas", f"id=eq.{corrida}", {"estado": "error", "fin": datetime.now().astimezone().isoformat(), "cantidad": total,
                                                       "informe": ",".join(informes), "detalle": str(e)[:900]})
        sys.exit(1)
    finally:
        soltar_bloqueo()
        try:
            STOP.unlink()
        except OSError:
            pass


if __name__ == "__main__":
    main()
