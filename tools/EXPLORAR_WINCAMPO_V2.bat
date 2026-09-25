@echo off
cd /d "%~dp0"
echo Exploracion v2 (busca ingresos por caravana)... 1-3 minutos
python explorar_wincampo_v2.py > explor2_log.txt 2>&1
type explor2_log.txt
echo.
echo Listo. Podes cerrar esta ventana.
pause
