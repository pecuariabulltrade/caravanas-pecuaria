@echo off
rem Detiene el robot VISEC que corre en segundo plano. Primero le pide que termine los lotes abiertos
rem (puede tardar hasta media hora); si se prefiere cortar ya, responder S a la pregunta.
cd /d "%~dp0"
if not exist visec_consulta.lock (
  echo El robot VISEC no esta corriendo.
  pause
  exit /b
)
set /p PID=<visec_consulta.lock
echo. > visec_consulta.stop
echo Le pedi al robot (proceso %PID%) que termine los lotes abiertos y salga.
set /p R=Cortarlo ahora mismo sin esperar? (S/N):
if /i "%R%"=="S" (
  taskkill /PID %PID% /T /F
  del visec_consulta.lock
  del visec_consulta.stop
  echo Robot cortado. Los lotes que estaban abiertos quedan en VISEC sin descartar; no es grave.
)
echo La tarea de cada hora lo vuelve a lanzar sola; para lanzarlo ya, usar INICIAR_VISEC.bat.
pause
