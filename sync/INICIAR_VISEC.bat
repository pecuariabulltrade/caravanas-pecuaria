@echo off
rem Lanza el robot VISEC en segundo plano (sin ventana), igual que la tarea programada de cada hora.
cd /d "%~dp0"
if exist visec_consulta.stop del visec_consulta.stop
wscript.exe //B "%~dp0oculto.vbs" "%~dp0VISEC_CONSULTA.bat"
echo Robot VISEC lanzado en segundo plano. El avance se ve en Inicio del portal o en visec_consulta.log.
pause
