@echo off
rem Starts Intune Chocolatey Deployment by double-click (Windows PowerShell 5.1), like the M365 MFA tool:
rem -ExecutionPolicy Bypass applies to this process only and changes no system setting.
rem -WindowStyle Hidden + -HideConsole: no console window next to the tool.
rem conhost.exe: classic console host, so that Windows Terminal does not take the window over.
rem PSModulePath is cleared so that Windows PowerShell uses its own module paths, also when started from PowerShell 7.
set "PSModulePath="
start "" conhost.exe powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Start-IntuneChocoTool.ps1" -HideConsole
