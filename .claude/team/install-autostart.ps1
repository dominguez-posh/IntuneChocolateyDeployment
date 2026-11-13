# Registers a scheduled task "IntuneChocoDeployment CTO" that runs autostart.ps1 at sign-in of the current user.
# Run once by hand: powershell -File .claude\team\install-autostart.ps1   (remove: Unregister-ScheduledTask "IntuneChocoDeployment CTO")
$script = Join-Path $PSScriptRoot 'autostart.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName 'IntuneChocoDeployment CTO' -Action $action -Trigger $trigger -Settings $settings -Description 'Starts the IntuneChocoDeployment CTO session at sign-in' -Force | Out-Null
Write-Host 'Task "IntuneChocoDeployment CTO" registered.'
