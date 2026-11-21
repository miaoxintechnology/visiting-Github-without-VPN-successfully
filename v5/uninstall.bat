@echo off
cd /d "%~dp0"
echo ============================================
echo   GitHub Rollback - undo ALL changes
echo   (hosts / proxy / certificate / config)
echo ============================================
powershell -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"