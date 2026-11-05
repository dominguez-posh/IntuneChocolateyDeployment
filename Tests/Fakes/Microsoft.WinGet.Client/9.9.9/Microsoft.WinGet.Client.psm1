# Fake Microsoft.WinGet.Client for the GUI smoke test (Tests\Invoke-GuiSmoke.ps1): a few packages with real ids and
# versions, so the manifests can still be read from github.com/microsoft/winget-pkgs; everything else is "not found".
$Packages = @(
    @{ Id = '7zip.7zip'; Name = '7-Zip'; Version = '26.05' }
    @{ Id = 'VideoLAN.VLC'; Name = 'VLC media player'; Version = '3.0.24' }
    @{ Id = 'Notepad++.Notepad++'; Name = 'Notepad++'; Version = '8.9.8.1' }
    @{ Id = 'AkelPad.AkelPad'; Name = 'AkelPad'; Version = '4.9.9' }
    @{ Id = 'Rizonesoft.Notepad3'; Name = 'Notepad3'; Version = '6.25.822.1' }
)
function Find-WinGetPackage {
    param([string]$Id, [string]$Query, [string]$MatchOption, [string]$Source)
    foreach ($p in $Packages) {
        $hit = if ($Id) { $p.Id -eq $Id } else { $p.Id -like "*$Query*" -or $p.Name -like "*$Query*" }
        if ($hit) { [pscustomobject]@{ Id = $p.Id; Name = $p.Name; Version = $p.Version; Source = 'winget'; AvailableVersions = @($p.Version) } }
    }
}
Export-ModuleMember -Function Find-WinGetPackage
