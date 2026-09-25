@echo off
cd /d "%~dp0"
echo Carga inicial historica desde 2026-01-01 (inicio de las caravanas 032) (puede tardar varios minutos)
python sync_wincampo.py --modo full --desde 2026-01-01
pause
