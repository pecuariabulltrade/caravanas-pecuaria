# -*- coding: utf-8 -*-
"""Exploración v3: lst_trazabilidad con los parámetros exactos que manda la pantalla de WinCampo Web. Solo lectura."""
import os, json, time, re
from pathlib import Path
from datetime import date
from collections import Counter
import requests
from dotenv import load_dotenv
load_dotenv(Path(__file__).resolve().parent.parent / "sync" / ".env")
if not os.environ.get("WINCAMPO_EMAIL"):
    load_dotenv(Path(r"C:\Users\USER\OneDrive - pecuaria el garabi sa\PEGSA_Portal\.env"))
API = "https://elgarabi-api.wincampo.com/api/"
OUT = Path(__file__).resolve().parent / "explor3"; OUT.mkdir(exist_ok=True)
s = requests.Session(); s.headers.update({"Accept": "application/json", "Content-Type": "application/json"})
r = s.post(API + "login", json={"email": os.environ["WINCAMPO_EMAIL"], "password": os.environ["WINCAMPO_PASSWORD"], "idioma": "es"}, timeout=30)
d = r.json(); d = d[0] if isinstance(d, list) else d; s.headers["Authorization"] = "Bearer " + d["token"]; print("login OK")

def walk(obj, prefix="", acc=None, depth=0):
    if acc is None: acc = {}
    if depth > 4: return acc
    if isinstance(obj, dict):
        for k, v in obj.items():
            acc.setdefault(prefix + k, type(v).__name__)
            if isinstance(v, (dict, list)): walk(v, prefix + k + ".", acc, depth + 1)
    elif isinstance(obj, list) and obj: walk(obj[0], prefix + "[].", acc, depth + 1)
    return acc

def probar(nombre, params):
    print(f"\n== {nombre}: {params}")
    try:
        time.sleep(0.3); r = s.get(API + "lst_trazabilidad", params=params, timeout=180)
    except Exception as e:
        print("  ERROR", e); return None
    t = r.text
    print("  HTTP", r.status_code, len(t), "bytes")
    if r.status_code != 200:
        print("  ", t[:300]); return None
    try: data = r.json()
    except Exception: print("  no JSON:", t[:200]); return None
    keys = walk(data); print("  keys:", json.dumps(keys, ensure_ascii=False)[:2500])
    rf = Counter(x[:3] for x in re.findall(r'"RFID": ?"([^"]*)"', t)); print("  RFID por prefijo:", rf.most_common(6), " total RFID:", sum(rf.values()))
    for col in ("DTE", "DTE_INGRESO", "MOTIVO", "CONSIGNATARIO", "ORIGEN", "HOTELERO", "CATEGORIA", "TIPO_OPERACION", "FECHA_INGRESO"):
        vals = Counter(re.findall(r'"%s": ?"([^"]*)"' % col, t)); 
        if vals: print(f"  {col}: {vals.most_common(6)}")
    (OUT / f"{nombre}.json").write_text(t[:600000], encoding="utf-8")
    return data

base = {"fecha_desde": "20260101", "fecha_hasta": date.today().strftime("%Y%m%d"), "reporte_elegido": "ingreso_caravana",
        "extendido_sino": "N", "new_version_sino": "S", "inicia_termina_sino": "N", "resumen_sino": "N", "comparar_pesada_anterior_sino": "N"}
probar("ingreso_caravana", base)
probar("ingreso_caravana_pag1", {**base, "pagina": 1})
probar("ingreso_caravana_extendido", {**base, "reporte_elegido": "ingreso_caravana_extendido", "extendido_sino": "S"})
probar("ingreso_caravana_newver_N", {**base, "new_version_sino": "N"})
probar("ingreso_caravana_corto", {**base, "fecha_desde": "20260901"})
print("\nListo. Resultados en", OUT)
