@echo off
rem Instala Playwright (navegador para el robot de VISEC). Correr una sola vez, con doble clic.
cd /d "%~dp0"
python -m pip install --upgrade playwright python-dotenv requests
python -m playwright install chromium
echo.
echo Listo. Ahora agrega VISEC_USUARIO y VISEC_CLAVE en sync\.env y proba con VISEC_PRUEBA.bat
pause
