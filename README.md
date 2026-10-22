# Caravanas Pecuaria

Padrón de caravanas electrónicas (SENASA) del grupo Bulltrade / PEGSA, vinculado a WinCampo Web.

- `index.html` — app (GitHub Pages). Completar `SUPABASE_URL` y `SUPABASE_ANON_KEY` al inicio del `<script>`.
- `supabase/schema.sql` — esquema completo: correr en el SQL Editor del proyecto Supabase `caravanas-pecuaria`.
- `sync/sync_wincampo.py` — script de sincronización (corre en la PC de la oficina, tarea programada).
- `tools/` — utilidades de exploración de la API de WinCampo.
- `manga-app/` — app Android "Lector de Manga" (tablet + balanza XR5000); el APK lo compila GitHub Actions (`.github/workflows/manga-app.yml`) y queda en Releases. Instalación: `manga-app/INSTALAR.md`.

Diseño funcional: documento "Caravanas Pecuaria — Diseño funcional" en Claude.
