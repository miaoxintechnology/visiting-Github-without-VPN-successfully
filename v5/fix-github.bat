@echo off
cd /d "%~dp0"
echo ============================================
echo   GitHub Auto Fix v4
echo   (detects SNI blocking and configures proxy)
echo ============================================
powershell -ExecutionPolicy Bypass -File "%~dp0fix-github.ps1"