@echo off
rem Crea las tareas programadas de Windows para Caravanas Pecuaria (ventana oculta).
rem Ejecutar una sola vez, con doble clic, en la PC de la oficina. Se puede volver a correr: reemplaza las tareas.
set D=%~dp0
schtasks /Delete /F /TN "CaravanasPecuaria_Diaria" >nul 2>&1
schtasks /Create /F /TN "CaravanasPecuaria_Horaria" /SC HOURLY /MO 1 /ST 07:05 /TR "wscript.exe //B \"%D%oculto.vbs\" \"%D%SYNC_FULL.bat\"" /RL LIMITED
schtasks /Create /F /TN "CaravanasPecuaria_Refrescar" /SC MINUTE /MO 2 /TR "wscript.exe //B \"%D%oculto.vbs\" \"%D%SYNC_POLL.bat\"" /RL LIMITED
echo.
echo Tareas creadas (sin ventana): CaravanasPecuaria_Horaria (cada hora) y CaravanasPecuaria_Refrescar (cada 2 min, atiende el boton Refrescar).
pause
