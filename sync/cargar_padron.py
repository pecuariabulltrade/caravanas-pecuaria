# -*- coding: utf-8 -*-
"""
cargar_padron.py — Caravanas Pecuaria
Carga inicial del padrón de caravanas ACTIVAS en SENASA desde padron/padron_032.csv
(generado a partir de "CARAVANAS PADRON.xlsx": electrónicas 032 y visuales, sin duplicados;
si no existe, usa padron_032.csv).

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
CSV = AQUI.parent / "padron" / "padron_completo.csv"
if not CSV.exists():
    CSV = AQUI.parent / "padron" / "padron_032.csv"
H = {"apikey": SB_KEY, "Authorization": "Bearer " + SB_KEY, "Content-Type": "application/json"}
USUARIO = "carga_inicial"


class _Tee:
    """Escribe en consola y en un log a la vez."""
    def __init__(self, path):
        self.f = open(path, "a", encoding="utf-8"); self.o = sys.__stdout__
        self.f.write(f"\n===== {datetime.now():%Y-%m-%d %H:%M} =====\n")
    def write(self, s):
        self.o.write(s); self.f.write(s); self.f.flush()
    def flush(self):
        self.o.flush(); self.f.flush()


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
        lote = filas[i:i + 500]
        for intento in range(3):
            try:
                r = requests.post(f"{SB_URL}/rest/v1/{tabla}", headers={**H, "Prefer": prefer}, data=json.dumps(lote), timeout=180)
                break
            except requests.RequestException as e:
                print(f"  {tabla} lote {i//500+1}: {e}; reintento…"); r = None
        if r is None or r.status_code >= 300:
            raise RuntimeError(f"{tabla} lote {i//500+1} (filas {i+1}-{i+len(lote)}): " + (f"HTTP {r.status_code} {r.text[:400]}" if r is not None else "sin respuesta"))
        print(f"  {tabla}: {i+len(lote)}/{len(filas)}")


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
    sys.stdout = _Tee(AQUI / "cargar_padron.log")
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
        if cat not in ("TORO", "VACA", "HEMBRA", "MACHO", "MIXTO"):
            sin_prop.add("CATEGORIA " + cat); continue
        bolsa = (f.get("bolsa") or "CLASIFICAR").strip().upper()
        obs = f"Bolsa: {bolsa}"
        nuevas.append({"numero": n, "estado": "activa", "propietario_id": pid, "categoria": cat,
                       "fecha_alta": f["fecha_alta"], "origen_alta": "padron_inicial",
                       "procedencia_alta": f.get("procedencia") or None, "bolsa": bolsa,
                       "actualizado_por": USUARIO})
        movs.append({"caravana": n, "tipo": "alta", "fecha": f["fecha_alta"], "propietario_id": pid, "categoria": cat,
                     "origen_destino": f.get("procedencia") or None, "fuente": "padron_inicial",
                     "observaciones": obs, "usuario": USUARIO})
    if sin_prop:
        sys.exit(f"Hay valores que no puedo mapear: {sorted(sin_prop)}")

    print(f"Filas en CSV: {len(filas)} · nuevas: {len(nuevas)} · ya existían: {omitidas}")
    if nuevas:
        post("caravanas", nuevas)
        print("Caravanas cargadas.")
    # movimientos de alta para toda caravana del padrón inicial que todavía no lo tenga
    con_mov = {m["caravana"] for m in get_all("movimientos", "select=caravana&tipo=eq.alta&fuente=eq.padron_inicial")}
    del_padron = {c["numero"]: c for c in get_all("caravanas", "select=numero,propietario_id,categoria,fecha_alta,procedencia_alta,bolsa&origen_alta=eq.padron_inicial")}
    faltan = [{"caravana": n, "tipo": "alta", "fecha": c["fecha_alta"], "propietario_id": c["propietario_id"], "categoria": c["categoria"],
               "origen_destino": c["procedencia_alta"], "fuente": "padron_inicial", "observaciones": ("Bolsa: " + c["bolsa"]) if c.get("bolsa") else None, "usuario": USUARIO}
              for n, c in del_padron.items() if n not in con_mov]
    print(f"Movimientos de alta a completar: {len(faltan)}")
    if faltan:
        post("movimientos", faltan)
    r = requests.post(f"{SB_URL}/rest/v1/rpc/marcar_salidas", headers=H, data="{}", timeout=120)
    print("Salidas marcadas (ya vendidas o muertas según WinCampo):", r.text)

    cargar_virgenes(existentes | {x["numero"] for x in nuevas})
    res = get_all("v_resumen", "select=*")
    print("\nResumen por propietario:")
    for x in res:
        print(f"  {x['propietario']:<13} activas {x['activas']:>5}  (salidas WinCampo {x['salidas_wincampo']:>4}, con 40 días {x['con_40_dias']:>5}, con 90 días {x['con_90_dias']:>5})  bajas {x['bajas']:>4}")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print("ERROR:", e)
        raise
