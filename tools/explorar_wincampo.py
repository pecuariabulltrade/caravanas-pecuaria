# -*- coding: utf-8 -*-
"""
explorar_wincampo.py - Etapa 1 Caravanas Pecuaria.
Captura la forma de los endpoints de WinCampo Web que traen caravanas (RFID)
en ingresos, egresos y stock. Escribe resultados en tools/explor/.
Usa las credenciales del .env de PEGSA_Portal (OneDrive).
"""
import os, sys, json, time
from pathlib import Path
from datetime import date, timedelta
from collections import Counter

import requests
from dotenv import load_dotenv

ENV = Path(r"C:\Users\USER\OneDrive - pecuaria el garabi sa\PEGSA_Portal\.env")
load_dotenv(ENV)
API = "https://elgarabi-api.wincampo.com/api/"
OUT = Path(__file__).resolve().parent / "explor"
OUT.mkdir(exist_ok=True)

s = requests.Session()
s.headers.update({"Accept": "application/json", "Content-Type": "application/json"})
r = s.post(API + "login", json={"email": os.environ["WINCAMPO_EMAIL"],
                                "password": os.environ["WINCAMPO_PASSWORD"], "idioma": "es"}, timeout=30)
r.raise_for_status()
d = r.json()
d = d[0] if isinstance(d, list) else d
s.headers["Authorization"] = "Bearer " + d["token"]
print("login OK", d.get("nombre"), d.get("empresa"), d.get("establecimiento"))

hoy = date.today()
desde = (hoy - timedelta(days=90)).strftime("%Y%m%d")
hasta = hoy.strftime("%Y%m%d")
resumen = {}

def get(path, params=None, timeout=120):
    time.sleep(0.3)
    r = s.get(API + path, params=params, timeout=timeout)
    return r

def walk_keys(obj, prefix="", acc=None, depth=0):
    """Colecta claves por nivel (para ver la jerarquia sin leer todo)."""
    if acc is None: acc = {}
    if depth > 4: return acc
    if isinstance(obj, dict):
        for k, v in obj.items():
            acc.setdefault(prefix + k, type(v).__name__)
            if isinstance(v, (dict, list)):
                walk_keys(v, prefix + k + ".", acc, depth + 1)
    elif isinstance(obj, list) and obj:
        walk_keys(obj[0], prefix + "[].", acc, depth + 1)
    return acc

def rfid_stats(rows, key_candidates=("RFID", "rfid", "CARAVANA_ELECTRONICA", "EID")):
    c = Counter()
    for row in rows:
        v = None
        for k in key_candidates:
            if k in row and row[k] not in (None, ""):
                v = str(row[k]).strip(); break
        if v is None: c["sin_rfid"] += 1
        elif v.startswith("032"): c["032"] += 1
        elif v.startswith("982"): c["982"] += 1
        else: c["otro:" + v[:3]] += 1
    return dict(c)

def flatten(obj, path_lists):
    """Aplana siguiendo la lista de claves de listas anidadas (p.ej. ['lst_x','tropas','detalle'])."""
    rows = [obj]
    for k in path_lists:
        nxt = []
        for r in rows:
            if isinstance(r, dict):
                v = r.get(k)
                if isinstance(v, list):
                    for it in v:
                        if isinstance(it, dict):
                            m = {kk: vv for kk, vv in r.items() if not isinstance(vv, (list, dict))}
                            m.update(it); nxt.append(m)
            elif isinstance(r, list):
                nxt.extend(x for x in r if isinstance(x, dict))
        rows = nxt
    return rows

def probar(nombre, path, params, aplanar=None, muestra=3):
    print(f"\n== {nombre}: {path} {params}")
    try:
        r = get(path, params)
    except Exception as e:
        print("  ERROR", e); resumen[nombre] = {"error": str(e)}; return None
    info = {"status": r.status_code, "bytes": len(r.content)}
    print("  HTTP", r.status_code, len(r.content), "bytes")
    if r.status_code != 200:
        info["texto"] = r.text[:300]; resumen[nombre] = info; return None
    try:
        data = r.json()
    except Exception:
        info["texto"] = r.text[:300]; resumen[nombre] = info; return None
    info["keys"] = walk_keys(data)
    (OUT / f"{nombre}_raw_head.json").write_text(json.dumps(data, ensure_ascii=False, default=str)[:400000], encoding="utf-8")
    if aplanar:
        rows = flatten(data, aplanar)
        info["filas"] = len(rows)
        info["rfid"] = rfid_stats(rows)
        for col in ("MOTIVO", "CATEGORIA", "HOTELERO", "CONSIGNATARIO", "DESTINO", "ORIGEN", "TIPO_ACTIVIDAD", "TIPO_MOVIMIENTO", "PROPIETARIO"):
            vals = Counter(str(x.get(col)) for x in rows if col in x)
            if vals: info["distinct_" + col] = dict(vals.most_common(15))
        (OUT / f"{nombre}_muestra.json").write_text(json.dumps(rows[:muestra], ensure_ascii=False, default=str, indent=1), encoding="utf-8")
        print("  filas:", len(rows), "rfid:", info["rfid"])
    resumen[nombre] = info
    return data

# 1. Ingresos - movimiento hacienda (con y sin DTE, agrupado N)
probar("ingresos_dte", "lst_movimiento_hacienda",
       {"fecha_desde": desde, "fecha_hasta": hasta, "reporte_elegido": "ingreso_hacienda", "agrupado": "N", "visualiza_dte": "S"},
       aplanar=["lst_movimiento_hacienda", "CAMIONES"])
# variantes por caravana
for rep in ("ingreso_caravana", "detallado_caravana", "ingreso_hacienda_caravana", "movimiento_caravana"):
    probar("ingresos_var_" + rep, "lst_movimiento_hacienda",
           {"fecha_desde": desde, "fecha_hasta": hasta, "reporte_elegido": rep, "agrupado": "N", "visualiza_dte": "S"})
probar("ingresos_por_caravana_param", "lst_movimiento_hacienda",
       {"fecha_desde": desde, "fecha_hasta": hasta, "reporte_elegido": "ingreso_hacienda", "agrupado": "N", "visualiza_dte": "S", "filtro_tropa_caravana": "por_caravana"},
       aplanar=["lst_movimiento_hacienda", "CAMIONES"])

# 2. Egresos por caravana
probar("egresos", "lst_egresos_hacienda",
       {"fecha_desde": desde, "fecha_hasta": hasta, "filtro_tropa_caravana": "por_caravana"},
       aplanar=["lst_egresos_hacienda", "tropas", "detalle"])

# 3. Stock actual por caravana
probar("stock_caravanas", "caravanas_stock", None, aplanar=["data"])

# 4. Trazabilidad / otros candidatos
probar("trazabilidad", "lst_trazabilidad", {"fecha_desde": desde, "fecha_hasta": hasta})
probar("trazabilidad_muertes", "lst_trazabilidad", {"fecha_desde": desde, "fecha_hasta": hasta, "id_motivo_baja_cabeza": "0002"})
probar("historia_caravana", "lst_historia_caravana", {"fecha_desde": desde, "fecha_hasta": hasta})
probar("dte", "dte", {"fecha_desde": desde, "fecha_hasta": hasta})
probar("dte_grilla", "dte/grilla", None)
probar("maestro_categoria", "categoria", None)
probar("maestro_hotelero", "hotelero/grilla", None)
probar("maestro_origen", "origen", {"ayuda_hacienda": 1})

(OUT / "_resumen.json").write_text(json.dumps(resumen, ensure_ascii=False, indent=1, default=str), encoding="utf-8")
print("\nListo. Resultados en", OUT)
