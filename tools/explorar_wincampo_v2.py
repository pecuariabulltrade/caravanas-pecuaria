# -*- coding: utf-8 -*-
"""Exploración v2: busca un listado de INGRESOS por caravana (RFID) y consultas por caravana. Solo lectura."""
import os, json, time, re
from pathlib import Path
from datetime import date, timedelta
from collections import Counter
import requests
from dotenv import load_dotenv
load_dotenv(Path(r"C:\Users\USER\OneDrive - pecuaria el garabi sa\PEGSA_Portal\.env"))
API = "https://elgarabi-api.wincampo.com/api/"
OUT = Path(__file__).resolve().parent / "explor2"; OUT.mkdir(exist_ok=True)
s = requests.Session(); s.headers.update({"Accept": "application/json", "Content-Type": "application/json"})
r = s.post(API + "login", json={"email": os.environ["WINCAMPO_EMAIL"], "password": os.environ["WINCAMPO_PASSWORD"], "idioma": "es"}, timeout=30)
d = r.json(); d = d[0] if isinstance(d, list) else d; s.headers["Authorization"] = "Bearer " + d["token"]; print("login OK")
desde, hasta = "20260101", date.today().strftime("%Y%m%d")
resumen = {}
def rfids(txt): return Counter(x[:3] for x in re.findall(r'"RFID": ?"([^"]*)"', txt)).most_common(4)
def probar(nombre, path, params=None):
    try:
        time.sleep(0.3); r = s.get(API + path, params=params, timeout=180)
    except Exception as e:
        print(f"== {nombre}: ERROR {e}"); resumen[nombre] = str(e); return
    t = r.text
    keys = sorted(set(re.findall(r'"([A-Z_]{3,})":', t[:200000])))[:40]
    info = {"status": r.status_code, "bytes": len(t), "rfid": rfids(t), "keys": keys, "texto": t[:200] if r.status_code != 200 else ""}
    print(f"== {nombre}: HTTP {r.status_code} {len(t)} b  rfid={info['rfid']}  keys={keys[:12]}  {info['texto']}")
    if r.status_code == 200 and len(t) > 300: (OUT / f"{nombre}.json").write_text(t[:300000], encoding="utf-8")
    resumen[nombre] = info

# un RFID 032 real del stock para las consultas puntuales
st = s.get(API + "caravanas_stock", timeout=180).json().get("data", [])
uno = next((x for x in st if str(x.get("RFID", "")).startswith("032")), None)
rf = uno["RFID"] if uno else "032000000000000"; idt = uno.get("ID_TRAZABILIDAD") if uno else ""
print("RFID de prueba:", rf, "ID_TRAZABILIDAD:", idt, "tropa:", uno and uno.get("NRO_TROPA"))

for rep in ["trazabilidad", "ingreso", "ingresos", "ingreso_hacienda", "egreso", "bajas", "baja_cabeza", "movimientos", "detallado", "detallado_caravana", "caravana", "historial", "listado", "general", "completo"]:
    probar("traz_" + rep, "lst_trazabilidad", {"fecha_desde": desde, "fecha_hasta": hasta, "reporte_elegido": rep})
for rep in ["egreso_hacienda", "movimiento_hacienda", "traslado_hacienda", "ingreso_caravana", "detalle_caravana"]:
    probar("mov_" + rep, "lst_movimiento_hacienda", {"fecha_desde": desde, "fecha_hasta": hasta, "reporte_elegido": rep, "agrupado": "N", "visualiza_dte": "S"})
probar("mov_ingreso_agrupado_S", "lst_movimiento_hacienda", {"fecha_desde": desde, "fecha_hasta": hasta, "reporte_elegido": "ingreso_hacienda", "agrupado": "S", "visualiza_dte": "S"})
probar("mov_ingreso_por_caravana", "lst_movimiento_hacienda", {"fecha_desde": desde, "fecha_hasta": hasta, "reporte_elegido": "ingreso_hacienda", "agrupado": "N", "visualiza_dte": "S", "filtro_tropa_caravana": "por_caravana", "detalle_caravana": "S", "visualiza_caravana": "S"})
probar("stock_hist_fecha", "lst_stock_de_hacienda", {"agrupado": "N", "reporte_elegido": "detallado_caravana", "fecha": "20260301"})
probar("stock_hist_fecha2", "lst_stock_de_hacienda", {"agrupado": "N", "reporte_elegido": "detallado_caravana", "fecha_desde": "20260301", "fecha_hasta": "20260301"})
probar("stock_sin_fecha", "lst_stock_de_hacienda", {"agrupado": "N", "reporte_elegido": "detallado_caravana"})
for p in [f"consulta_caravana?rfid={rf}", f"consulta_caravana?caravana={rf}", f"consulta_caravana?RFID={rf}", f"caravana?rfid={rf}", f"caravanas/{rf}", f"caravana/{rf}", f"trazabilidad/{idt}", f"caravanas_stock/{idt}", f"historia_caravana?rfid={rf}", f"lst_481?fecha_desde={desde}&fecha_hasta={hasta}", "lst_481", f"movimiento_caravana?rfid={rf}", f"cc_pesada?rfid={rf}", f"baja_cabeza_rfid?rfid={rf}", f"actualiza_caravana?rfid={rf}", f"cambio_categoria_caravana?rfid={rf}"]:
    probar("q_" + re.sub(r"[^a-z0-9]+", "_", p.split("?")[0].lower()) + ("_p" if "?" in p else ""), p)
for rep in ["lst_trazabilidad", "lst_movimiento_hacienda", "lst_481", "consulta_caravana", "stock_detallado_de_caravanas"]:
    probar("pr_" + rep, "lst_planilla_recorrido", {"reporte_elegido": rep, "fecha": date.today().isoformat(), "procesar": "S"})
probar("maestro_motivo_baja", "motivo_baja_cabeza")
probar("maestro_clasif_caravana", "clasificacion_caravana")
(OUT / "_resumen.json").write_text(json.dumps(resumen, ensure_ascii=False, indent=1), encoding="utf-8")
print("\nListo. Resultados en", OUT)
