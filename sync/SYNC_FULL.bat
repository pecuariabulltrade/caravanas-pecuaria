@echo off
cd /d "%~dp0"
rem PAUSA (Cowork 05/11/2026, pedido de Nicolas): con WINCAMPO_PAUSA.txt en esta carpeta no se consulta WinCampo. Borrar el archivo para reanudar.
if exist "%~dp0WINCAMPO_PAUSA.txt" exit /b 0
python sync_wincampo.py --modo full
