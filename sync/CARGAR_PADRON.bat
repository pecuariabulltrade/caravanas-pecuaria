@echo off
cd /d "%~dp0"
echo Cargando el padron inicial de caravanas 032 en Supabase...
python cargar_padron.py
echo.
pause
