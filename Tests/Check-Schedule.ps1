<#
    Non-GUI checks of the update schedule (WP2, #8): policy round trip through the Intune notes (new and all older
    formats), fingerprint, notes length, and the generated device scripts for every update mode and both sources
    (they parse, contain the expected code, have no placeholders left, are plain ASCII).
    The generated scripts are only parsed, never run. Run:  powershell -File Tests\Check-Schedule.ps1
#>
$ErrorActionPreference = "Stop"
$Repo = Split-Path $PSScriptRoot -Parent
# Settings and work files of the tool go to a temp folder, never to the real profile
$Temp = Join-Path ([IO.Path]::GetTempPath()) ("choco-schedule-check-" + [guid]::NewGuid().ToString("N"))
New-Item -Path $Temp -ItemType Directory -Force | Out-Null
$env:LOCALAPPDATA = $Temp
. (Join-Path $Repo "ChocoIntuneDeployment-Main.ps1")

$script:Failures = 0
$script:Checks = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) {
    $script:Checks++
    if ($Ok) { Write-Host "PASS $Name" }
    else { $script:Failures++; Write-Host ("FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" } else { "" })) }
}
function Test-Throws([string]$Name, [scriptblock]$Code) {
    $Threw = $false
    try { & $Code | Out-Null } catch { $Threw = $true }
    Test-Check $Name $Threw
}
function Get-CodeText([string]$Script) {
    # The script without its comments (comments may name the old folders)
    $Tokens = $null; $Errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Script, [ref]$Tokens, [ref]$Errors)
    $Text = $Script
    foreach ($Token in @($Tokens | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        $Text = $Text.Remove($Token.Extent.StartOffset, $Token.Extent.EndOffset - $Token.Extent.StartOffset)
    }
    return $Text
}
function Get-FunctionText([string]$Script, [string]$Name) {
    # Body of one function of a generated script, without comments (empty when it is not there)
    $Ast = [System.Management.Automation.Language.Parser]::ParseInput($Script, [ref]$null, [ref]$null)
    $Function = $Ast.Find({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq $Name }, $true)
    if (-not $Function) { return "" }
    return (Get-CodeText $Function.Body.Extent.Text).Trim().TrimStart('{').Trim()
}
function Get-CopiedHelpers([string]$Script) {
    # File names a generated install.ps1 copies from its own folder: Copy-Item (Join-Path $PSScriptRoot <name or $File>);
    # for $File the names come from the foreach around it
    $Ast = [System.Management.Automation.Language.Parser]::ParseInput($Script, [ref]$null, [ref]$null)
    $Copies = $Ast.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.CommandAst] -and $Node.GetCommandName() -eq 'Copy-Item' -and $Node.Extent.Text -like '*Join-Path $PSScriptRoot*' }, $true)
    foreach ($Copy in $Copies) {
        $Join = $Copy.Find({ param($Node) $Node -is [System.Management.Automation.Language.CommandAst] -and $Node.GetCommandName() -eq 'Join-Path' }, $true)
        $Child = $Join.CommandElements[2]
        if ($Child -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $Child.Value; continue }
        $Loop = $Copy.Parent
        while ($Loop -and -not ($Loop -is [System.Management.Automation.Language.ForEachStatementAst])) { $Loop = $Loop.Parent }
        if ($Loop) { $Loop.Condition.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value } }
    }
}
function Test-SameSchedule($A, $B) {
    foreach ($Field in $script:ScheduleFields) { if ([string]$A.($Field.Name) -ne [string]$B.($Field.Name)) { return "$($Field.Name): '$($A.($Field.Name))' vs '$($B.($Field.Name))'" } }
    return $null
}

# A schedule that differs from the defaults in every field
$Changed = @{
    TriggerStart = $false; TriggerWindow = $true; WindowFrom = "22:30"; WindowTo = "02:15"; WindowDays = "1245"; IdleMinutes = 15; TriggerLogon = $true
    OnlyOnMains = $true; NoPresentation = $true; NoMetered = $true; AppNotRunning = $true; CheckIntervalHours = 24
    DeadlineAppMode = "AskClose"; CloseAfterMinutes = 30; RestartMode = "OutsideWindow"; RetryMode = "Every"; RetryCount = 5; RetryHours = 12
    ProcessNames = "chrome,msedge"
}

# --- Defaults equal the behavior before schedules existed ---
$Default = New-ChocoSchedule
Test-Check "defaults: start trigger plus daily window 10:00-15:00 on all days" ($Default.TriggerStart -and $Default.TriggerWindow -and $Default.WindowFrom -eq "10:00" -and $Default.WindowTo -eq "15:00" -and $Default.WindowDays -eq "1234567")
Test-Check "defaults: no idle, no sign-in trigger, no conditions" ($Default.IdleMinutes -eq 0 -and -not $Default.TriggerLogon -and -not ($Default.OnlyOnMains -or $Default.NoPresentation -or $Default.NoMetered -or $Default.AppNotRunning))
Test-Check "defaults: check every 4 hours, install at the deadline, never restart, next chance on failure" ($Default.CheckIntervalHours -eq 4 -and $Default.DeadlineAppMode -eq "Install" -and $Default.RestartMode -eq "Never" -and $Default.RetryMode -eq "Next")

# --- Round trip through the notes ---
foreach ($Case in @(@{ Marker = $script:AppMarker; Name = "Chocolatey" }, @{ Marker = $script:WingetMarker; Name = "winget" })) {
    foreach ($Mode in "Off", "Startup", "Custom") {
        $Policy = New-ChocoAppPolicy -Package "Some.Package+1" -Version "1.2.3" -UpdateMode $Mode -GraceHours 72 -PackageSource "https://choco.contoso.com/nuget/a b/" -UpdateDelayMinMinutes 7 -UpdateDelayMaxMinutes 41 -Schedule $Changed
        $Notes = ConvertTo-ChocoAppNotes -Policy $Policy -Marker $Case.Marker
        $Back = ConvertFrom-ChocoAppNotes $Notes
        $Different = Test-SameSchedule $Policy.Schedule $Back.Schedule
        Test-Check "round trip $($Case.Name) $Mode" ($Back.Package -eq "Some.Package+1" -and $Back.Version -eq "1.2.3" -and $Back.UpdateMode -eq $Mode -and $Back.GraceHours -eq 72 -and
            $Back.PackageSource -eq "https://choco.contoso.com/nuget/a b/" -and $Back.UpdateDelayMinMinutes -eq 7 -and $Back.UpdateDelayMaxMinutes -eq 41 -and $Back.HasSchedule -and -not $Different) $Different
    }
}
$PolicyDefault = New-ChocoAppPolicy -Package "vlc"
$NotesDefault = ConvertTo-ChocoAppNotes $PolicyDefault
Test-Check "notes start with the marker and keep the readable fields" ($NotesDefault -match '^PoweredByChocolatey;package=vlc;version=latest;update=Startup;grace=48;source=;delay=5-60;cfg=[A-Za-z0-9_-]+$') $NotesDefault
Test-Check "round trip of the defaults" (-not (Test-SameSchedule $PolicyDefault.Schedule (ConvertFrom-ChocoAppNotes $NotesDefault).Schedule))

# --- Older formats stay readable; their schedule is the default (= their old behavior) ---
$Old1 = ConvertFrom-ChocoAppNotes "PoweredByChocolatey"
Test-Check "v1 marker only" ($null -eq $Old1.Package -and $Old1.UpdateMode -eq "Startup" -and -not $Old1.HasPolicy -and -not $Old1.HasSchedule -and -not (Test-SameSchedule $Old1.Schedule $Default))
$Old2 = ConvertFrom-ChocoAppNotes "PoweredByChocolatey;package=vlc"
Test-Check "package only" ($Old2.Package -eq "vlc" -and -not $Old2.HasPolicy -and $null -eq $Old2.PackageSource -and $null -eq $Old2.UpdateDelayMinMinutes)
$Old3 = ConvertFrom-ChocoAppNotes "PoweredByWinget;package=Notepad++.Notepad++;version=latest;update=Off;grace=48"
Test-Check "policy without source and delay" ($Old3.Package -eq "Notepad++.Notepad++" -and $Old3.UpdateMode -eq "Off" -and $Old3.HasPolicy -and $null -eq $Old3.PackageSource -and -not $Old3.HasSchedule)
$Old4 = ConvertFrom-ChocoAppNotes "PoweredByChocolatey;package=7zip.install;version=23.1;update=Custom;grace=72;source=https%3A%2F%2Fx.contoso.com%2Fchoco;delay=3-9"
Test-Check "format of the last release (source, delay, no cfg)" ($Old4.Version -eq "23.1" -and $Old4.UpdateMode -eq "Custom" -and $Old4.GraceHours -eq 72 -and $Old4.PackageSource -eq "https://x.contoso.com/choco" -and $Old4.UpdateDelayMinMinutes -eq 3 -and $Old4.UpdateDelayMaxMinutes -eq 9 -and -not $Old4.HasSchedule -and -not (Test-SameSchedule $Old4.Schedule $Default))
$Broken = ConvertFrom-ChocoAppNotes "PoweredByChocolatey;package=vlc;version=latest;update=Startup;grace=48;source=;delay=5-60;cfg=!!!" 3>$null
Test-Check "notes with a damaged cfg fall back to the defaults" ($Broken.Package -eq "vlc" -and -not (Test-SameSchedule $Broken.Schedule $Default))
$Broken2 = ConvertFrom-ChocoAppNotes ("PoweredByChocolatey;package=vlc;update=Off;cfg=" + (ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes('{"v":1,"wf":"9900"}')))) 3>$null
Test-Check "notes with an invalid cfg value fall back to the defaults" ($Broken2.UpdateMode -eq "Off" -and -not $Broken2.HasSchedule -and -not (Test-SameSchedule $Broken2.Schedule $Default))
$Future = ConvertFrom-ChocoAppNotes ("PoweredByChocolatey;package=vlc;cfg=" + (ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes('{"v":9,"cp":1,"zz":5}'))))
Test-Check "cfg of a newer version: known fields are read, unknown ones ignored" ($Future.HasSchedule -and $Future.Schedule.OnlyOnMains)

# --- Partial changes of an existing schedule (Update-IntuneChocoApp merges like this) ---
$Merged = New-ChocoSchedule -Values @{ OnlyOnMains = $true } -Base $Back.Schedule
Test-Check "partial values keep the rest of the base" ($Merged.OnlyOnMains -and $Merged.WindowFrom -eq "22:30" -and $Merged.RetryCount -eq 5)

# --- Validation ---
Test-Throws "automatic mode without any trigger is refused" { New-ChocoAppPolicy -Package "x" -UpdateMode Startup -Schedule @{ TriggerStart = $false; TriggerWindow = $false } }
Test-Check "Off and Custom do not need triggers" ($(New-ChocoAppPolicy -Package "x" -UpdateMode Custom -Schedule @{ TriggerStart = $false; TriggerWindow = $false }) -and $(New-ChocoAppPolicy -Package "x" -UpdateMode Off -Schedule @{ TriggerStart = $false; TriggerWindow = $false }))
Test-Throws "window start = end" { New-ChocoSchedule -Values @{ WindowFrom = "10:00"; WindowTo = "10:00" } }
Test-Throws "bad time" { New-ChocoSchedule -Values @{ WindowFrom = "25:00" } }
Test-Throws "bad weekdays" { New-ChocoSchedule -Values @{ WindowDays = "18" } }
Test-Throws "idle minutes not allowed by Task Scheduler" { New-ChocoSchedule -Values @{ IdleMinutes = 7 } }
Test-Throws "check interval not offered" { New-ChocoSchedule -Values @{ CheckIntervalHours = 3 } }
Test-Throws "unknown restart mode" { New-ChocoSchedule -Values @{ RestartMode = "Always" } }
Test-Throws "process names with a quote" { New-ChocoSchedule -Values @{ ProcessNames = "a'b" } }
Test-Throws "retry count out of range" { New-ChocoSchedule -Values @{ RetryCount = 99 } }
Test-Check "settings default UpdateSchedule changes the schedule of new apps" ($(
        $script:Settings = [pscustomobject]@{ UpdateSchedule = '{"OnlyOnMains":true,"WindowFrom":"12:00"}' }
        $D = Get-ChocoScheduleDefaults
        $script:Settings = $null
        $D.OnlyOnMains -and $D.WindowFrom -eq "12:00" -and $D.WindowTo -eq "15:00" -and $script:DefaultSettings.Contains("UpdateSchedule")))

# --- Fingerprint covers every field ---
$Base = New-ChocoAppPolicy -Package "vlc" -Version "3.0.1" -UpdateMode Startup -GraceHours 48 -PackageSource "" -UpdateDelayMinMinutes 5 -UpdateDelayMaxMinutes 60
$Same = New-ChocoAppPolicy -Package "VLC" -Version "3.0.1" -UpdateMode Startup -GraceHours 48 -PackageSource "" -UpdateDelayMinMinutes 5 -UpdateDelayMaxMinutes 60
Test-Check "same policy, same fingerprint" ($Base.Fingerprint -eq $Same.Fingerprint -and $Base.Fingerprint -match '^[0-9a-f]{16}$')
$Seen = @{ $Base.Fingerprint = "base" }
function Test-FingerprintChange([string]$Name, $Policy) {
    $Known = $Seen.ContainsKey($Policy.Fingerprint)
    Test-Check "fingerprint changes with $Name" (-not $Known) $(if ($Known) { "same as $($Seen[$Policy.Fingerprint])" })
    $script:Seen[$Policy.Fingerprint] = $Name
}
Test-FingerprintChange "version" (New-ChocoAppPolicy -Package "vlc" -Version "3.0.2" -UpdateMode Startup)
Test-FingerprintChange "update mode" (New-ChocoAppPolicy -Package "vlc" -Version "3.0.1" -UpdateMode Custom)
Test-FingerprintChange "grace hours" (New-ChocoAppPolicy -Package "vlc" -Version "3.0.1" -GraceHours 49)
Test-FingerprintChange "package source" (New-ChocoAppPolicy -Package "vlc" -Version "3.0.1" -PackageSource "https://x")
Test-FingerprintChange "delay min" (New-ChocoAppPolicy -Package "vlc" -Version "3.0.1" -UpdateDelayMinMinutes 6)
Test-FingerprintChange "delay max" (New-ChocoAppPolicy -Package "vlc" -Version "3.0.1" -UpdateDelayMaxMinutes 61)
foreach ($Field in $script:ScheduleFields) {
    $Value = switch ($Field.Type) {
        "bool" { -not $Default.($Field.Name) }
        "time" { if ($Field.Name -eq "WindowFrom") { "11:00" } else { "16:00" } }
        "days" { "12345" }
        "int" { @($(if ($Field.Allowed) { $Field.Allowed } else { $Field.Min..$Field.Max }) | Where-Object { $_ -ne $Default.($Field.Name) })[0] }
        "enum" { @($Field.Map.Keys | Where-Object { $_ -ne $Default.($Field.Name) })[0] }
        "names" { "chrome" }
    }
    Test-FingerprintChange "schedule field $($Field.Name)" (New-ChocoAppPolicy -Package "vlc" -Version "3.0.1" -UpdateMode Startup -Schedule @{ $Field.Name = $Value })
}
$Revision = $script:DeviceScriptRevision
$script:DeviceScriptRevision = $Revision + 1
Test-Check "fingerprint changes with the device script revision" ((New-ChocoAppPolicy -Package "vlc" -Version "3.0.1").Fingerprint -ne $Base.Fingerprint)
$script:DeviceScriptRevision = $Revision
Test-Check "device script revision was raised for WP2 (4 or more)" ($Revision -ge 4) $Revision

# --- Length of the notes ---
$Largest = @{ ProcessNames = (("abcdefghi" * 17).Substring(0, 150)); WindowDays = "1234567"; RetryHours = 72; CloseAfterMinutes = 240; CheckIntervalHours = 24 }
$LargestPolicy = New-ChocoAppPolicy -Package ("p" * 60) -Version "10.20.30.40-beta.1" -UpdateMode Custom -GraceHours 2160 -PackageSource ("https://choco.contoso.com/nuget/" + ("a" * 140)) -UpdateDelayMinMinutes 100 -UpdateDelayMaxMinutes 1000 -Schedule $Largest
$LargestNotes = ConvertTo-ChocoAppNotes $LargestPolicy
Write-Host "INFO notes length: default $($NotesDefault.Length), largest policy $($LargestNotes.Length), limit used $($script:NotesMaxLength)"
Test-Check "notes of the largest policy stay below the limit" ($LargestNotes.Length -lt $script:NotesMaxLength) $LargestNotes.Length
Test-Check "notes of the largest policy are read back" ((ConvertFrom-ChocoAppNotes $LargestNotes).Schedule.ProcessNames -eq $Largest.ProcessNames)
Test-Throws "notes that would be too long are refused" { ConvertTo-ChocoAppNotes (New-ChocoAppPolicy -Package "p" -PackageSource ("https://x/" + ("a" * 900))) }

# --- Generated device scripts ---
$script:WingetIdPattern | Out-Null
$AllConditions = @{ OnlyOnMains = $true; NoPresentation = $true; NoMetered = $true; AppNotRunning = $true; IdleMinutes = 10; TriggerLogon = $true; RestartMode = "Ask"; RetryMode = "Every"; DeadlineAppMode = "AskClose" }
$Cases = @()
foreach ($Source in "Chocolatey", "Winget") {
    foreach ($Mode in "Off", "Startup", "Custom") {
        $Cases += @{ Source = $Source; Mode = $Mode; Label = "default"; Schedule = $null }
        $Cases += @{ Source = $Source; Mode = $Mode; Label = "all conditions"; Schedule = $AllConditions }
        $Cases += @{ Source = $Source; Mode = $Mode; Label = "changed"; Schedule = $Changed }
    }
}
function Test-ScriptFile([string]$Label, [string]$Path) {
    $Bytes = [IO.File]::ReadAllBytes($Path)
    $Text = [Text.Encoding]::ASCII.GetString($Bytes)
    Test-Check "$Label $(Split-Path $Path -Leaf) is plain ASCII" (-not ($Bytes | Where-Object { $_ -gt 126 -or ($_ -lt 32 -and $_ -notin 9, 10, 13) }))
    $Errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$Errors)
    Test-Check "$Label $(Split-Path $Path -Leaf) parses" ($Errors.Count -eq 0) ($Errors | Select-Object -First 1 | ForEach-Object { "$($_.Message) line $($_.Extent.StartLineNumber)" })
    Test-Check "$Label $(Split-Path $Path -Leaf) has no placeholder left" ($Text -notmatch '__[A-Z]{3,}__') ([regex]::Match($Text, '__[A-Z]{3,}__').Value)
    return $Text
}
$Index = 0
foreach ($Case in $Cases) {
    $Index++
    $Label = "$($Case.Source) $($Case.Mode) [$($Case.Label)]"
    $Policy = New-ChocoAppPolicy -Package $(if ($Case.Source -eq "Winget") { "Contoso.App" } else { "contosoapp" }) -UpdateMode $Case.Mode -Schedule $Case.Schedule
    $Folder = Join-Path $Temp "case$Index"
    New-Item -Path (Join-Path $Folder "source") -ItemType Directory -Force | Out-Null
    $Detection = if ($Case.Source -eq "Winget") { New-WingetPackageScripts -WingetId "Contoso.App" -SourcePath (Join-Path $Folder "source") -Policy $Policy -DisplayName "Contoso App" }
    else { New-ChocoPackageScripts -ChocoName "contosoapp" -SourcePath (Join-Path $Folder "source") -Policy $Policy -DisplayName "Contoso App" }
    $Install = Test-ScriptFile $Label (Join-Path $Folder "source\install.ps1")
    $Update = Test-ScriptFile $Label (Join-Path $Folder "source\update.ps1")
    $Notify = Test-ScriptFile $Label (Join-Path $Folder "source\notify.ps1")
    $Probe = Test-ScriptFile $Label (Join-Path $Folder "source\probe.ps1")
    $DetectionText = Test-ScriptFile $Label $Detection
    $S = $Policy.Schedule

    Test-Check "$Label detection carries the fingerprint" ($DetectionText.Contains($Policy.Fingerprint))
    Test-Check "$Label install.ps1 carries the fingerprint and the schedule" ($Install.Contains("'$($Policy.Fingerprint)'") -and $Install.Contains('"WindowFrom":"' + $S.WindowFrom + '"'))
    Test-Check "$Label install.ps1 and update.ps1 use the global lock" ($Install -match 'Global\\IntuneChocoDeployment' -and $Update -match 'Global\\IntuneChocoDeployment' -and $Update -match 'Enter-DeploymentLock')
    Test-Check "$Label scripts use SIDs for principals" ($Install -match 'S-1-5-18' -and $Install -notmatch '-UserId "SYSTEM"' -and $Install -notmatch '-GroupId "Users"')
    Test-Check "$Label scripts write the Intune log and the last result" ($Install -match 'IntuneManagementExtension\\Logs' -and $Install -match 'IntuneChocoDeployment-\$LogId' -and $Install -match 'Save-LastResult' -and $Update -match 'last-result\.json' -and $Update -match '-gt 1MB')
    Test-Check "$Label install.ps1 has the trigger code" ($Install -match 'New-ScheduledTaskTrigger -AtStartup' -and $Install -match 'New-ScheduledTaskTrigger -Weekly' -and $Install -match 'RandomDelay' -and $Install -match 'MSFT_TaskIdleTrigger' -and $Install -match 'New-ScheduledTaskTrigger -AtLogOn')
    Test-Check "$Label install.ps1 has the Task Scheduler settings" ($Install -match 'AllowStartIfOnBatteries' -and $Install -match 'DontStopIfGoingOnBatteries' -and $Install -match 'RunOnlyIfNetworkAvailable' -and $Install -match 'RunOnlyIfIdle')
    Test-Check "$Label update.ps1 has the condition code" ($Update -match 'function Test-OnBattery' -and $Update -match 'Win32_Battery' -and $Update -match 'function Test-Metered' -and $Update -match 'GetConnectionCost' -and $Update -match 'function Test-ScreenBusy' -and $Update -match 'RunEx' -and $Update -match 'function Test-InWindow' -and $Update -match 'function Get-RunningApp')
    Test-Check "$Label update.ps1 has deadline, retry and restart code" ($Update -match 'DeadlineAppMode' -and $Update -match 'CloseAfterMinutes' -and $Update -match 'function Register-FailureRetry' -and $Update -match 'RetryHours' -and $Update -match 'function Invoke-RestartStep' -and $Update -match 'shutdown\.exe')
    Test-Check "$Label probe.ps1 asks Windows for the notification state" ($Probe -match 'SHQueryUserNotificationState' -and $Probe -match 'HKCU:\\Software\\IntuneChocoDeployment\\ScreenProbe')
    # Security review: answer of the probe without a file, device folders under %ProgramFiles%, fail-closed lock
    $InstallCode = Get-CodeText $Install; $UpdateCode = Get-CodeText $Update; $ProbeCode = Get-CodeText $Probe; $DetectionCode = Get-CodeText $DetectionText
    Test-Check "$Label probe answer goes through the registry with a nonce, no file in the profile" ($ProbeCode -notmatch 'screen-state|LOCALAPPDATA|Set-Content' -and $ProbeCode -match '\^\[0-9a-f\]\{32\}\$' -and $InstallCode.Contains('-Nonce `$(Arg0)') -and $UpdateCode -match 'RunEx\(\$Nonce, 4' -and $UpdateCode -match 'Registry::HKEY_USERS\\\$Sid' -and $UpdateCode -match 'TryParse\(\[string\]\$Answer\.State' -and $UpdateCode -notmatch 'screen-state|AppData|ProfileImagePath')
    Test-Check "$Label probe value is never logged" ((Get-FunctionText $Update 'Test-ScreenBusy') -notmatch 'Write-Log[^\r\n]*\$(State|Answer)' -and (Get-FunctionText $Update 'Test-ScreenBusy') -match 'screen state unknown \(\$\(\$_\.Exception\.GetType\(\)\.Name\)\)')
    $Sub = if ($Case.Source -eq "Winget") { "Winget" } else { "Chocolatey" }
    Test-Check "$Label helpers live under %ProgramFiles%\IntuneChocoDeployment, nothing under %ProgramData% of the tool" ($InstallCode -match '\$ToolRoot = Join-Path \$\(if \(\$env:ProgramW6432\)' -and $InstallCode -match ('Join-Path \$ToolRoot "' + $Sub + '"') -and $InstallCode -match 'Protect-Folder \$ToolRoot' -and $InstallCode -notmatch 'IntuneChocoUpdates|IntuneWingetDeployment' -and $UpdateCode -notmatch 'IntuneChocoUpdates|IntuneWingetDeployment')
    Test-Check "$Label detection reads the marker under %ProgramFiles%" ($DetectionCode -match ('"IntuneChocoDeployment\\' + $Sub + '\\') -and $DetectionCode -match 'ProgramW6432' -and $DetectionCode -notmatch 'ProgramData[^\r\n]*(IntuneChocoUpdates|IntuneWingetDeployment)')
    Test-Check "$Label no recursion into folders a user could have made" ($InstallCode -notmatch 'Remove-ForeignItems' -and (Get-FunctionText $Install 'Remove-ItemSafely') -match '^\s*Assert-ToolPath \$Path' -and (Get-FunctionText $Install 'Protect-Folder') -match 'Assert-ToolPath \$Path' -and (Get-FunctionText $Install 'Protect-Folder') -match 'Test-AdminOnlyFolder \$Parent' -and (Get-FunctionText $Install 'Protect-Folder') -notmatch 'Remove-|Get-ChildItem')
    Test-Check "$Label lock: mutex with security descriptor, foreign owner fails closed" ($InstallCode -match 'MutexSecurity' -and $InstallCode -match 'MutexAccessRule' -and $InstallCode -match '\[System\.Threading\.Mutex\]::new\(\$false, \$Name, \[ref\]\$Created, \$Security\)' -and $InstallCode -match '\$Owner -notin \$script:AdminSids' -and $InstallCode -notmatch 'New-Object System\.Threading\.Mutex' -and $UpdateCode -match 'MutexSecurity')
    Test-Check "$Label IME log only into an admin-only folder, never into a link or foreign file" ((Get-FunctionText $Install 'Add-CappedLine') -match 'Test-AdminOnlyFolder' -and (Get-FunctionText $Install 'Add-CappedLine') -match 'if \(Test-ForeignItem \$Path\) \{ return \}' -and (Get-FunctionText $Install 'Add-CappedLine') -notmatch 'Remove-' -and (Get-FunctionText $Install 'Write-DeviceLog') -match 'IntuneManagementExtension')
    if ($Case.Source -eq "Winget") { Test-Check "$Label winget only from WindowsApps, never from PATH" ($InstallCode -notmatch 'Get-Command winget' -and $UpdateCode -notmatch 'Get-Command winget' -and $DetectionCode -notmatch 'Get-Command winget') }
    Test-Check "$Label last result uses the schema of the status script" ((Get-FunctionText $Install 'Save-LastResult') -match 'lastAttempt = ' -and (Get-FunctionText $Install 'Save-LastResult') -match 'installedVersion = ' -and (Get-FunctionText $Install 'Save-LastResult') -match 'targetVersion = ' -and (Get-FunctionText $Install 'Save-LastResult') -notmatch '\bTime = ')
    Test-Check "$Label notify.ps1 has update, close warning and restart prompts" ($Notify -match 'restart\.json' -and $Notify -match 'CloseAt' -and $Notify -match 'Software update')
    $TaskFolder = if ($Case.Source -eq "Winget") { "Intune-Winget-Updates" } else { "Intune-Choco-Updates" }
    Test-Check "$Label notify.ps1 starts the task of its source" ($Notify.Contains("\$TaskFolder\Update"))
    Test-Check "$Label install.ps1 copies the helpers" ($Install -match '"update\.ps1", "notify\.ps1", "probe\.ps1"')
    # Every file install.ps1 copies from its own folder is in the package and in the sandbox lab project (the lab once missed probe.ps1)
    $Helpers = @(Get-CopiedHelpers $Install)
    $Lab = Join-Path $Folder "lab"; New-Item -Path $Lab -ItemType Directory -Force | Out-Null
    Copy-LabPackageFiles -SourcePath (Join-Path $Folder "source") -Destination $Lab
    $MissingSource = @($Helpers | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Folder "source\$_")) })
    $MissingLab = @($Helpers | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Lab $_)) })
    Test-Check "$Label every helper install.ps1 copies is in the package and in the lab project" ($Helpers.Count -ge 3 -and $MissingSource.Count -eq 0 -and $MissingLab.Count -eq 0 -and (Test-Path (Join-Path $Lab "choco-app.ps1")) -and -not (Test-Path (Join-Path $Lab "install.ps1"))) "helpers: $($Helpers -join ','); missing in package: $($MissingSource -join ','); missing in lab: $($MissingLab -join ',')"
    if ($Case.Source -eq "Winget") { Test-Check "$Label winget update.ps1 asks winget for upgrades and uses machine scope" ($Update -match '--upgrade-available' -and $Update -match '--scope machine') }
    else { Test-Check "$Label choco update.ps1 uses choco upgrade" ($Update -match 'upgrade \$Package') }
}

# --- Security review: the guards of the device scripts, run on their own (read-only; no device script is run) ---
$CommonAst = [System.Management.Automation.Language.Parser]::ParseInput((Get-DeviceScriptCommon), [ref]$null, [ref]$null)
foreach ($Name in "Test-AdminOnlyFolder", "Assert-ToolPath", "Test-ForeignItem", "Open-DeploymentLock") {
    $Function = $CommonAst.Find({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq $Name }, $true)
    $Text = $Function.Extent.Text
    # The lock is tried under a name of its own, never the real device lock
    if ($Name -eq "Open-DeploymentLock") { $Text = $Text.Replace('"Global\IntuneChocoDeployment"', '$script:CheckLockName') }
    . ([scriptblock]::Create($Text))
}
$AdminSidsLine = $CommonAst.Find({ param($Node) $Node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $Node.Left.Extent.Text -eq '$script:AdminSids' }, $true)
. ([scriptblock]::Create($AdminSidsLine.Extent.Text))
$ProgramFilesDir = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
Test-Check "admin-only folder: %ProgramFiles% is one" (Test-AdminOnlyFolder $ProgramFilesDir)
Test-Check "admin-only folder: a folder of the user (temp) is not one" (-not (Test-AdminOnlyFolder $Temp))
$Junction = Join-Path $Temp "junction"
& cmd.exe /c mklink /J "$Junction" "$ProgramFilesDir" | Out-Null
Test-Check "admin-only folder: a junction to %ProgramFiles% is not one" ((Test-Path -LiteralPath $Junction) -and -not (Test-AdminOnlyFolder $Junction))
Test-Check "a junction counts as foreign item" (Test-ForeignItem $Junction)
[IO.Directory]::Delete($Junction, $false)
$ImeLogs = Join-Path $env:ProgramData "Microsoft\IntuneManagementExtension\Logs"
if (Test-Path -LiteralPath $ImeLogs) { Test-Check "admin-only folder: the IME log folder of this machine is one" (Test-AdminOnlyFolder $ImeLogs) }
$ToolRoot = Join-Path $ProgramFilesDir "IntuneChocoDeployment"
Test-Check "tool path: a folder of the tool is accepted" ($(try { Assert-ToolPath (Join-Path $ToolRoot "Winget\Contoso.App"); $true } catch { $false }))
Test-Throws "tool path: .. out of the tool folder is refused" { Assert-ToolPath (Join-Path $ToolRoot "..\Other") }
Test-Throws "tool path: the old %ProgramData% folder is refused" { Assert-ToolPath (Join-Path $env:ProgramData "IntuneChocoUpdates\vlc") }
Test-Throws "tool path: a look-alike folder is refused" { Assert-ToolPath ($ToolRoot + "-x\vlc") }
$script:CheckLockName = "Local\IntuneChocoCheck-" + [guid]::NewGuid().ToString("N")
$Own = Open-DeploymentLock
Test-Check "lock: created with its security descriptor" ($null -ne $Own -and @($Own.GetAccessControl().GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value }) -join "," -eq "S-1-5-18,S-1-5-32-544") $script:LockError
if ($Own) { $Own.Dispose() }
$script:CheckLockName = "Local\IntuneChocoCheck-" + [guid]::NewGuid().ToString("N")
$Squatter = New-Object System.Threading.Mutex($false, $script:CheckLockName)
$script:LockError = ""
$Opened = Open-DeploymentLock
$IsAdmin = ([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) { Test-Check "lock: one made before by a user fails closed with a cause" ($null -eq $Opened -and $script:LockError -match 'belongs to someone else') $script:LockError }
$Squatter.Dispose()

# --- Security review: notes with crafted numbers, feed URLs, icon URLs ---
$Crafted = ConvertFrom-ChocoAppNotes "PoweredByChocolatey;package=vlc;version=latest;update=Startup;grace=99999999999;source=;delay=99999999999-5"
Test-Check "notes: numbers too big for int keep the defaults" ($Crafted.GraceHours -eq 48 -and $null -eq $Crafted.UpdateDelayMinMinutes) "$($Crafted.GraceHours) $($Crafted.UpdateDelayMinMinutes)"
$Clamped = ConvertFrom-ChocoAppNotes "PoweredByChocolatey;package=vlc;version=latest;update=Startup;grace=5000;source=;delay=20000-3"
Test-Check "notes: grace and delay are clamped to the valid ranges" ($Clamped.GraceHours -eq 2160 -and $Clamped.UpdateDelayMinMinutes -eq $script:MaxDelayMinutes -and $Clamped.UpdateDelayMaxMinutes -eq $script:MaxDelayMinutes) "$($Clamped.GraceHours) $($Clamped.UpdateDelayMinMinutes)-$($Clamped.UpdateDelayMaxMinutes)"
$Zero = ConvertFrom-ChocoAppNotes "PoweredByChocolatey;package=vlc;version=latest;update=Startup;grace=0;delay=9-2"
Test-Check "notes: grace 0 becomes 1, max delay not below min" ($Zero.GraceHours -eq 1 -and $Zero.UpdateDelayMinMinutes -eq 9 -and $Zero.UpdateDelayMaxMinutes -eq 9)
Test-Throws "feed: user and password in the URL are refused" { New-ChocoAppPolicy -Package "vlc" -PackageSource "https://user:secret@feed.example/nuget" }
Test-Throws "feed: query parameters (API key) are refused" { New-ChocoAppPolicy -Package "vlc" -PackageSource "https://feed.example/nuget?apikey=1" }
$BadSettings = Get-IntuneChocoSettings; $BadSettings.PackageSource = "https://feed.example/nuget?apikey=1"
Test-Throws "feed: the package source setting refuses query parameters as well" { Save-IntuneChocoSettings -Settings $BadSettings }
Test-Check "feed: plain https and UNC feeds are accepted" ($(try { $null = New-ChocoAppPolicy -Package "vlc" -PackageSource "https://feed.example/nuget/"; $null = New-ChocoAppPolicy -Package "vlc" -PackageSource "\\server\choco"; $true } catch { $false }))
Test-Check "icon URL: only https" ((Test-HttpsUrl "https://cdn.example/icon.png") -and -not (Test-HttpsUrl "http://cdn.example/icon.png") -and -not (Test-HttpsUrl "file:///C:/Windows/win.ini") -and -not (Test-HttpsUrl "\\server\share\icon.png") -and -not (Test-HttpsUrl "https://u:p@cdn.example/i.png"))
$NoIcon = Get-ChocoIconBase64 -ChocoName "iconcheck" -IconUrl "file:///C:/Windows/win.ini" -NoIconPrompt -NoFeedLookup -WarningAction SilentlyContinue
Test-Check "icon URL: a file URL is not read" ($null -eq $NoIcon -and -not (Test-Path (Join-Path $Temp "IntuneChocoDeployment\icons\iconcheck\download")))

Remove-Item -Path $Temp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "$script:Checks checks, $script:Failures failed"
if ($script:Failures -gt 0) { exit 1 }
exit 0
