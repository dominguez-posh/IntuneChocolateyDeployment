<#
.SYNOPSIS
    Renders the README screenshots (docs\screenshots\*.png) with the fakes of the GUI smoke test: demo data only.
.EXAMPLE
    .\Tests\Capture-Docs.ps1
#>
[CmdletBinding()]
param([string]$OutDir)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot is empty in parameter defaults on Windows PowerShell 5.1
if (-not $OutDir) { $OutDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'docs/screenshots' }
$work = Join-Path ([IO.Path]::GetTempPath()) 'IntuneChocoDocs'
& (Join-Path $PSScriptRoot 'Invoke-GuiSmoke.ps1') -OutDir $work -Driver (Join-Path $PSScriptRoot 'DocsDriver.ps1')
$log = Join-Path $work 'results.txt'
if (-not (Test-Path $log)) { throw 'The screenshot run wrote no results.' }
if (Get-Content $log | Where-Object { $_ -like 'FAIL*' }) { throw (Get-Content $log -Raw) }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
foreach ($name in 'start', 'apps', 'deploy', 'tenant', 'schedule', 'status', 'import', 'activity', 'settings') {
    $file = Join-Path $work "$name.png"
    if (Test-Path $file) { Copy-Item $file (Join-Path $OutDir "$name.png") -Force } else { Write-Warning "$name.png was not rendered" }
}
"Screenshots written to $OutDir"
