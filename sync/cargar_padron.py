# -*- coding: utf-8 -*-
"""
cargar_padron.py — Caravanas Pecuaria
Carga inicial del padrón de caravanas ACTIVAS en SENASA desde padron/padron_032.csv
(generado a partir de "CARAVANAS PADRON.xlsx": solo caravanas 032, sin duplicados).

Cada caravana queda 'activa' con origen_alta = padron_inicial, propietario, categoría,
fecha de alta (FECHA INGRESO del Excel), procedencia (ORIGEN del Excel) y la bolsa en
observaciones. Las que ya existen en el padrón no se tocan. Al final llama a
marcar_salidas() para pasar a 'salida' las que WinCampo ya dio por vendidas o muertas.

Se puede correr más de una vez sin duplicar nada.
"""
import csv
import json
import os
import sys
from datetime import datetime
from pathlib import Path

import requests
from dotenv import load_dotenv

AQUI = Path(__file__).resolve().parent
load_dotenv(AQUI / ".env")
SB_URL = os.environ.get("SUPABASE_URL", "").rstrip("/")
SB_KEY = os.environ.get("SUPABASE_SERVICE_KEY", "")
CSV = AQUI.parent / "padron" / "padron_032.csv"
H = {"apikey": SB_KEY, "Authorization": "Bearer " + SB_KEY, "Content-Type": "application/json"}
USUARIO = "carga_inicial"


def get_all(tabla, query):
    out, off = [], 0
    while True:
        r = requests.get(f"{SB_URL}/rest/v1/{tabla}?{query}", headers={**H, "Range": f"{off}-{off + 999}", "Range-Unit": "items"}, timeout=60)
        r.raise_for_status()
        data = r.json(); out += data
        if len(data) < 1000: return out
        off += 1000


def post(tabla, filas, prefer="return=minimal"):
    for i in range(0, len(filas), 500):
        r = requests.post(f"{SB_URL}/rest/v1/{tabla}", headers={**H, "Prefer": prefer}, data=json.dumps(filas[i:i + 500]), timeout=120)
        if r.status_code >= 300:
            raise RuntimeError(f"{tabla}: HTTP {r.status_code} {r.text[:400]}")


def cargar_virgenes(existentes):
    """Carga padron/virgenes_032.csv como caravanas 'virgen', agrupadas en rangos consecutivos
    y registradas como compras 'Stock inicial' para que se puedan elegir en Alta con vírgenes."""
    csv_v = AQUI.parent / "padron" / "virgenes_032.csv"
    if not csv_v.exists():
        print("(sin archivo de vírgenes, se omite)"); return
    nums = sorted({r["numero"].strip() for r in csv.DictReader(open(csv_v, encoding="utf-8")) if r["numero"].strip()}, key=int)
    nums = [n for n in nums if n not in existentes]
    if not nums:
        print("Vírgenes: todas ya estaban cargadas."); return
    rangos, a, b = [], int(nums[0]), int(nums[0])
    for n in map(int, nums[1:]):
        if n == b + 1: b = n
        else: rangos.append((a, b)); a = b = n
    rangos.append((a, b))
    tot = 0
    for a, b in rangos:
        body = {"p_fecha": datetime.now().date().isoformat(), "p_proveedor": "Stock inicial", "p_desde": f"{a:015d}", "p_hasta": f"{b:015d}",
                "p_comprobante": "Vírgenes disponibles al 25/09/2026", "p_usuario": USUARIO, "p_observaciones": None}
        r = requests.post(f"{SB_URL}/rest/v1/rpc/registrar_compra", headers=H, data=json.dumps(body), timeout=60)
        if r.status_code >= 300:
            print(f"  rango {a:015d}-{b:015d}: ERROR {r.text[:200]}"); continue
        tot += b - a + 1
        print(f"  vírgenes {a:015d} -> {b:015d}: {b - a + 1} cargadas")
    print(f"Vírgenes cargadas: {tot}")


def main():
    if not SB_URL or not SB_KEY:
        sys.exit("Falta SUPABASE_URL / SUPABASE_SERVICE_KEY en sync\\.env")
    if not CSV.exists():
        sys.exit(f"No encuentro {CSV}")

    props = {p["nombre"].upper(): p["id"] for p in get_all("propietarios", "select=id,nombre")}
    existentes = {c["numero"] for c in get_all("caravanas", "select=numero")}
    print(f"Propietarios: {list(props)}\nYa en el padrón: {len(existentes)}")

    filas = list(csv.DictReader(open(CSV, encoding="utf-8")))
    nuevas, movs, omitidas, sin_prop = [], [], 0, set()
    for f in filas:
        n = f["numero"].strip()
        if n in existentes:
            omitidas += 1; continue
        pid = props.get(f["propietario"].strip().upper())
        if not pid:
            sin_prop.add(f["propietario"]); continue
        cat = f["categoria"].strip().upper()
        if cat not in ("TORO", "VACA", "HEMBRA", "MACHO"):
            sin_prop.add("CATEGORIA " + cat); continue
        obs = f"Bolsa: {f['bolsa']}" if f.get("bolsa") else None
        nuevas.append({"numero": n, "estado": "activa", "propietario_id": pid, "categoria": cat,
                       "fecha_alta": f["fecha_alta"], "origen_alta": "padron_inicial",
                       "procedencia_alta": f.get("procedencia") or None, "observaciones": obs,
                       "actualizado_por": USUARIO})
        movs.append({"caravana": n, "tipo": "alta", "fecha": f["fecha_alta"], "propietario_id": pid, "categoria": cat,
                     "origen_destino": f.get("procedencia") or None, "fuente": "padron_inicial",
                     "observaciones": obs, "usuario": USUARIO})
    if sin_prop:
        sys.exit(f"Hay valores que no puedo mapear: {sorted(sin_prop)}")

    print(f"Filas en CSV: {len(filas)} · nuevas: {len(nuevas)} · ya existían: {omitidas}")
    if nuevas:
        post("caravanas", nuevas)
        post("movimientos", movs)
        print("Caravanas y movimientos cargados.")
    r = requests.post(f"{SB_URL}/rest/v1/rpc/marcar_salidas", headers=H, data="{}", timeout=120)
    print("Salidas marcadas (ya vendidas o muertas según WinCampo):", r.text)

    cargar_virgenes(existentes | {x["numero"] for x in nuevas})
    res = get_all("v_resumen", "select=*")
    print("\nResumen por propietario:")
    for x in res:
        print(f"  {x['propietario']:<12} activas {x['activas']:>5}  salidas pendientes {x['salidas_pendientes']:>5}  bajas {x['bajas']:>5}")


if __name__ == "__main__":
    main()
