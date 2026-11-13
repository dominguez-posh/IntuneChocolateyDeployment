<#
.SYNOPSIS
    Records the animated tour of the tool for the README (docs\screenshots\demo.webp).
.DESCRIPTION
    Starts the tool off-screen with the fakes of the GUI smoke test (fake IntuneWin32App module and sign-in, nothing
    reaches a tenant; package infos come from the real feeds), plays Tests\DemoDriver.ps1 and turns the frames into an
    animated WebP with img2webp from libwebp (winget install Google.Libwebp).
.EXAMPLE
    .\Tests\Record-Demo.ps1
#>
[CmdletBinding()]
param(
    [string]$Output,
    [int]$Quality = 80
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot is empty in parameter defaults on Windows PowerShell 5.1
if (-not $Output) { $Output = Join-Path (Split-Path $PSScriptRoot -Parent) 'docs\screenshots\demo.webp' }
$img2webp = (Get-Command img2webp.exe -ErrorAction SilentlyContinue).Source
if (-not $img2webp) {
    $img2webp = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.Libwebp*" -Recurse -Filter img2webp.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $img2webp) { throw 'img2webp.exe was not found. Install it with: winget install Google.Libwebp' }

$frames = Join-Path ([IO.Path]::GetTempPath()) 'IntuneChocoDemo'
& (Join-Path $PSScriptRoot 'Invoke-GuiSmoke.ps1') -OutDir $frames -Driver (Join-Path $PSScriptRoot 'DemoDriver.ps1')
if (Test-Path (Join-Path $frames 'error.txt')) { throw (Get-Content (Join-Path $frames 'error.txt') -Raw) }
$list = Get-Content (Join-Path $frames 'frames.json') -Raw | ConvertFrom-Json
if (-not $list) { throw 'The tour wrote no frames.' }

# Frames that look the same are merged by img2webp; the last frame stays a little longer before the loop starts again
$arguments = @('-loop', '0', '-mixed', '-q', $Quality, '-m', '4')
for ($i = 0; $i -lt $list.Count; $i++) {
    $ms = if ($i -eq $list.Count - 1) { 1500 } else { [Math]::Max(40, [int]$list[$i].ms) }
    $arguments += '-d', $ms, $list[$i].file
}
New-Item -ItemType Directory -Path (Split-Path $Output) -Force | Out-Null
$arguments += '-o', $Output
# Short relative frame names keep hundreds of frames within the command line limit
Push-Location $frames
try { & $img2webp @arguments | Out-Null } finally { Pop-Location }
if ($LASTEXITCODE -ne 0) { throw "img2webp failed with exit code $LASTEXITCODE" }
$seconds = [Math]::Round((($list | Measure-Object ms -Sum).Sum) / 1000, 1)
"Tour: $($list.Count) frames, $seconds s, $([Math]::Round((Get-Item $Output).Length / 1MB, 1)) MB -> $Output"
