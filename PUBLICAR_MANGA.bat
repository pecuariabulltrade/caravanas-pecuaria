@echo off
rem Publica la app Lector de Manga: copia el workflow de GitHub Actions a su lugar y sube todo al repo.
rem Al terminar, GitHub Pages actualiza el portal (pestana Sesiones) y Actions compila el APK (5-8 min):
rem   https://github.com/pecuariabulltrade/caravanas-pecuaria/actions
rem   https://github.com/pecuariabulltrade/caravanas-pecuaria/releases/latest
cd /d "%~dp0"
if not exist .github\workflows mkdir .github\workflows
copy /y manga-app\github\manga-app.yml .github\workflows\manga-app.yml >nul
git add -A
git commit -m "Lector de Manga: app Android (tablet + XR5000), pestana Sesiones del portal y patch SQL"
git push origin main
echo.
echo Listo. Mira la compilacion del APK en https://github.com/pecuariabulltrade/caravanas-pecuaria/actions
pause
