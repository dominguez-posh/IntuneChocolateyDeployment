<#
.SYNOPSIS
    Records the animated tour of the tool for the README (docs\screenshots\demo.webp).
.DESCRIPTION
    Starts the tool off-screen with the fakes of the GUI smoke test (fake IntuneWin32App module and sign-in, nothing
    reaches a tenant; package infos come from the real feeds), plays Tests\DemoDriver.ps1 and composes the frames with
    Tests\Render-Showcase.ps1 (floating window, camera zoom, title and end card) into an animated WebP (and an MP4 when an
    encoder is available).
.EXAMPLE
    .\Tests\Record-Demo.ps1
#>
[CmdletBinding()]
param(
    [string]$Output,
    [int]$Quality = 35
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot is empty in parameter defaults on Windows PowerShell 5.1
if (-not $Output) { $Output = Join-Path (Split-Path $PSScriptRoot -Parent) 'docs\screenshots\demo.webp' }
$frames = Join-Path ([IO.Path]::GetTempPath()) 'IntuneChocoShowcaseFrames'
if (Test-Path $frames) { Remove-Item $frames -Recurse -Force }
# Raw mode: pointer, click ring and captions are not drawn into the frames, the compositor adds them
$env:INTUNECHOCO_DEMO_RAW = '1'
try { & (Join-Path $PSScriptRoot 'Invoke-GuiSmoke.ps1') -OutDir $frames -Driver (Join-Path $PSScriptRoot 'DemoDriver.ps1') }
finally { Remove-Item Env:\INTUNECHOCO_DEMO_RAW -ErrorAction SilentlyContinue }
if (Test-Path (Join-Path $frames 'error.txt')) { throw (Get-Content (Join-Path $frames 'error.txt') -Raw) }
$list = Get-Content (Join-Path $frames 'frames.json') -Raw | ConvertFrom-Json
if (-not $list) { throw 'The tour wrote no frames.' }

# The compositor draws pointer, click ring and captions itself from frames.json and renders the showcase video
& (Join-Path $PSScriptRoot 'Render-Showcase.ps1') -Mode Video -Source $frames -OutDir (Split-Path $Output) -Quality $Quality
$seconds = [Math]::Round((($list | Measure-Object ms -Sum).Sum) / 1000, 1)
"Tour: $($list.Count) raw frames, $seconds s recorded -> $Output"
