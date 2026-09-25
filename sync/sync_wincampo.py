# -*- coding: utf-8 -*-
"""
sync_wincampo.py — Caravanas Pecuaria
Sincroniza ingresos y egresos con caravana electrónica (032…) desde WinCampo Web
hacia Supabase (tablas wc_ingresos / wc_egresos) y marca las salidas del padrón.

Fuentes (API REST de WinCampo Web, misma que el portal PEGSA):
  - lst_trazabilidad (ingreso_caravana) -> Ingresos por Caravana: una fila por animal con RFID, tropa, fecha, categoría
  - caravanas_stock              -> stock actual (complemento)
  - lst_egresos_hacienda         -> egresos por caravana (MOTIVO V=venta, M=muerte, T=traslado)
  - lst_movimiento_hacienda      -> tropas de ingreso (DTE_INGRESO, CONSIGNATARIO, ORIGEN) para enriquecer

Un "ingreso por caravana" sale del reporte de trazabilidad; stock y egresos completan lo que falte,
enriquecido con los datos de la tropa. Solo entran RFID que empiezan con 032 (15 dígitos).

Modos:
  python sync_wincampo.py --modo full                # corrida completa (programar diaria 07:00)
  python sync_wincampo.py --modo poll                # atiende una solicitud "pendiente" de Refrescar si la hay
  python sync_wincampo.py --modo full --desde 2024-01-01   # carga inicial histórica

Credenciales: .env en esta carpeta (ver .env.example). Si falta WINCAMPO_EMAIL, toma el .env
del portal PEGSA (OneDrive\\PEGSA_Portal\\.env).
"""
import argparse
import json
import logging
import os
import re
import sys
import time
from datetime import date, datetime, timedelta
from pathlib import Path

import requests
from dotenv import load_dotenv

AQUI = Path(__file__).resolve().parent
load_dotenv(AQUI / ".env")
if not os.environ.get("WINCAMPO_EMAIL"):
    load_dotenv(Path(r"C:\Users\USER\OneDrive - pecuaria el garabi sa\PEGSA_Portal\.env"))

API = "https://elgarabi-api.wincampo.com/api/"
SB_URL = os.environ.get("SUPABASE_URL", "").rstrip("/")
SB_KEY = os.environ.get("SUPABASE_SERVICE_KEY", "")
RFID_OK = re.compile(r"^032\d{12}$")
CONSIG_TRASLADO = {"TRASLADO", "DESTETE"}
MOTIVO = {"V": "venta", "M": "muerte", "T": "traslado"}
CAT_MAP = {"TO": "TORO", "VA": "VACA", "VQ": "HEMBRA", "TH": "HEMBRA", "TM": "MACHO", "NT": "MACHO", "NV": "MACHO"}

log = logging.getLogger("sync")
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
    handlers=[logging.StreamHandler(sys.stdout),
              logging.FileHandler(AQUI / "sync_wincampo.log", encoding="utf-8")])


# ───────────────────────── WinCampo ─────────────────────────
class WinCampo:
    def __init__(self):
        self.s = requests.Session()
        self.s.headers.update({"Accept": "application/json", "Content-Type": "application/json"})
        self._login()

    def _login(self):
        r = self.s.post(API + "login", json={"email": os.environ["WINCAMPO_EMAIL"],
                                              "password": os.environ["WINCAMPO_PASSWORD"], "idioma": "es"}, timeout=30)
        r.raise_for_status()
        d = r.json()
        d = d[0] if isinstance(d, list) else d
        self.s.headers["Authorization"] = "Bearer " + d["token"]
        log.info("WinCampo login OK (%s)", d.get("nombre"))

    def get(self, path, params=None, intentos=3):
        for i in range(intentos):
            try:
                time.sleep(0.3)
                r = self.s.get(API + path, params=params, timeout=180)
                if r.status_code == 401:
                    self._login(); continue
                if r.status_code >= 500:
                    raise requests.HTTPError(f"HTTP {r.status_code}")
                r.raise_for_status()
                return r.json()
            except (requests.ConnectionError, requests.Timeout, requests.HTTPError) as e:
                if i == intentos - 1:
                    raise
                log.warning("%s: %s, reintento en %ss", path, e, 3 ** i)
                time.sleep(3 ** i)

    def stock(self):
        d = self.get("caravanas_stock")
        return d.get("data", []) if isinstance(d, dict) else d

    def egresos(self, desde, hasta):
        """Aplana hotelero -> tropas -> detalle. Chunks de 500 días (cap del endpoint)."""
        out = []
        d0 = desde
        while d0 <= hasta:
            d1 = min(d0 + timedelta(days=499), hasta)
            data = self.get("lst_egresos_hacienda", {"fecha_desde": d0.strftime("%Y%m%d"), "fecha_hasta": d1.strftime("%Y%m%d"),
                                                     "filtro_tropa_caravana": "por_caravana"})
            for h in data.get("lst_egresos_hacienda", []):
                for t in h.get("tropas", []):
                    for x in t.get("detalle", []):
                        x.setdefault("HOTELERO", h.get("HOTELERO")); x.setdefault("NRO_TROPA", t.get("NRO_TROPA"))
                        out.append(x)
            d0 = d1 + timedelta(days=1)
        return out

    def ingresos_por_caravana(self, desde, hasta):
        """Reporte 'Ingresos por Caravana' de la pantalla Trazabilidad (lst_trazabilidad).
        Una fila por animal: FECHA_INGRESO, NRO_TROPA, HOTELERO, NRO_CARAVANA, RFID, CATEGORIA, KG_INGRESO, NRO_CORRAL.
        Parámetros tomados del código de la pantalla de WinCampo Web (25/09/2026)."""
        data = self.get("lst_trazabilidad", {
            "fecha_desde": desde.strftime("%Y%m%d"), "fecha_hasta": hasta.strftime("%Y%m%d"),
            "reporte_elegido": "ingreso_caravana", "extendido_sino": "N", "new_version_sino": "S",
            "inicia_termina_sino": "N", "resumen_sino": "N", "comparar_pesada_anterior_sino": "N"})
        return data.get("lst_trazabilidad", []) if isinstance(data, dict) else []

    def tropas_ingreso(self, desde, hasta):
        data = self.get("lst_movimiento_hacienda", {"fecha_desde": desde.strftime("%Y%m%d"), "fecha_hasta": hasta.strftime("%Y%m%d"),
                                                    "reporte_elegido": "ingreso_hacienda", "agrupado": "N", "visualiza_dte": "S"})
        return data.get("lst_movimiento_hacienda", []) if isinstance(data, dict) else []


# ───────────────────────── Supabase ─────────────────────────
class Supa:
    def __init__(self):
        if not SB_URL or not SB_KEY:
            raise SystemExit("Faltan SUPABASE_URL / SUPABASE_SERVICE_KEY en el .env")
        self.h = {"apikey": SB_KEY, "Authorization": "Bearer " + SB_KEY, "Content-Type": "application/json"}

    def upsert(self, tabla, filas, lote=500):
        n = 0
        for i in range(0, len(filas), lote):
            r = requests.post(f"{SB_URL}/rest/v1/{tabla}", headers={**self.h, "Prefer": "resolution=merge-duplicates,return=minimal"},
                              data=json.dumps(filas[i:i + lote]), timeout=120)
            if r.status_code >= 300:
                raise RuntimeError(f"upsert {tabla}: HTTP {r.status_code} {r.text[:300]}")
            n += len(filas[i:i + lote])
        return n

    def rpc(self, fn, args=None):
        r = requests.post(f"{SB_URL}/rest/v1/rpc/{fn}", headers=self.h, data=json.dumps(args or {}), timeout=120)
        if r.status_code >= 300:
            raise RuntimeError(f"rpc {fn}: HTTP {r.status_code} {r.text[:300]}")
        return r.json() if r.text else None

    def select(self, tabla, query):
        r = requests.get(f"{SB_URL}/rest/v1/{tabla}?{query}", headers=self.h, timeout=60)
        r.raise_for_status(); return r.json()

    def patch(self, tabla, query, datos):
        r = requests.patch(f"{SB_URL}/rest/v1/{tabla}?{query}", headers={**self.h, "Prefer": "return=minimal"}, data=json.dumps(datos), timeout=60)
        if r.status_code >= 300:
            raise RuntimeError(f"patch {tabla}: HTTP {r.status_code} {r.text[:300]}")

    def insert(self, tabla, datos):
        r = requests.post(f"{SB_URL}/rest/v1/{tabla}", headers={**self.h, "Prefer": "return=representation"}, data=json.dumps(datos), timeout=60)
        if r.status_code >= 300:
            raise RuntimeError(f"insert {tabla}: HTTP {r.status_code} {r.text[:300]}")
        return r.json()[0]


# ───────────────────────── Transformación ─────────────────────────
def fecha(s):
    if not s: return None
    s = str(s).strip()
    for f in ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d", "%d/%m/%Y"):
        try: return datetime.strptime(s[:26], f).date().isoformat()
        except ValueError: pass
    return None


def limpiar(s):
    s = (s or "").strip()
    return s or None


def es_traslado(tropa):
    if not tropa: return False
    c = (tropa.get("CONSIGNATARIO") or "").strip().upper()
    o = (tropa.get("ORIGEN") or "").strip().upper()
    d = (tropa.get("DTE_INGRESO") or "").strip().upper()
    return c in CONSIG_TRASLADO or o == "TRASLADO" or d.startswith("TRASLADO")


def armar_ingresos(stock, egresos, tropas, trazabilidad=()):
    """Una fila por (RFID, tropa, fecha ingreso), enriquecida con la tropa.
    Fuente principal: reporte 'Ingresos por Caravana' (trazabilidad); stock y egresos completan
    cualquier animal que el reporte no traiga (misma clave, así que no se duplican)."""
    por_tropa = {t.get("NRO_TROPA"): t for t in tropas}
    filas = {}

    def agregar(rfid, tropa_nro, f_ing, hotelero, cat_wc, corral, consig=None, origen=None):
        rfid = (rfid or "").strip()
        f = fecha(f_ing)
        if not RFID_OK.match(rfid) or not f:
            return
        clave = f"{rfid}|{tropa_nro or ''}|{f}"
        t = por_tropa.get(tropa_nro)
        dte = limpiar(t.get("DTE_INGRESO")) if t else None
        if dte and dte.upper() in ("SIN DTE",): dte = None
        filas[clave] = {
            "id_wincampo": clave, "caravana": rfid, "fecha_ingreso": f,
            "origen": limpiar((t or {}).get("PROVEEDOR")) or limpiar(origen),
            "hotelero": limpiar(hotelero),
            "consignataria": limpiar((t or {}).get("CONSIGNATARIO")) or limpiar(consig),
            "categoria_wc": limpiar(cat_wc), "categoria": CAT_MAP.get((cat_wc or "").strip().upper()),
            "nro_tropa": limpiar(tropa_nro), "nro_corral": limpiar(corral),
            "dte_wc": dte,
            "es_traslado": es_traslado(t) if t else ((consig or "").strip().upper() in CONSIG_TRASLADO),
            "sincronizado_en": datetime.now().astimezone().isoformat(),
        }

    # 1) reporte Ingresos por Caravana (fuente principal)
    for x in trazabilidad:
        agregar(x.get("RFID"), x.get("NRO_TROPA"), x.get("FECHA_INGRESO"), x.get("HOTELERO"),
                x.get("CATEGORIA"), x.get("NRO_CORRAL"))
    # 2) complemento: stock actual y egresos (no pisan lo que ya vino del reporte)
    for x in stock:
        clave = f"{(x.get('RFID') or '').strip()}|{x.get('NRO_TROPA') or ''}|{fecha(x.get('FECHA_INGRESO'))}"
        if clave in filas: continue
        agregar(x.get("RFID"), x.get("NRO_TROPA"), x.get("FECHA_INGRESO"), x.get("HOTELERO"),
                x.get("CATEGORIA_INGRESO") or x.get("CATEGORIA_ACTUAL"), x.get("NRO_CORRAL"), x.get("CONSIGNATARIO"), x.get("PROVEEDOR_TROPA"))
    for x in egresos:
        clave = f"{(x.get('RFID') or '').strip()}|{x.get('NRO_TROPA') or ''}|{fecha(x.get('FECHA_INGRESO'))}"
        if clave in filas: continue
        agregar(x.get("RFID"), x.get("NRO_TROPA"), x.get("FECHA_INGRESO"), x.get("HOTELERO"),
                x.get("CATEGORIA"), x.get("NRO_CORRAL"), None, x.get("ORIGEN"))
    return list(filas.values())


def armar_egresos(egresos):
    filas = {}
    for x in egresos:
        rfid = (x.get("RFID") or "").strip(); f = fecha(x.get("FECHA_EGRESO"))
        if not RFID_OK.match(rfid) or not f:
            continue
        clave = f"{rfid}|{x.get('NRO_TRANSACCION') or ''}|{f}"
        cat = (x.get("CATEGORIA") or "").strip().upper()
        filas[clave] = {
            "id_wincampo": clave, "caravana": rfid, "fecha_egreso": f,
            "destino": limpiar(x.get("DESTINO")), "hotelero": limpiar(x.get("HOTELERO")),
            "categoria_wc": cat or None, "categoria": CAT_MAP.get(cat),
            "nro_tropa": limpiar(x.get("NRO_TROPA")),
            "motivo": MOTIVO.get((x.get("MOTIVO") or "").strip().upper(), (x.get("MOTIVO") or "otro").lower()),
            "sincronizado_en": datetime.now().astimezone().isoformat(),
        }
    return list(filas.values())


# ───────────────────────── Corrida ─────────────────────────
def correr(sb, desde, hasta, sync_id=None):
    inicio = datetime.now().astimezone().isoformat()
    if sync_id:
        sb.patch("sincronizaciones", f"id=eq.{sync_id}", {"estado": "corriendo", "inicio": inicio})
    else:
        sync_id = sb.insert("sincronizaciones", {"solicitado_por": None, "estado": "corriendo", "inicio": inicio})["id"]
    try:
        wc = WinCampo()
        log.info("Leyendo stock…"); stock = wc.stock(); log.info("  %d animales en stock", len(stock))
        log.info("Leyendo egresos %s → %s…", desde, hasta); egr = wc.egresos(desde, hasta); log.info("  %d egresos", len(egr))
        log.info("Leyendo tropas de ingreso…"); tropas = wc.tropas_ingreso(desde, hasta); log.info("  %d tropas", len(tropas))
        log.info("Leyendo Ingresos por Caravana (trazabilidad)…"); traz = wc.ingresos_por_caravana(desde, hasta); log.info("  %d filas", len(traz))

        ing_rows = armar_ingresos(stock, egr, tropas, traz)
        egr_rows = armar_egresos(egr)
        log.info("Caravanas 032: %d ingresos, %d egresos", len(ing_rows), len(egr_rows))
        n_i = sb.upsert("wc_ingresos", ing_rows)
        n_e = sb.upsert("wc_egresos", egr_rows)
        salidas = sb.rpc("marcar_salidas") or 0
        log.info("Salidas marcadas en el padrón: %s", salidas)
        sb.patch("sincronizaciones", f"id=eq.{sync_id}", {"estado": "ok", "fin": datetime.now().astimezone().isoformat(),
                                                          "ingresos_nuevos": n_i, "egresos_nuevos": n_e, "salidas_marcadas": salidas})
        return True
    except Exception as e:
        log.exception("Error en la sincronización")
        sb.patch("sincronizaciones", f"id=eq.{sync_id}", {"estado": "error", "fin": datetime.now().astimezone().isoformat(), "error": str(e)[:900]})
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--modo", choices=["full", "poll"], default="full")
    ap.add_argument("--desde", help="YYYY-MM-DD (default: hoy - 120 días)")
    ap.add_argument("--hasta", help="YYYY-MM-DD (default: hoy)")
    a = ap.parse_args()
    hasta = date.fromisoformat(a.hasta) if a.hasta else date.today()
    desde = date.fromisoformat(a.desde) if a.desde else hasta - timedelta(days=120)
    sb = Supa()

    if a.modo == "poll":
        pend = sb.select("sincronizaciones", "estado=eq.pendiente&order=id.asc&limit=1")
        if not pend:
            return
        # si hay otra corriendo hace menos de 20 min, esperar al próximo tick
        corriendo = sb.select("sincronizaciones", "estado=eq.corriendo&order=id.desc&limit=1")
        if corriendo and (datetime.now().astimezone() - datetime.fromisoformat(corriendo[0]["inicio"])).total_seconds() < 1200:
            log.info("Hay una sincronización corriendo; espero"); return
        log.info("Solicitud de refresco #%s de %s", pend[0]["id"], pend[0].get("solicitado_por"))
        ok = correr(sb, desde, hasta, sync_id=pend[0]["id"])
    else:
        ok = correr(sb, desde, hasta)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
