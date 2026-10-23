@echo off
rem Crea las tareas programadas de Windows para Caravanas Pecuaria (ventana oculta).
rem Ejecutar una sola vez, con doble clic, en la PC de la oficina. Se puede volver a correr: reemplaza las tareas.
set D=%~dp0
schtasks /Delete /F /TN "CaravanasPecuaria_Horaria" >nul 2>&1
schtasks /Create /F /TN "CaravanasPecuaria_Diaria" /SC DAILY /ST 07:05 /TR "wscript.exe //B \"%D%oculto.vbs\" \"%D%SYNC_FULL.bat\"" /RL LIMITED
schtasks /Create /F /TN "CaravanasPecuaria_VISEC" /SC HOURLY /MO 1 /ST 00:10 /TR "wscript.exe //B \"%D%oculto.vbs\" \"%D%VISEC_CONSULTA.bat\"" /RL LIMITED
schtasks /Create /F /TN "CaravanasPecuaria_Refrescar" /SC MINUTE /MO 2 /TR "wscript.exe //B \"%D%oculto.vbs\" \"%D%SYNC_POLL.bat\"" /RL LIMITED
echo.
echo Tareas creadas (sin ventana): CaravanasPecuaria_Diaria (07:05), CaravanasPecuaria_VISEC (cada hora, dia y noche: consulta VISEC de las caravanas activas) y CaravanasPecuaria_Refrescar (cada 2 min, solo atiende el boton Refrescar).
pause
