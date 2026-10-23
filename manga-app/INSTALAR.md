# Lector de Manga — instalación y puesta en marcha

App para tablet Android que, conectada a la balanza Tru-Test XR5000, controla cada caravana leída contra el padrón SENASA de Caravanas Pecuaria y la pinta en verde, amarillo o rojo. Las sesiones cerradas se envían al portal (pestaña **Sesiones**).

Carpeta `manga-app/` del repo `pecuariabulltrade/caravanas-pecuaria`. El APK lo compila GitHub Actions y lo publica en
https://github.com/pecuariabulltrade/caravanas-pecuaria/releases/latest

## 1. Base de datos (una sola vez, desde la PC)

1. Supabase > SQL Editor > correr `supabase/patch_2026-10-22_sesiones_manga.sql` completo.
2. Supabase > Authentication > Users > **Add user**: email `manga@pecuariabulltrade.com` (o el que prefieras), una contraseña, y marcar *Auto confirm user*.
3. SQL Editor: `insert into operarios_manga (email) values ('manga@pecuariabulltrade.com');`
   Ese usuario solo puede leer el padrón y subir sesiones; no puede cargar ni modificar nada del portal.

## 2. Publicar el portal y compilar el APK

1. Los archivos ya están en `Documents\GitHub\caravanas-pecuaria` de la PC de la oficina (carpeta `manga-app/`, `index.html` con la pestaña Sesiones y `supabase/patch_2026-10-22_sesiones_manga.sql`).
2. Ejecutar `PUBLICAR_MANGA.bat` (copia el workflow `manga-app/github/manga-app.yml` a `.github/workflows/` y sube todo). Al subir:
   - GitHub Pages actualiza el portal con la pestaña Sesiones (1–2 min).
   - GitHub Actions compila el APK (5–8 min) y lo publica en *Releases*. Se puede seguir en la pestaña **Actions** del repo.
3. Si la compilación falla, en Actions se ve el error; pasarlo a Claude para corregirlo.

## 3. Instalar en la tablet (Android 8 o superior)

1. En la tablet, abrir Chrome e ir a https://github.com/pecuariabulltrade/caravanas-pecuaria/releases/latest
2. Tocar el archivo `LectorManga-1.0.N.apk` para descargarlo y después abrirlo desde la barra de descargas.
3. Si Android pide permiso para "instalar apps desconocidas" de Chrome, aceptarlo e instalar.
4. Abrir **Lector de Manga**. La primera vez pide:
   - **Usuario del portal**: el email y la contraseña del paso 1 → *Probar y guardar* (queda guardado; no se vuelve a pedir).
   - **Balanza**: Bluetooth o cable USB-C (ver punto 4).
5. Para actualizar a una versión nueva: desinstalar la app y volver a instalar el APK nuevo (si no se configuró firma estable, ver abajo).

## 4. Conectar el lector (balanza o bastón)

En ⚙ Configuración → Conexión hay tres opciones:
- **Balanza XR5000 por Bluetooth**: el bastón va conectado a la balanza y la balanza manda la caravana a la tablet.
- **Bastón XRS2i directo por Bluetooth**: el bastón manda la caravana directo a la tablet (sin balanza).
- **Balanza XR5000 por cable USB-C**.

### Bastón XRS2i directo
1. En el bastón: *Settings → Bluetooth*: **Manual**; en *Advanced*: **Connect Mode: Default** y **Output: Default**.
2. En la tablet: *Ajustes → Bluetooth* → emparejar con el XRS2i (PIN `0000` o `1234` si lo pide).
3. En la app: Configuración → Conexión: *Bastón XRS2i directo* → elegirlo en la lista → *Probar conexión*. Leer una caravana y mirar en Diagnóstico que llegue.
4. El bastón se conecta a un solo equipo a la vez: si está vinculado a la balanza, no puede mandarle a la tablet (y al revés). Para trabajar con la balanza, volver a la opción *Balanza XR5000 por Bluetooth*.

### Balanza XR5000 por Bluetooth
1. En el XR5000: *Settings > Bluetooth*: encendido y visible (discoverable). El bastón ya tiene que estar conectado a la balanza.
2. En la tablet: *Ajustes > Bluetooth* > emparejar con el XR5000 (aparece como "XR5000" + número). Si pide PIN, probar `0000` o `1234`.
3. En el XR5000: *Settings > Connections* (o *Output*): **Output: EID, Weight when weight is recorded**. Con esto la balanza manda la caravana a la tablet cada vez que registra un animal.
4. En la app: ⚙ Configuración > Conexión: Bluetooth > elegir el XR5000 en la lista > *Probar conexión con la balanza*.
5. Registrar un peso en la balanza y mirar en **Diagnóstico** que llegue una línea con la caravana (15 dígitos).

### Por cable USB-C (alternativa)
- Opción A: cable del puerto mini-USB del XR5000 a USB-C de la tablet (adaptador OTG si hace falta).
- Opción B: cable serie del XR5000 (adaptador C16) a un conversor serie→USB (FTDI, Prolific o Silicon Labs) y de ahí a la tablet.
- En la app: Configuración > Conexión: Cable USB-C > velocidad 9600 (o la que tenga el XR5000 en *Settings > Serial*) > *Probar conexión*. Android pregunta si permite que la app use el USB: aceptar.
- Pendiente de probar en campo cuál de las dos opciones funciona; Diagnóstico muestra lo que llega.

## 5. Uso diario

1. **Iniciar trabajo de manga** → chequeo: balanza, internet, padrón (se descarga actualizado si hay wifi; si no, usa la última copia) y envío de sesiones pendientes.
2. Elegir **destino** (Exportación exige 90 días desde la activación en SENASA; Consumo no controla días), **categoría** (HEMBRA, VACA o MACHO, que incluye TORO) y **propietario**.
3. Leer: cada caravana pinta la pantalla.
   - **Verde**: coincide.
   - **Amarillo**: hembra/vaca cruzadas, toro en sesión de machos, categoría MIXTO o caravana repetida en la sesión.
   - **Rojo**: no está en el padrón, dada de baja, otro propietario, categoría opuesta o sin 90 días (exportación). Rojo manda sobre amarillo; el cartel muestra todos los motivos.
4. **Ingresar a mano**: últimos 6 dígitos (o el número completo). Si varias terminan igual, se elige de la lista.
5. **Ver listado**: filtro por color y botón *Borrar* (con confirmación). Las borradas quedan registradas aparte.
6. **Cerrar sesión**: resumen y envío al portal. Sin wifi queda pendiente y se envía sola después (o con *Reenviar ahora* en el inicio).
7. En el portal, pestaña **Sesiones**: lista, detalle por caravana, filtros y exportación a Excel.

## 6. Firma estable del APK (opcional, para actualizar sin desinstalar)

En el repo, *Settings > Secrets and variables > Actions*, crear:
- `MANGA_KEYSTORE_B64`: un keystore en base64 (`keytool -genkeypair -alias manga -keyalg RSA -keysize 2048 -validity 10000 -keystore manga.jks` y después `base64 -w0 manga.jks`).
- `MANGA_KEYSTORE_PASS`: la contraseña del keystore (misma para la clave).
Las compilaciones siguientes salen firmadas siempre igual y Android las instala encima de la anterior. Hay que desinstalar una sola vez la versión firmada con debug.

## 7. Pruebas automáticas (PC)

- `node manga-app/tools/test_rules.js` — reglas de colores.
- `node manga-app/tools/test_ui.js` — pantallas de la app con balanza y Supabase simulados (requiere Playwright).
- `node manga-app/tools/test_portal.js` — pestaña Sesiones del portal.
