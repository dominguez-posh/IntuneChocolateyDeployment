<#
.SYNOPSIS
    Composes the README media: the animated intro (docs\screenshots\demo.webp, demo.mp4) from the raw demo frames, or the framed
    screenshots and hero.png from the raw screenshots.
.DESCRIPTION
    Helper: Tests\showcase.py. Needs, all without admin rights: Python 3.12 with Pillow and numpy (installed with
    pip install --user when missing), img2webp from libwebp (winget install Google.Libwebp) for the video, oxipng
    (winget install Shssoichiro.Oxipng) for smaller PNGs. demo.mp4 is only written when imageio-ffmpeg (bundled ffmpeg,
    pip install --user imageio-ffmpeg) is available.
.EXAMPLE
    .\Tests\Render-Showcase.ps1 -Mode Shots -Source $env:TEMP\IntuneChocoDocs
    .\Tests\Render-Showcase.ps1 -Mode Video -Source $env:TEMP\IntuneChocoDemo
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Video', 'Shots')][string]$Mode,
    [Parameter(Mandatory)][string]$Source,
    [string]$OutDir,
    [string]$Title = 'PackTune',
    [string]$Subtitle = 'winget and Chocolatey apps for Intune',
    [string]$Url = 'github.com/dominguez-posh/PackTune',
    [int]$Quality = 35,
    [int]$Fps = 30,
    [double]$TourSeconds = 40
)

$ErrorActionPreference = 'Stop'
if (-not $OutDir) { $OutDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'docs\screenshots' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$python = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
if (-not $python) { $python = (Get-Command py.exe -ErrorAction SilentlyContinue).Source }
if (-not $python) { throw 'Python 3 was not found.' }
function Test-Module([string]$Import) { $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { & $python -c "import $Import" 2>&1 | Out-Null; $LASTEXITCODE -eq 0 } finally { $ErrorActionPreference = $old } }
if (-not (Test-Module 'PIL, numpy')) { & $python -m pip install --user --quiet Pillow numpy; if ($LASTEXITCODE -ne 0) { throw 'pip install --user Pillow numpy failed' } }

function Find-Tool([string]$Exe, [string]$Package) {
    $c = (Get-Command $Exe -ErrorAction SilentlyContinue).Source
    if (-not $c) { $c = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\$Package*" -Recurse -Filter $Exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
    $c
}
$helper = Join-Path $PSScriptRoot 'showcase.py'

if ($Mode -eq 'Shots') {
    $args2 = @($helper, 'shots', '--src', $Source, '--out', $OutDir)
    $oxi = Find-Tool 'oxipng.exe' 'Shssoichiro.Oxipng'
    if ($oxi) { $args2 += '--oxipng', $oxi } else { Write-Warning 'oxipng not found, PNGs stay larger (winget install Shssoichiro.Oxipng)' }
    & $python @args2
    if ($LASTEXITCODE -ne 0) { throw "showcase.py failed with exit code $LASTEXITCODE" }
}
else {
    $img2webp = Find-Tool 'img2webp.exe' 'Google.Libwebp'
    if (-not $img2webp) { throw 'img2webp.exe was not found. Install it with: winget install Google.Libwebp' }
    if (-not (Test-Module 'imageio_ffmpeg')) { $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; & $python -m pip install --user --quiet imageio-ffmpeg 2>&1 | Out-Null; $ErrorActionPreference = $old }
    $args2 = @($helper, 'video', '--frames', $Source, '--out', (Join-Path $OutDir 'demo.webp'), '--img2webp', $img2webp,
        '--title', $Title, '--subtitle', $Subtitle, '--url', $Url, '--quality', $Quality, '--fps', $Fps, '--tour-seconds', $TourSeconds)
    if (Test-Module 'imageio_ffmpeg') { $args2 += '--mp4', (Join-Path $OutDir 'demo.mp4') } else { Write-Warning 'No ffmpeg encoder available, demo.mp4 is skipped.' }
    & $python @args2
    if ($LASTEXITCODE -ne 0) { throw "showcase.py failed with exit code $LASTEXITCODE" }
}
