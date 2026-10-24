@echo off
rem Prueba del robot VISEC con el navegador visible (para ver que entra bien).
cd /d "%~dp0"
set VISEC_VISIBLE=1
set VISEC_LOTE=3
set VISEC_PARALELO=1
set VISEC_MAX_MIN=30
python visec_consulta.py
pause
