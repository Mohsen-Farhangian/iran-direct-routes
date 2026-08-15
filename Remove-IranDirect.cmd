@echo off
net session >nul 2>&1
if %errorLevel% neq 0 (
  echo Requesting Administrator rights...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0IranDirect.ps1" -Action Remove
echo.
pause
