<#
.SYNOPSIS
    Smoke test of the graphical interface: starts Start-IntuneChocoTool.ps1 off-screen with a fake IntuneWin32App
    module, drives every page (sign-in, catalog, search, custom icon, deployments, tenant, settings, sign-out) and
    checks the results. No window or dialog shows up on the desktop, nothing is sent to a tenant.
.DESCRIPTION
    Runs in a separate Windows PowerShell 5.1 process with its own %LOCALAPPDATA% (settings, work folder, fake tenant).
    Package infos are read from the real Chocolatey feed; an existing feed cache of this user is copied in first so
    the feed is asked as little as possible. Screenshots of every page land in -OutDir.
.EXAMPLE
    .\Tests\Invoke-GuiSmoke.ps1
#>
[CmdletBinding()]
param([string]$OutDir = (Join-Path ([IO.Path]::GetTempPath()) 'IntuneChocoSmoke'))

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
$appData = Join-Path $OutDir 'appdata'
New-Item -ItemType Directory -Path (Join-Path $appData 'IntuneChocoDeployment') -Force | Out-Null
@{ TenantID = 'contoso.onmicrosoft.com'; ClientID = '11111111-2222-3333-4444-555555555555' } | ConvertTo-Json |
    Set-Content (Join-Path $appData 'IntuneChocoDeployment\settings.json')
$cache = Join-Path $env:LOCALAPPDATA 'IntuneChocoDeployment\feedcache.json'
if (Test-Path $cache) { Copy-Item $cache (Join-Path $appData 'IntuneChocoDeployment\feedcache.json') }

$results = Join-Path $OutDir 'results.txt'
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$psi.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $repo 'Start-IntuneChocoTool.ps1')
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.EnvironmentVariables['LOCALAPPDATA'] = $appData
$psi.EnvironmentVariables['PSModulePath'] = (Join-Path $PSScriptRoot 'Fakes') + ';' + "$env:USERPROFILE\Documents\WindowsPowerShell\Modules;$env:ProgramFiles\WindowsPowerShell\Modules;$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules"
$psi.EnvironmentVariables['INTUNECHOCO_SMOKE'] = Join-Path $PSScriptRoot 'GuiSmokeDriver.ps1'
$psi.EnvironmentVariables['INTUNECHOCO_SMOKE_OUT'] = $OutDir
$process = [System.Diagnostics.Process]::Start($psi)
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
if (-not $process.WaitForExit(15 * 60 * 1000)) { $process.Kill(); throw 'The GUI smoke test did not finish within 15 minutes.' }
if ($stderr.Result.Trim()) { "--- stderr ---"; $stderr.Result }
if (-not (Test-Path $results)) { "--- stdout ---"; $stdout.Result; throw 'The GUI smoke test wrote no results.' }
Get-Content $results
$failed = @(Get-Content $results | Where-Object { $_ -like 'FAIL*' }).Count
"Screenshots: $OutDir"
if ($failed -gt 0) { throw "$failed check(s) failed." }
'All checks passed.'
