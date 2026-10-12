@echo off
cd /d "%~dp0"
echo ============================================
echo   GitHub Fast Fix  (about 60-120 seconds)
echo   Admin privileges will be requested
echo ============================================
powershell -ExecutionPolicy Bypass -File "%~dp0fix-github-fast.ps1"