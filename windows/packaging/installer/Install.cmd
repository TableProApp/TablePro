@echo off
rem Double-click to install TablePro for this user. PowerShell's default policy blocks a downloaded script, so the
rem policy is lifted for this one run only.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Launch %*
if errorlevel 1 pause
