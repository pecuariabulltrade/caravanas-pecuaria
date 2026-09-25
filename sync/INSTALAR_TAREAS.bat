@echo off
rem Crea las dos tareas programadas de Windows para Caravanas Pecuaria.
rem Ejecutar una sola vez, con doble clic, en la PC de la oficina.
set D=%~dp0
schtasks /Create /F /TN "CaravanasPecuaria_Diaria" /SC DAILY /ST 07:00 /TR "\"%D%SYNC_FULL.bat\"" /RL LIMITED
schtasks /Create /F /TN "CaravanasPecuaria_Refrescar" /SC MINUTE /MO 2 /TR "\"%D%SYNC_POLL.bat\"" /RL LIMITED
echo.
echo Tareas creadas: CaravanasPecuaria_Diaria (07:00) y CaravanasPecuaria_Refrescar (cada 2 min).
pause
