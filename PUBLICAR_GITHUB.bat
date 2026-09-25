@echo off
rem Sube la carpeta al repo pecuariabulltrade/caravanas-pecuaria (GitHub Pages).
rem Usa las credenciales de GitHub guardadas en Windows (las mismas del portal PEGSA).
cd /d "%~dp0"
if not exist .git (
  git init
  git branch -M main
  git remote add origin https://github.com/pecuariabulltrade/caravanas-pecuaria.git
)
git add -A
git commit -m "Caravanas Pecuaria: app, esquema Supabase y script de sincronizacion" 
git push -u origin main
echo.
echo Si termino sin errores, la app queda en https://pecuariabulltrade.github.io/caravanas-pecuaria/ (tarda 1-2 min la primera vez)
pause
