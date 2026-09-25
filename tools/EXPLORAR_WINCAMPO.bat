@echo off
cd /d "%~dp0"
echo Explorando WinCampo Web... (1-3 minutos)
python explorar_wincampo.py > explor\_log.txt 2>&1
type explor\_log.txt
echo.
echo Listo. Podes cerrar esta ventana.
pause
