@echo off
cd /d "%~dp0"
echo Exploracion v3 (lst_trazabilidad / ingresos por caravana)... 1-3 minutos
python explorar_wincampo_v3.py > explor3_log.txt 2>&1
type explor3_log.txt
echo.
echo Listo. Podes cerrar esta ventana.
pause
