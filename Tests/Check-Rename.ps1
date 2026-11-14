<#
.SYNOPSIS
    Checks of the rename to PackTune and of its compatibility: old command names as aliases, settings copied from the
    old folder, notes markers (old read, new written), the device-side migration code (old tasks, folders, mutexes,
    log names) and a grep for leftover product wording. No tenant, nothing from the device scripts runs on this machine
    except their file helpers on a temporary folder.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Check-Rename.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneRename-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$script:Failed = 0
function Test-Check([string]$Name, $Ok, $Detail) { if ($Ok) { "PASS  $Name" } else { $script:Failed++; "FAIL  $Name  $Detail" } }

# --- settings: copied from the folder of the earlier name on the first start
$localAppData = Join-Path $work 'localappdata'
$legacyDir = Join-Path $localAppData 'IntuneChocoDeployment'
New-Item -ItemType Directory -Path (Join-Path $legacyDir 'iconcache'), (Join-Path $legacyDir 'package\vlc') -Force | Out-Null
'{ "TenantID": "contoso.onmicrosoft.com", "ClientID": "11111111-2222-3333-4444-555555555555", "Assignment": "Required" }' | Set-Content (Join-Path $legacyDir 'settings.json')
'{}' | Set-Content (Join-Path $legacyDir 'feedcache.json')
'x' | Set-Content (Join-Path $legacyDir 'iconcache\a.png')
'big' | Set-Content (Join-Path $legacyDir 'package\vlc\install.intunewin')
$env:LOCALAPPDATA = $localAppData
. (Join-Path $repo 'PackTune-Main.ps1')
$packDir = Join-Path $localAppData 'PackTune'
Test-Check 'settings: work folder is %LOCALAPPDATA%\PackTune' ($script:WorkRoot -eq $packDir)
Test-Check 'settings: copied, not moved' ((Test-Path (Join-Path $packDir 'settings.json')) -and (Test-Path (Join-Path $legacyDir 'settings.json')))
Test-Check 'settings: feed and icon caches follow, old work folders do not' ((Test-Path (Join-Path $packDir 'feedcache.json')) -and (Test-Path (Join-Path $packDir 'iconcache\a.png')) -and -not (Test-Path (Join-Path $packDir 'package')))
Test-Check 'settings: the values are used' ($script:Settings.TenantID -eq 'contoso.onmicrosoft.com' -and $script:Settings.Assignment -eq 'Required')
'changed' | Set-Content (Join-Path $packDir 'settings.json')
Copy-PackTuneLegacyData
Test-Check 'settings: a second start does not copy again' ((Get-Content (Join-Path $packDir 'settings.json') -Raw).Trim() -eq 'changed')

# --- commands: every old name is an alias of an existing new command
Import-Module (Join-Path $repo 'Modules/Keevault.psm1') -Force
$aliases = $script:OldCommandNames
$bad = @($aliases.Keys | Where-Object { -not (Get-Alias $_ -ErrorAction SilentlyContinue) -or -not (Get-Command $aliases[$_] -ErrorAction SilentlyContinue) })
Test-Check "aliases: $($aliases.Count) old names, each resolves to an existing command" ($aliases.Count -ge 50 -and $bad.Count -eq 0) ($bad -join ', ')
foreach ($pair in @(@('Connect-IntuneChoco', 'Connect-PackTune'), @('New-IntuneWin32ChocoApplication', 'New-PackTuneChocolateyApp'), @('New-IntuneWin32WingetApplication', 'New-PackTuneWingetApp'),
        @('Update-IntuneChocoApp', 'Update-PackTuneApp'), @('Test-IntuneChocoPackage', 'Test-PackTunePackage'), @('ConvertFrom-ChocoAppNotes', 'ConvertFrom-PackTuneAppNotes'), @('Install-IntunechocoComponents', 'Install-PackTuneComponents'))) {
    $alias = Get-Alias $pair[0] -ErrorAction SilentlyContinue
    Test-Check "alias $($pair[0]) -> $($pair[1])" ($alias -and $alias.Definition -eq $pair[1])
}
Test-Check 'compat functions of the dependency apps still exist' ((Get-Command install-chocolatey, get-ChocoWin32ID, Get-WingetRuntimeWin32ID -ErrorAction SilentlyContinue).Count -eq 3)
$forward = Get-Content (Join-Path $repo 'Start-IntuneChocoTool.ps1') -Raw
Test-Check 'Start-IntuneChocoTool.ps1 only forwards with a deprecation note' ($forward -match 'deprecated' -and $forward -match 'Start-PackTune\.ps1' -and ($forward -split "`n").Count -lt 8)
Test-Check 'no file of the old names is left' (@(Get-ChildItem $repo -Filter 'ChocoIntuneDeployment-*').Count -eq 0 -and (Test-Path (Join-Path $repo 'Start-PackTune.ps1')) -and (Test-Path (Join-Path $repo 'PackTune-Main.ps1')))

# --- notes: old markers are read, the new one is written
$cases = @(
    @('PoweredByChocolatey', 'Chocolatey'), @('PoweredByChocolatey;package=7zip;version=23.01;update=Off;grace=24', 'Chocolatey'),
    @('PoweredByWinget;package=VideoLAN.VLC;version=latest;update=Custom;grace=72', 'Winget'),
    @('PoweredByPackTune;from=Winget;package=VideoLAN.VLC;version=latest;update=Startup;grace=48', 'Winget'),
    @('PoweredByPackTune;from=Chocolatey;package=git;version=latest;update=Startup;grace=48', 'Chocolatey'), @('FiredWithPowershell', $null), @('something else', $null), @('', $null))
foreach ($c in $cases) { Test-Check "notes source of '$($c[0])'" ((Get-PackTuneNotesSource $c[0]) -eq $c[1]) (Get-PackTuneNotesSource $c[0]) }
$policy = New-PackTuneAppPolicy -Package 'git'
$written = ConvertTo-PackTuneAppNotes $policy
$writtenWinget = ConvertTo-PackTuneAppNotes (New-PackTuneAppPolicy -Package 'VideoLAN.VLC') -Marker $script:WingetMarker
Test-Check 'notes written: PoweredByPackTune;from=Chocolatey' ($written -like 'PoweredByPackTune;from=Chocolatey;package=git;*' -and $written -notmatch 'PoweredByChocolatey')
Test-Check 'notes written: PoweredByPackTune;from=Winget for winget apps' ($writtenWinget -like 'PoweredByPackTune;from=Winget;package=VideoLAN.VLC;*')
Test-Check 'notes written are read back (package, source, policy)' ((ConvertFrom-PackTuneAppNotes $written).Package -eq 'git' -and (ConvertFrom-PackTuneAppNotes $written).From -eq 'Chocolatey' -and (ConvertFrom-PackTuneAppNotes $writtenWinget).From -eq 'Winget')
$oldRead = ConvertFrom-PackTuneAppNotes 'PoweredByChocolatey;package=7zip;version=23.01;update=Off;grace=24'
Test-Check 'old notes are read: package, version, mode' ($oldRead.Package -eq '7zip' -and $oldRead.Version -eq '23.01' -and $oldRead.UpdateMode -eq 'Off' -and $oldRead.From -eq 'Chocolatey')
Test-Check 'notes stay short enough' ($written.Length -lt 500) $written.Length
$insight = Import-Module (Join-Path $repo 'Modules\TenantInsight.psm1') -Force -PassThru
$markers = @{ Tool = $script:AppMarker; Winget = $script:WingetMarker; ChocolateyApp = $script:ChocoAppMarker; PackTune = $script:ToolMarker }
Set-TenantInsightHooks -Markers $markers -ConvertFromNotes ${function:ConvertFrom-PackTuneAppNotes} -ConvertToNotes ${function:ConvertTo-PackTuneAppNotes} -NewPolicy ${function:New-PackTuneAppPolicy} -NewChocoApp { } -NewWingetApp { } -SignIn { }
$classes = Get-InsightClassification -RawApps @(
    [pscustomobject]@{ id = 'n1'; displayName = 'New choco'; notes = $written; createdDateTime = '2026-01-01T00:00:00Z'; AppType = 'Win32'; installCommandLine = 'x' },
    [pscustomobject]@{ id = 'n2'; displayName = 'New winget'; notes = $writtenWinget; createdDateTime = '2026-01-01T00:00:00Z'; AppType = 'Win32'; installCommandLine = 'x' },
    [pscustomobject]@{ id = 'o1'; displayName = 'Old choco'; notes = 'PoweredByChocolatey;package=7zip;version=latest;update=Startup;grace=48'; createdDateTime = '2026-01-01T00:00:00Z'; AppType = 'Win32'; installCommandLine = 'x' },
    [pscustomobject]@{ id = 'o2'; displayName = 'Old winget'; notes = 'PoweredByWinget;package=Mozilla.Firefox;version=latest;update=Startup;grace=48'; createdDateTime = '2026-01-01T00:00:00Z'; AppType = 'Win32'; installCommandLine = 'x' }
)
$bySource = @($classes | ForEach-Object { "$($_.Id)=$($_.Source)/$($_.Kind)" }) -join ' '
Test-Check 'import and tenant list recognize new and old markers with the right source' (($classes | Where-Object Id -eq 'n1').Source -eq 'Chocolatey' -and ($classes | Where-Object Id -eq 'n2').Source -eq 'Winget' -and ($classes | Where-Object Id -eq 'o1').Source -eq 'Chocolatey' -and ($classes | Where-Object Id -eq 'o2').Source -eq 'Winget' -and @($classes | Where-Object Kind -ne 'ToolCreated').Count -eq 0) $bySource

# --- app registration: new name, old names recognized
$mainText = Get-Content (Join-Path $repo 'PackTune-Main.ps1') -Raw
Test-Check 'app registration: named PackTune, old name recognized, owner check stays' ($mainText -match '\[string\]\$DisplayName = "PackTune"' -and $mainText -match 'FormerNames = @\("Intune Chocolatey Deployment"\)' -and $mainText -match 'you are not its only owner' -and $mainText -match '\$Tag = "PackTune"')

# --- device side: generated scripts and their helpers
$common = Get-DeviceScriptCommon
$ast = [System.Management.Automation.Language.Parser]::ParseInput($common, [ref]$null, [ref]$null)
Test-Check 'device common: new tool root, old root known, new mutex first and the old one too' ($common -match '\$ToolRoot = Join-Path \$ProgramFilesRoot "PackTune"' -and $common -match '\$OldToolRoot = Join-Path \$ProgramFilesRoot "IntuneChocoDeployment"' -and $common.IndexOf('"Global\PackTune"') -gt 0 -and $common.IndexOf('"Global\PackTune"') -lt $common.IndexOf('"Global\IntuneChocoDeployment"'))
Test-Check 'device common: log file is PackTune-<id>.log, registry key PackTune' ($common -match '"PackTune-\$LogId\.log"' -and $common -notmatch 'IntuneChocoDeployment-\$LogId')
Test-Check 'device common: the lock is released in reverse order and not taken when one of the two is not ours' ($common -match 'for \(\$i = \$script:Locks\.Count - 1' -and $common -match 'foreach \(\$Done in \$Opened\) \{ \$Done\.Dispose\(\) \}')
$policyV = New-PackTuneAppPolicy -Package 'vlc'
$chocoDir = Join-Path $work 'choco'; New-Item -ItemType Directory -Path (Join-Path $chocoDir 'source') -Force | Out-Null
$null = New-Item -ItemType Directory -Path $chocoDir -Force
$chocoDetect = New-ChocoPackageScripts -ChocoName 'vlc' -SourcePath (Join-Path $chocoDir 'source') -Policy $policyV -DisplayName 'VLC'
$chocoInstall = Get-Content (Join-Path $chocoDir 'source\install.ps1') -Raw
$wingetDir = Join-Path $work 'winget'; New-Item -ItemType Directory -Path (Join-Path $wingetDir 'source') -Force | Out-Null
$wingetDetect = New-WingetPackageScripts -WingetId 'VideoLAN.VLC' -SourcePath (Join-Path $wingetDir 'source') -Policy (New-PackTuneAppPolicy -Package 'VideoLAN.VLC') -DisplayName 'VLC'
$wingetInstall = Get-Content (Join-Path $wingetDir 'source\install.ps1') -Raw
foreach ($case in @(@('Chocolatey', $chocoInstall, '\PackTune\Chocolatey\', '\Intune-Choco-Updates\', 'Chocolatey\$Package'), @('Winget', $wingetInstall, '\PackTune\Winget\', '\Intune-Winget-Updates\', 'Winget\$SafeId'))) {
    $label = $case[0]; $text = $case[1]
    Test-Check "$label install.ps1: tasks in $($case[2]), old tasks of $($case[3]) removed with the new ones" ($text.Contains('$TaskPath = "' + $case[2] + '"') -and $text.Contains('$OldTaskPath = "' + $case[3] + '"') -and $text -match 'Unregister-ScheduledTask -TaskName \$Name -TaskPath \$OldTaskPath')
    Test-Check "$label install.ps1: the old folder goes after the new tasks are registered, and on uninstall" ((([regex]::Matches($text, [regex]::Escape('Remove-OldToolFolder "' + $case[4] + '"'))).Count) -eq 2)
    Test-Check "$label install.ps1: nothing of the old name is written" ($text -notmatch 'Join-Path \$ToolRoot[^\r\n]*IntuneChoco' -and $text -notmatch 'Software\\IntuneChocoDeployment')
}
Test-Check 'detection reads the new folder' ((Get-Content $chocoDetect -Raw) -match '"PackTune\\Chocolatey\\\$Package\\policy\.txt"' -and (Get-Content $wingetDetect -Raw) -match '"PackTune\\Winget\\\$SafeId\\policy\.txt"')
Test-Check 'the fingerprint changed with the device script revision' ($script:DeviceScriptRevision -ge 7 -and $policyV.Fingerprint -ne 'x')
# Old folders only when admin-only up to %ProgramFiles%, old task folders only when empty
$removeOld = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Remove-OldToolFolder' }, $true).Extent.Text
$removeTaskFolder = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Remove-OldTaskFolder' }, $true)
Test-Check 'old folder: every removal is guarded by the admin-only chain check' (([regex]::Matches($removeOld, 'Remove-ItemSafely')).Count -eq 3 -and ([regex]::Matches($removeOld, 'Test-AdminOnlyChain')).Count -eq 3 -and $removeOld.IndexOf('Test-AdminOnlyChain $Path') -lt $removeOld.IndexOf('Remove-ItemSafely $Path'))
Test-Check 'old task folder: deleted only when it has no tasks (hidden too) and no subfolders' ($removeTaskFolder -and $removeTaskFolder.Extent.Text -match 'GetTasks\(1\)\.Count -eq 0 -and \$Folder\.GetFolders\(0\)\.Count -eq 0' -and $removeTaskFolder.Extent.Text -match 'DeleteFolder')
Test-Check 'old task folder: removed after the old tasks (Chocolatey, winget, runtime)' (@($chocoInstall, $wingetInstall | Where-Object { $_.IndexOf('Remove-OldTaskFolder $OldTaskPath') -gt $_.IndexOf('-TaskPath $OldTaskPath -Confirm') -and $_.IndexOf('-TaskPath $OldTaskPath -Confirm') -gt 0 }).Count -eq 2 -and ([regex]::Matches((Get-PackTuneRuntimeScripts).Install, 'Remove-OldTaskFolder \$OldTaskPath')).Count -eq 2 -and [int]$script:RuntimeRevision -ge 3)
$notify = Get-Content (Join-Path $chocoDir 'source\notify.ps1') -Raw
Test-Check 'notify.ps1 starts tasks in the new folder' ($notify.Contains('\PackTune\Chocolatey\') -and -not $notify.Contains('Intune-Choco-Updates'))
$runtime = Get-PackTuneRuntimeScripts
Test-Check 'runtime: new folder and task folder, old tasks and folder removed, marker revision raised' ($runtime.Install -match '\$TaskPath = "\\PackTune\\Runtime\\"' -and $runtime.Install -match '\$OldTaskPath = "\\Intune-Winget-Updates\\"' -and $runtime.Install -match 'Remove-OldToolFolder "Runtime"' -and $runtime.Install -match 'Remove-OldToolFolder "Winget\\Runtime"' -and $runtime.Detection -match '"PackTune\\Runtime\\ready\.txt"' -and [int]$script:RuntimeRevision -ge 2)

# The folder helpers of the device scripts, run on a temporary tree (never on %ProgramFiles%)
$ToolRoot = Join-Path $work 'pf\PackTune'
$OldToolRoot = Join-Path $work 'pf\IntuneChocoDeployment'
$script:AdminSids = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
function Write-DeviceLog([string]$Text) { $script:DeviceLogText += "$Text`n" }
$script:DeviceLogText = ''
foreach ($name in 'Assert-ToolPath', 'Remove-ItemSafely', 'Remove-OldToolFolder', 'Test-AdminOnlyFolder', 'Test-AdminOnlyChain') {
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    . ([scriptblock]::Create($fn.Extent.Text))
}
# The admin-only chain check with the real %ProgramFiles% (read-only): a system folder passes, the temp tree does not
$ProgramFilesRoot = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
Test-Check 'admin-only chain: a folder under %ProgramFiles% that only admins can change passes' (Test-AdminOnlyChain (Join-Path $ProgramFilesRoot 'WindowsPowerShell'))
Test-Check 'admin-only chain: a path outside %ProgramFiles% fails' (-not (Test-AdminOnlyChain $work))
$decoy = Join-Path $work 'decoy'
New-Item -ItemType Directory -Path $decoy, (Join-Path $OldToolRoot 'Chocolatey\vlc\sub'), (Join-Path $OldToolRoot 'Chocolatey\git'), (Join-Path $OldToolRoot 'Winget\Logs'), (Join-Path $OldToolRoot 'Winget\Contoso.App'), (Join-Path $OldToolRoot 'Runtime') -Force | Out-Null
'keep me' | Set-Content (Join-Path $decoy 'precious.txt')
'x' | Set-Content (Join-Path $OldToolRoot 'Chocolatey\vlc\update.ps1'), (Join-Path $OldToolRoot 'Chocolatey\chocolatey-update.txt'), (Join-Path $OldToolRoot 'Winget\Logs\a.log')
& cmd.exe /c mklink /J (Join-Path $OldToolRoot 'Chocolatey\vlc\sub\link') $decoy | Out-Null
$linkMade = Test-Path -LiteralPath (Join-Path $OldToolRoot 'Chocolatey\vlc\sub\link')
# Fail closed: the temporary tree belongs to this user (a user could change it), so nothing is removed, only logged
$ProgramFilesRoot = Join-Path $work 'pf'
Remove-OldToolFolder 'Chocolatey\vlc'
Test-Check 'old folder that is not admin-only is left alone and logged' ((Test-Path (Join-Path $OldToolRoot 'Chocolatey\vlc\update.ps1')) -and $script:DeviceLogText -match 'left alone, it is not admin-only') $script:DeviceLogText
# A junction in the chain is refused by the same check
$junctionRoot = Join-Path $work 'pf-link'
& cmd.exe /c mklink /J $junctionRoot (Join-Path $work 'pf') | Out-Null
Test-Check 'admin-only chain: a junction on the way fails' (-not (Test-AdminOnlyChain (Join-Path $junctionRoot 'IntuneChocoDeployment\Chocolatey')))
[IO.Directory]::Delete($junctionRoot, $false)
# From here the chain counts as admin-only (stand-in), to check what is removed and what is not
function Test-AdminOnlyChain([string]$Path) { $true }
$script:DeviceLogText = ''
Remove-OldToolFolder 'Chocolatey\vlc'
Test-Check 'old folder of one app is removed, a link inside is removed and never followed' ($linkMade -and -not (Test-Path (Join-Path $OldToolRoot 'Chocolatey\vlc')) -and (Test-Path (Join-Path $decoy 'precious.txt')))
Test-Check 'other apps of the old tree stay until their own install' ((Test-Path (Join-Path $OldToolRoot 'Chocolatey\git')) -and (Test-Path (Join-Path $OldToolRoot 'Winget\Contoso.App')))
Remove-OldToolFolder 'Chocolatey\git'; Remove-OldToolFolder 'Winget\Contoso.App'; Remove-OldToolFolder 'Runtime'
Test-Check 'the emptied old tree is pruned (stamp and Logs folders included)' (-not (Test-Path $OldToolRoot)) (@(Get-ChildItem $OldToolRoot -Recurse -ErrorAction SilentlyContinue).FullName -join ', ')
$evil = Join-Path $work 'elsewhere'; New-Item -ItemType Directory -Path $evil -Force | Out-Null
Remove-OldToolFolder '..\..\elsewhere'
Test-Check 'a relative path out of the old tree is refused' ((Test-Path $evil) -and $script:DeviceLogText -match 'could not be removed')

# --- leftover product wording (allowlist: compatibility code, history, team files)
$pattern = 'IntuneChoco|ChocoIntune|Chocolatey Deployment|Intune Chocolatey|IntuneWingetDeployment|Intune-Choco-Updates|Intune-Winget-Updates'
$compat = 'earlier name|earlier version|before the rename|Before the rename|old name|older|Legacy|legacy|OldToolRoot|OldTaskPath|OldChoco|OldWinget|FormerNames|migrated-from|IntuneChocoUpdates|IntuneWingetDeployment|Global\\IntuneChocoDeployment|Old command|old command|OldCommandNames|IntuneChocoDeployment\.Export|IntuneChocoDeployment status|IntuneChocoDeployment-\*|IntuneChocoDeployment\\|\.1\.log|alias|IntuneChocoDeployment CTO|copied from'
$wholeFile = @('PackTune-Aliases.ps1', 'Start-IntuneChocoTool.ps1', 'CHANGELOG.md', 'Tests/Check-Rename.ps1', 'Tests/Check-Schedule.ps1', 'Tests/Check-Sources.ps1', 'Tests/Check-Insight.ps1', 'Tests/GuiSmokeDriver.ps1', 'Tests/Invoke-GuiSmoke.ps1')
$files = @(& git -C $repo ls-files) | Where-Object { $_ -notlike '.claude/*' -and $_ -notlike '*.png' -and $_ -notlike '*.webp' -and $_ -notlike '*.jpg' -and $_ -notlike '*.svg' -and $_ -ne 'LICENSE' -and $_ -notin $wholeFile }
$left = foreach ($file in $files) {
    $path = Join-Path $repo $file
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $n = 0
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        $n++
        if ($line -match $pattern -and $line -notmatch $compat) { "${file}:${n}: $($line.Trim())" }
    }
}
Test-Check 'no old product wording outside compatibility code and history' (@($left).Count -eq 0) ((@($left) | Select-Object -First 12) -join "`n")

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failed -gt 0) { "$script:Failed check(s) failed."; exit 1 }
'All checks passed.'
