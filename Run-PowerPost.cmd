@echo off
REM Double-click launcher for PowerPost. Starts the GUI under STA with no console window.
start "" powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0PowerPost.ps1"
