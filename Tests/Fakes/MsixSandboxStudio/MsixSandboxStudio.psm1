# Fake MSIX Sandbox Studio for the GUI smoke test: writes the project to a folder and reports "Passed"; no sandbox opens.
$Root = Join-Path $env:LOCALAPPDATA "fake-sandbox"
function New-Win32Detection { param([string]$Type = "Script") [ordered]@{ Type = $Type } }
function Save-Win32AppProject {
    param([string]$Id, [string]$DisplayName, [string]$Publisher, [string]$Version, $Detection, [string]$RunAs, [hashtable]$Scripts)
    $Source = Join-Path $Root "$Id\source"
    New-Item -Path $Source -ItemType Directory -Force | Out-Null
    foreach ($Name in $Scripts.Keys) { Set-Content -Path (Join-Path $Source $Name) -Value $Scripts[$Name] -Encoding ASCII }
    [pscustomobject]@{ Id = $Id; DisplayName = $DisplayName; Version = $Version; SourcePath = $Source }
}
function Start-Win32TestLab {
    param([string]$Id)
    Set-Content -Path (Join-Path $Root "$Id\started.txt") -Value (Get-Date).ToString("o")
    [pscustomobject]@{ State = "Succeeded"; Verdict = "Passed"; Message = "Fake test lab"; JobPath = (Join-Path $Root $Id) }
}
Export-ModuleMember -Function New-Win32Detection, Save-Win32AppProject, Start-Win32TestLab
