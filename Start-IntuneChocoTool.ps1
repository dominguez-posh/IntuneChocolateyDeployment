# Deprecated name: the tool is called PackTune now. This file only forwards to Start-PackTune.ps1.
Write-Warning 'Start-IntuneChocoTool.ps1 is deprecated, use Start-PackTune.ps1 (or Start.cmd).'
& (Join-Path $PSScriptRoot 'Start-PackTune.ps1') @args
