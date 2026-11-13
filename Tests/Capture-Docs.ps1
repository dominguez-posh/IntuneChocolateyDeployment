<#
.SYNOPSIS
    Renders the README screenshots (docs\screenshots\*.png, framed by Tests\Render-Showcase.ps1, plus hero.png) with the
    fakes of the GUI smoke test: demo data only.
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
# Frame every screenshot on the showcase stage (soft background, floating window) and compose hero.png
& (Join-Path $PSScriptRoot 'Render-Showcase.ps1') -Mode Shots -Source $work -OutDir $OutDir
"Screenshots written to $OutDir"
