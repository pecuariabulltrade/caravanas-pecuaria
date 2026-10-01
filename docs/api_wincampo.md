# API de WinCampo Web (feedlot El Haras) — ingresos, egresos y stock

Referencia de lo que usa `sync/sync_wincampo.py` de Caravanas Pecuaria, para reutilizar en otros proyectos.
Es la misma API REST que usa la pantalla de WinCampo Web (https://elgarabi.wincampo.com) y el portal PEGSA.

**Base:** `https://elgarabi-api.wincampo.com/api/`
**Credenciales:** las de WinCampo Web (`WINCAMPO_EMAIL` / `WINCAMPO_PASSWORD` en `sync\.env` o en el `.env` del PEGSA_Portal). No van en el código.
**Cabeceras:** `Accept: application/json`, `Content-Type: application/json`, y después del login `Authorization: Bearer <token>`.
**Fechas de entrada:** siempre `AAAAMMDD` (p. ej. `20260101`). Las fechas que devuelve vienen como `AAAA-MM-DD HH:MM:SS`.

## 1. Login

```
POST login
{"email": "...", "password": "...", "idioma": "es"}
```
Devuelve una lista con un objeto: `[{"token": "...", "nombre": "NICOLAS", ...}]`. Si una llamada devuelve **401**, volver a hacer login y repetir.

## 2. Ingresos por caravana (fuente principal)

Es el reporte "Ingresos por Caravana" de la pantalla Trazabilidad (`#/lst_trazabilidad`).

```
GET lst_trazabilidad
  fecha_desde=AAAAMMDD  fecha_hasta=AAAAMMDD
  reporte_elegido=ingreso_caravana
  extendido_sino=N  new_version_sino=S  inicia_termina_sino=N  resumen_sino=N  comparar_pesada_anterior_sino=N
```
Respuesta: `{"lst_trazabilidad": [ ... ]}`, una fila por animal:
`FECHA_INGRESO, NRO_TROPA, HOTELERO, NRO_CARAVANA (visual), RFID (electrónica 032…), CATEGORIA, KG_INGRESO, NRO_CORRAL`.

## 3. Tropas de ingreso (para enriquecer: DTE, proveedor, consignatario)

```
GET lst_movimiento_hacienda
  fecha_desde=AAAAMMDD  fecha_hasta=AAAAMMDD
  reporte_elegido=ingreso_hacienda  agrupado=N  visualiza_dte=S
```
Respuesta: `{"lst_movimiento_hacienda": [ ... ]}`, una fila por tropa:
`NRO_TROPA, DTE_INGRESO ("SIN DTE" cuando no hay), PROVEEDOR, CONSIGNATARIO, ORIGEN, HOTELERO, ...`.
Un ingreso es **traslado** (no compra) cuando `CONSIGNATARIO` es `TRASLADO` o `DESTETE`, `ORIGEN = TRASLADO` o el `DTE_INGRESO` empieza con `TRASLADO`.

## 4. Egresos por caravana

```
GET lst_egresos_hacienda
  fecha_desde=AAAAMMDD  fecha_hasta=AAAAMMDD
  filtro_tropa_caravana=por_caravana
```
**Tope: 500 días por llamada** (si el rango es mayor, partirlo en tramos).
Respuesta anidada: `{"lst_egresos_hacienda": [ {HOTELERO, tropas: [ {NRO_TROPA, detalle: [ ... ]} ]} ]}`.
Cada fila de `detalle`: `RFID, NRO_CARAVANA, FECHA_EGRESO, FECHA_INGRESO, DESTINO, CATEGORIA, MOTIVO, NRO_TRANSACCION, ORIGEN, NRO_CORRAL`.
`MOTIVO`: **V** = venta, **M** = muerte, **T** = traslado.

## 5. Stock actual

```
GET caravanas_stock
```
Respuesta: `{"data": [ ... ]}` (o una lista directa), una fila por animal en stock:
`RFID, NRO_CARAVANA, NRO_TROPA, FECHA_INGRESO, HOTELERO, CATEGORIA_ACTUAL, CATEGORIA_INGRESO, NRO_CORRAL, CONSIGNATARIO, PROVEEDOR_TROPA, ...`.

## Mapeos que usamos

- Categorías WinCampo → padrón: `TO→TORO`, `VA→VACA`, `VQ/TH→HEMBRA`, `TM/NT/NV→MACHO`.
- Hotelero → propietario: `PEGSA→PEGSA`, `BULLTRADE SRL→BULLTRADE`, `DARWASH SA→DARWASH`, `LAS TAPERAS→LAS TAPERAS`, `EL SAGUAIPE SAS→EL SAGUIPE`.
- Caravana electrónica válida: `^032\d{12}$` (15 dígitos).

## Ejemplo mínimo en Python

```python
import requests
API = "https://elgarabi-api.wincampo.com/api/"
s = requests.Session(); s.headers.update({"Accept": "application/json", "Content-Type": "application/json"})
d = s.post(API + "login", json={"email": EMAIL, "password": PASSWORD, "idioma": "es"}, timeout=30).json()
s.headers["Authorization"] = "Bearer " + (d[0] if isinstance(d, list) else d)["token"]

ing = s.get(API + "lst_trazabilidad", params={"fecha_desde": "20260101", "fecha_hasta": "20261001",
      "reporte_elegido": "ingreso_caravana", "extendido_sino": "N", "new_version_sino": "S",
      "inicia_termina_sino": "N", "resumen_sino": "N", "comparar_pesada_anterior_sino": "N"}, timeout=180).json()["lst_trazabilidad"]

egr = s.get(API + "lst_egresos_hacienda", params={"fecha_desde": "20260101", "fecha_hasta": "20261001",
      "filtro_tropa_caravana": "por_caravana"}, timeout=180).json()["lst_egresos_hacienda"]
detalle = [x | {"HOTELERO": h["HOTELERO"], "NRO_TROPA": t["NRO_TROPA"]} for h in egr for t in h["tropas"] for x in t["detalle"]]
```

## Alternativa: leer el espejo en Supabase

Si el otro proyecto no necesita hablar con WinCampo, los mismos datos ya están limpios (solo 032, desde 01/01/2026, sincronizados una vez por día) en el Supabase de Caravanas Pecuaria:
`https://xqcipsnyvnozkvehpzsk.supabase.co/rest/v1/` → tablas `wc_ingresos`, `wc_egresos`, `wc_stock` y vistas `v_ingresos_cruce`, `v_egresos_cruce`, `v_stock_cruce`.
Requiere un usuario de la app (login Supabase Auth) o la service key de `sync\.env`; el anon no tiene acceso.

## Notas

- Los scripts que llaman a WinCampo o Supabase hay que correrlos en la PC de la oficina (desde la nube no se llega).
- Entre llamadas conviene una pausa corta (0,3 s) y reintentos ante 5xx.
- Esta API es la de la base SQL Server congelada desde junio 2026 → WinCampo Web; los nombres de campos se tomaron del código de la pantalla el 25/09/2026.
