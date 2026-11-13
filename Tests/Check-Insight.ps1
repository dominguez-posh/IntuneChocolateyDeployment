# Non-GUI checks of Modules\TenantInsight.psm1 with fake Graph responses. Never contacts a tenant.
# Run in Windows PowerShell 5.1:  powershell -NoProfile -File Tests\Check-Insight.ps1
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ("insight-check-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$env:LOCALAPPDATA = $temp   # settings of the core script go here, not into the real profile
$script:Failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) {
    if ($Ok) { "PASS $Name" } else { $script:Failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) }
}

. (Join-Path $repo 'PackTune-Main.ps1')   # loads the module and its hooks

# ---- fake tenant: old and new notes formats, command lines, duplicates
$apps = @(
    @{ id = 'a1'; displayName = 'Git'; notes = 'PoweredByChocolatey;package=git;version=latest;update=Startup;grace=48;source=;delay=5-60'; installCommandLine = 'powershell.exe -File .\install.ps1'; createdDateTime = '2026-01-01T10:00:00Z'; AppType = 'Win32' }
    @{ id = 'a2'; displayName = 'Old tool app'; notes = 'PoweredByChocolatey'; installCommandLine = 'powershell.exe -File .\install.ps1'; createdDateTime = '2025-01-01T10:00:00Z'; AppType = 'Win32' }
    @{ id = 'a3'; displayName = 'Mid format'; notes = 'PoweredByChocolatey;package=7zip;version=23.01;update=Off;grace=24'; createdDateTime = '2025-06-01T10:00:00Z'; AppType = 'Win32' }
    @{ id = 'a4'; displayName = 'VLC'; notes = 'PoweredByWinget;package=VideoLAN.VLC;version=latest;update=Custom;grace=72;source=;delay=5-60'; createdDateTime = '2026-02-01T10:00:00Z'; AppType = 'Win32' }
    @{ id = 'a5'; displayName = 'Chocolatey'; notes = 'FiredWithPowershell'; createdDateTime = '2025-01-01T10:00:00Z'; AppType = 'Win32' }
    @{ id = 'b1'; displayName = 'Firefox (own)'; notes = ''; installCommandLine = 'choco install firefox -y --version 120.0'; createdDateTime = '2025-03-01T10:00:00Z'; AppType = 'Win32' }
    @{ id = 'b2'; displayName = 'Notepad++'; notes = 'by hand'; installCommandLine = 'C:\ProgramData\chocolatey\bin\choco.exe upgrade -y "notepadplusplus" --source=https://user:secret@feed.example/nuget?key=abc'; createdDateTime = '2025-03-02T10:00:00Z'; AppType = 'Win32' }
    @{ id = 'b3'; displayName = 'Git again'; notes = ''; installCommandLine = 'choco install git -y'; createdDateTime = '2025-03-03T10:00:00Z'; AppType = 'Win32' }
    @{ id = 'b4'; displayName = 'Winget app'; notes = ''; installCommandLine = 'winget install --id Mozilla.Firefox -e --silent --version 121.0'; createdDateTime = '2025-03-04T10:00:00Z'; AppType = 'Win32' }
    @{ id = 'b5'; displayName = 'Own MSI'; notes = ''; installCommandLine = 'msiexec /i setup.msi /qn'; createdDateTime = '2025-03-05T10:00:00Z'; AppType = 'Win32' }
    @{ id = 'c1'; displayName = 'Store VLC'; notes = ''; packageIdentifier = '9NBLGGH4NNS1'; createdDateTime = '2026-03-01T10:00:00Z'; AppType = 'Store' }
    @{ id = 'c2'; displayName = 'Store VLC win32 dup'; notes = ''; installCommandLine = 'winget install --id 9NBLGGH4NNS1'; createdDateTime = '2026-03-02T10:00:00Z'; AppType = 'Win32' }
) | ForEach-Object { [pscustomobject]$_ }
$c = Get-InsightClassification -RawApps $apps
function Get-C($id) { $c | Where-Object Id -eq $id }
Test-Check 'new notes = ToolCreated' ((Get-C a1).Kind -eq 'ToolCreated' -and (Get-C a1).Package -eq 'git' -and (Get-C a1).ProposedAction -eq 'Managed')
Test-Check 'old notes (marker only) still managed, no package' ((Get-C a2).Managed -and -not (Get-C a2).Package)
Test-Check 'mid notes policy read' ((Get-C a3).Version -eq '23.01' -and (Get-C a3).UpdateMode -eq 'Off' -and (Get-C a3).GraceHours -eq 24)
Test-Check 'winget notes' ((Get-C a4).Source -eq 'Winget' -and (Get-C a4).UpdateMode -eq 'Custom' -and (Get-C a4).GraceHours -eq 72)
Test-Check 'Chocolatey app is infrastructure' ((Get-C a5).Infrastructure -and (Get-C a5).Package -eq 'chocolatey')
Test-Check 'choco install with flags: id and pinned version' ((Get-C b1).Kind -eq 'ChocolateyWin32' -and (Get-C b1).Package -eq 'firefox' -and (Get-C b1).Version -eq '120.0' -and (Get-C b1).UpdateMode -eq 'Off' -and (Get-C b1).ProposedAction -eq 'TakeOver')
Test-Check 'choco upgrade with quoted id' ((Get-C b2).Package -eq 'notepadplusplus' -and (Get-C b2).Version -eq '')
Test-Check 'duplicate of managed app skipped' ((Get-C b3).Duplicate -and (Get-C b3).DuplicateOf -eq 'a1' -and (Get-C b3).ProposedAction -eq 'SkipDuplicate')
Test-Check 'winget Win32 app' ((Get-C b4).Kind -eq 'WingetWin32' -and (Get-C b4).Package -eq 'Mozilla.Firefox' -and (Get-C b4).Version -eq '121.0')
Test-Check 'own MSI cannot be managed' ((Get-C b5).Kind -eq 'Other' -and (Get-C b5).ProposedAction -eq 'CannotManage')
Test-Check 'Store app kept, Win32 twin skipped' ((Get-C c1).ProposedAction -eq 'KeepAsStoreApp' -and (Get-C c2).ProposedAction -eq 'SkipDuplicate')

# ---- take over writes the notes only
$sent = New-Object System.Collections.ArrayList
$fake = New-InsightGraphContext -Name fake -Invoke { param($m, $p, $b) [void]$sent.Add([pscustomobject]@{ M = $m; P = $p; B = $b }); @{ value = @() } }.GetNewClosure()
$r = @(Set-InsightAppTakeOver -Context $fake -Apps @((Get-C b1), (Get-C b5)))
Test-Check 'take over: one PATCH with tool notes' ($sent.Count -eq 1 -and $sent[0].M -eq 'PATCH' -and $sent[0].P -eq '/beta/deviceAppManagement/mobileApps/b1' -and $sent[0].B.notes -like 'PoweredByPackTune;from=Chocolatey;package=firefox;version=120.0;update=Off*' -and $sent[0].B.Keys.Count -eq 2)
Test-Check 'take over: not importable reported' ($r[1].Done -eq $false)
$back = ConvertFrom-PackTuneAppNotes $sent[0].B.notes
Test-Check 'written notes read back by the tool' ($back.Package -eq 'firefox' -and $back.Version -eq '120.0')

# ---- export / import round trip, no tenant ids, no secrets
$managed = @((Get-C a1), (Get-C a3), (Get-C a4), (Get-C a5), [pscustomobject]@{ Managed = $true; Package = 'x'; Source = 'Chocolatey'; Infrastructure = $false; DisplayName = 'Feed'; Version = ''; UpdateMode = 'Startup'; GraceHours = 48; PackageSource = 'https://user:secret@feed.example/nuget?key=abc'; Id = '11111111-2222-3333-4444-555555555555' })
$file = Join-Path $temp 'export.json'
$n = Export-InsightManagedApps -Apps $managed -Path $file
$text = Get-Content $file -Raw
Test-Check 'export: infrastructure left out' ($n -eq 4)
Test-Check 'export: no ids, no secrets' ($text -notmatch '[0-9a-f]{8}-[0-9a-f]{4}-' -and $text -notmatch 'secret|key=abc|"id"|tenant' -and $text -match 'feed\.example/nuget')
Test-Check 'export: UTF-8 without BOM' ([IO.File]::ReadAllBytes($file)[0] -eq 0x7B)
$cand = @(Read-InsightExportFile -Path $file)
Test-Check 'import: policy survives the round trip' ($cand.Count -eq 4 -and ($cand | Where-Object Package -eq '7zip').Version -eq '23.01' -and ($cand | Where-Object Package -eq 'VideoLAN.VLC').UpdateMode -eq 'Custom')
$bad = Join-Path $temp 'bad.json'; '{"format":"x"}' | Set-Content $bad
Test-Check 'import: foreign file rejected' ($(try { Read-InsightExportFile -Path $bad | Out-Null; $false } catch { $true }))

# ---- recreate through the deploy functions (replaced by fakes)
$deployed = New-Object System.Collections.ArrayList
$feeds = @{}
Set-TenantInsightHooks -Markers @{ Tool = $script:AppMarker; Winget = $script:WingetMarker; ChocolateyApp = $script:ChocoAppMarker } -ConvertFromNotes ${function:ConvertFrom-PackTuneAppNotes} -ConvertToNotes ${function:ConvertTo-PackTuneAppNotes} -NewPolicy ${function:New-PackTuneAppPolicy} `
    -NewChocoApp { param($ChocoName, $Assignment, $UpdateMode, $GraceHours, $Version, $PackageSource, $NoIconPrompt) [void]$deployed.Add("choco:$ChocoName`:$Version`:$UpdateMode"); $feeds[$ChocoName] = $PSBoundParameters.ContainsKey('PackageSource') }.GetNewClosure() `
    -NewWingetApp { param($WingetId, $Assignment, $UpdateMode, $GraceHours, $Version, $NoIconPrompt) [void]$deployed.Add("winget:$WingetId`:$Version`:$UpdateMode") }.GetNewClosure()
$rc = @(New-InsightRecreatedApps -Candidates $cand -ExistingApps @((Get-C a1)))
Test-Check 'recreate: deploy functions called, managed package skipped' ($deployed.Count -eq 3 -and ($rc | Where-Object Package -eq 'git').Done -eq $false -and ($rc | Where-Object Package -eq 'git').Message -like 'already*')
Test-Check 'recreate: pinned version and mode passed' (($deployed -contains 'choco:7zip:23.01:Off') -and ($deployed -contains 'winget:VideoLAN.VLC:latest:Custom'))

# ---- import: the package source of a file or another tenant is shown, checked and only used after a yes per app
Test-Check 'feed url: only https without user info, query or fragment' ((Test-InsightFeedUrl 'https://feed.example/nuget/') -and -not (Test-InsightFeedUrl 'http://feed.example/nuget') -and -not (Test-InsightFeedUrl '\\attacker\share') -and -not (Test-InsightFeedUrl 'file:///C:/feed') -and -not (Test-InsightFeedUrl 'https://u:p@feed.example/nuget') -and -not (Test-InsightFeedUrl 'https://feed.example/nuget?key=1') -and -not (Test-InsightFeedUrl ''))
$feedFile = Join-Path $temp 'feeds.json'
@{ format = 'IntuneChocoDeployment.Export'; version = 1; exported = '2026-11-13'; apps = @(
        @{ displayName = 'Good feed'; source = 'Chocolatey'; package = 'goodfeed'; version = ''; updateMode = 'Startup'; graceHours = 48; packageSource = 'https://feed.example/nuget/' }
        @{ displayName = 'UNC feed'; source = 'Chocolatey'; package = 'uncfeed'; version = ''; updateMode = 'Startup'; graceHours = 48; packageSource = '\\attacker\share' }
        @{ displayName = 'No feed'; source = 'Chocolatey'; package = 'nofeed'; version = ''; updateMode = 'Startup'; graceHours = 48; packageSource = '' }) } | ConvertTo-Json -Depth 5 | Set-Content $feedFile
$feedCand = @(Read-InsightExportFile -Path $feedFile)
Test-Check 'import: offered source is kept for display, not marked for use' ($feedCand.Count -eq 3 -and ($feedCand | Where-Object Package -eq 'uncfeed').PackageSource -eq '\\attacker\share' -and @($feedCand | Where-Object { $_.UseOfferedSource }).Count -eq 0)
$feeds.Clear()
$fr = @(New-InsightRecreatedApps -Candidates $feedCand)
Test-Check 'import without a yes: every app gets the own package source' (@($fr | Where-Object Done).Count -eq 3 -and $feeds['goodfeed'] -eq $false -and $feeds['uncfeed'] -eq $false -and $feeds['nofeed'] -eq $false) ($feeds | ConvertTo-Json -Compress)
foreach ($cand in $feedCand) { $cand.UseOfferedSource = $true }
$feeds.Clear()
$fr = @(New-InsightRecreatedApps -Candidates $feedCand)
Test-Check 'import with a yes: https source used, UNC source refused, app not created' ($feeds['goodfeed'] -eq $true -and -not $feeds.ContainsKey('uncfeed') -and ($fr | Where-Object Package -eq 'uncfeed').Done -eq $false -and ($fr | Where-Object Package -eq 'uncfeed').Message -like '*refused*' -and $feeds['nofeed'] -eq $false) ($fr | ConvertTo-Json -Compress)
$foreign = Get-InsightClassification -RawApps @([pscustomobject]@{ id = 'f1'; displayName = 'Foreign'; notes = 'PoweredByChocolatey;package=evil;version=latest;update=Startup;grace=48;source=https%3A%2F%2Fu%3Ap%40feed.example%2Fx%3Fk%3D1;delay=5-60'; createdDateTime = '2026-01-01T10:00:00Z'; AppType = 'Win32' })
$foreign[0].ProposedAction = 'Recreate'; $foreign[0].UseOfferedSource = $true
$feeds.Clear()
$fr = @(New-InsightRecreatedApps -Candidates $foreign)
Test-Check 'import from another tenant: a source with user info and query in the notes is refused' (-not $feeds.ContainsKey('evil') -and $fr[0].Done -eq $false) ($fr | ConvertTo-Json -Compress)

# ---- error codes
Test-Check 'error 1618' ((Get-InsightErrorCause 1618) -like '*another installation*')
Test-Check 'error 3010 / 1641' ((Get-InsightErrorCause 3010) -like '*restart is required*' -and (Get-InsightErrorCause 1641) -like '*restart*')
Test-Check 'error IME detection (signed int and hex)' ((Get-InsightErrorCause -2016345060) -like '*detection rule*' -and (Get-InsightErrorCause '0x87D1041C') -like '*detection rule*')
Test-Check 'error winget 0x8A150011' ((Get-InsightErrorCause '0x8A150011') -like 'winget*hash*')
Test-Check 'error winget unknown 0x8A1500FF' ((Get-InsightErrorCause '0x8A1500FF') -like 'winget error*')
Test-Check 'error unknown / empty' ((Get-InsightErrorCause 777) -eq 'error 0x00000309' -and $null -eq (Get-InsightErrorCause $null))

# ---- install status and merge
$now = [datetime]'2026-11-13T12:00:00Z'
$status = New-InsightGraphContext -Name fake -Invoke {
    param($m, $p, $b)
    if ($p -like '*/deviceStatuses') { @{ value = @(
                @{ deviceId = 'd1'; deviceName = 'PC-01'; userPrincipalName = 'a@contoso.example'; installState = 'installed'; displayVersion = '2.0'; lastSyncDateTime = '2026-11-13T08:00:00Z'; errorCode = 0 }
                @{ deviceId = 'd2'; deviceName = 'PC-02'; userPrincipalName = 'b@contoso.example'; installState = 'failed'; errorCode = 1618; lastSyncDateTime = '2026-11-12T08:00:00Z' }
                @{ deviceId = 'd3'; deviceName = 'PC-03'; userName = 'c'; installState = 'pendingInstall'; lastSyncDateTime = '2026-11-01T08:00:00Z' }) } }
    else { throw "unexpected $m $p" }
}
$st = Get-InsightAppInstallStatus -Context $status -AppId 'a1' -Now $now
Test-Check 'status counts' ($st.Installed -eq 1 -and $st.Failed -eq 1 -and $st.Pending -eq 1 -and $st.NotReported7Days -eq 1 -and $st.Endpoint -eq 'beta')
Test-Check 'status device row' (($st.Devices | Where-Object DeviceName -eq 'PC-02').Cause -like '*another installation*' -and ($st.Devices | Where-Object DeviceName -eq 'PC-02').ErrorCode -eq '0x00000652')
$run = [pscustomobject]@{ detectionState = 'success'; lastStateUpdateDateTime = '2026-11-13T09:00:00Z'; managedDevice = [pscustomobject]@{ id = 'm2'; deviceName = 'pc-02'; userPrincipalName = 'b@contoso.example' }
    preRemediationDetectionScriptOutput = '{"v":1,"n":2,"f":[{"p":"git","s":"c","t":"2026-11-13T07:00","a":"upgrade","e":1618,"c":"","v":"1.9","g":"2.0"}],"o":["7zip=23.01"],"x":0}' }
$rs = ConvertFrom-InsightRunState $run
Test-Check 'run state parsed' ($rs.Apps.Count -eq 2 -and $rs.Apps[0].Package -eq 'git' -and $rs.Apps[0].Cause -like '*another installation*' -and $rs.Apps[1].Ok)
$merged = Merge-InsightStatus -InstallStatus $st -Package 'git' -RunStates @($rs)
Test-Check 'merge by device name (case-insensitive)' (($merged.Devices | Where-Object DeviceName -eq 'PC-02').LastResult.TargetVersion -eq '2.0' -and $null -eq ($merged.Devices | Where-Object DeviceName -eq 'PC-01').LastResult)

# ---- status script: parses, ASCII, output below 2048 with 40 apps
$scriptText = Get-InsightStatusScriptText
$tokens = $null; $errors = $null
[void][Management.Automation.Language.Parser]::ParseInput($scriptText, [ref]$tokens, [ref]$errors)
Test-Check 'status script parses' ($errors.Count -eq 0) ($errors | Out-String)
Test-Check 'status script is ASCII' (-not ($scriptText.ToCharArray() | Where-Object { [int]$_ -gt 127 }))
$scriptFile = Join-Path $temp 'status.ps1'
[IO.File]::WriteAllText($scriptFile, $scriptText, (New-Object Text.UTF8Encoding($false)))
$chocoRoot = Join-Path $temp 'choco'; $wingetRoot = Join-Path $temp 'winget'
foreach ($i in 1..40) {
    $root = if ($i % 4 -eq 0) { $wingetRoot } else { $chocoRoot }
    $name = if ($i % 4 -eq 0) { "Vendor.Product$i" } else { "some-long-package-name-$i" }
    $dir = Join-Path $root $name; New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $bad5 = ($i % 5 -eq 0)
    @{ lastAttempt = '2026-11-13T07:00:00Z'; action = 'upgrade'; exitCode = $(if ($bad5) { 1603 } else { 0 }); cause = $(if ($bad5) { 'installer failed with a long explanation text that has to be shortened' } else { '' }); installedVersion = "10.20.$i.4711"; targetVersion = "10.21.$i.4712" } |
        ConvertTo-Json | Set-Content (Join-Path $dir 'last-result.json')
}
$out = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $scriptFile -ChocoRoot $chocoRoot -WingetRoot $wingetRoot
$out = ($out | Out-String).Trim()
$parsed = try { $out | ConvertFrom-Json } catch { $null }
Test-Check 'status output below 2048 chars with 40 apps' ($out.Length -gt 0 -and $out.Length -lt 2048) $out.Length
Test-Check 'status output is JSON, failed apps first, overflow counted' ($parsed -and $parsed.n -eq 40 -and @($parsed.f).Count -eq 8 -and ($parsed.x -gt 0) -and @($parsed.o).Count + @($parsed.f).Count + $parsed.x -eq 40) $out
$none = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $scriptFile -ChocoRoot (Join-Path $temp 'none') -WingetRoot (Join-Path $temp 'none2')
Test-Check 'status script tolerates missing folders' (($none | Out-String) -match '"n":0')

# ---- the status script reads what the device scripts write (Save-LastResult of Get-DeviceScriptCommon)
$commonAst = [Management.Automation.Language.Parser]::ParseInput((Get-DeviceScriptCommon), [ref]$null, [ref]$null)
$saveFn = $commonAst.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Save-LastResult' }, $true)
. ([scriptblock]::Create($saveFn.Extent.Text))
function Write-ProtectedFile([string]$Path, [string]$Text) { Set-Content -LiteralPath $Path -Value $Text -Encoding ASCII }   # stand-in, the real one only writes under %ProgramFiles%
$schemaRoot = Join-Path $temp 'schema'
foreach ($case in @(@('fails.pkg', 'upgrade', 'failed', 1603, 'failed: exit code 1603', '1.0', '2.0'), @('fine.pkg', 'install', 'ok', 0, 'ok', '3.1', '3.1'), @('waits.pkg', 'upgrade', 'skipped', 0, 'waiting: on battery', '4.0', '4.1'))) {
    $dir = Join-Path $schemaRoot $case[0]; New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $LogId = $case[0]; $ResultFile = Join-Path $dir 'last-result.json'
    Save-LastResult $case[1] $case[2] $case[3] $case[4] $case[5] $case[6]
}
$written = Get-Content (Join-Path $schemaRoot 'fails.pkg\last-result.json') -Raw | ConvertFrom-Json
Test-Check 'Save-LastResult writes the documented fields' ((@($written.PSObject.Properties.Name) -join ',') -eq 'format,package,lastAttempt,action,status,exitCode,cause,installedVersion,targetVersion') (@($written.PSObject.Properties.Name) -join ',')
$schemaOut = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $scriptFile -ChocoRoot $schemaRoot -WingetRoot (Join-Path $temp 'none')
$schema = ($schemaOut | Out-String).Trim() | ConvertFrom-Json
$f = @($schema.f)[0]
Test-Check 'status script reads every field Save-LastResult writes' ($schema.n -eq 3 -and @($schema.f).Count -eq 1 -and $f.p -eq 'fails.pkg' -and $f.t -match '^\d{4}-\d\d-\d\dT\d\d:\d\d$' -and $f.a -eq 'upgrade' -and $f.e -eq 1603 -and $f.c -eq 'failed: exit code 1603' -and $f.v -eq '1.0' -and $f.g -eq '2.0' -and (@($schema.o) -contains 'fine.pkg=3.1') -and (@($schema.o) -contains 'waits.pkg=4.0')) ($schemaOut | Out-String)
$statusFields = @([regex]::Matches($scriptText, '\$R\.(\w+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
$missing = @($statusFields | Where-Object { $_ -notin @($written.PSObject.Properties.Name) })
Test-Check 'status script reads no field the devices do not write' ($statusFields.Count -ge 5 -and $missing.Count -eq 0) ($missing -join ',')
Test-Check 'status script looks under %ProgramFiles%\IntuneChocoDeployment' ($scriptText -match "ProgramW6432" -and $scriptText -match "'IntuneChocoDeployment\\Chocolatey'" -and $scriptText -match "'IntuneChocoDeployment\\Winget'" -and $scriptText -notmatch 'ProgramData')

# ---- health script create/update and licence degrade
$calls = New-Object System.Collections.ArrayList
$ok = New-InsightGraphContext -Name fake -Invoke { param($m, $p, $b)
    [void]$calls.Add("$m $p")
    if ($m -eq 'GET') { @{ value = @() } } elseif ($p -like '*/assign') { @{} } else { @{ id = 'hs1' } } }
$created = Set-InsightStatusScript -Context $ok
Test-Check 'status script created and assigned hourly' ($created.Created -and $calls -contains 'POST /beta/deviceManagement/deviceHealthScripts' -and $calls -contains 'POST /beta/deviceManagement/deviceHealthScripts/hs1/assign')
$deny = New-InsightGraphContext -Name fake -Invoke { param($m, $p, $b) throw 'Graph GET failed (403): The tenant is not licensed for this feature' }
$degraded = Set-InsightStatusScript -Context $deny
Test-Check 'no licence: degrades without throwing' (-not $degraded.Created -and $degraded.Message -like '*not available*')

# ---- diagnostics: admin center pointer and zip extraction
$info = Get-InsightDiagnosticsInfo -ManagedDeviceId 'm1' -Package 'git'
Test-Check 'diagnostics: device page url and hint' ($info.Url -like 'https://intune.microsoft.com/*m1' -and $info.Hint -like '*PackTune-git.log*' -and $info.Hint -like '*Collect diagnostics*')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipSrc = Join-Path $temp 'zipsrc'; New-Item -ItemType Directory -Path "$zipSrc\IME" -Force | Out-Null
'a' | Set-Content "$zipSrc\IME\IntuneChocoDeployment-git.log"; 'b' | Set-Content "$zipSrc\IME\IntuneManagementExtension.log"
$zip = Join-Path $temp 'diag.zip'; [IO.Compression.ZipFile]::CreateFromDirectory($zipSrc, $zip)
$files = @(Expand-InsightLogs -ZipPath $zip -OutDir (Join-Path $temp 'ex'))
Test-Check 'zip: only our logs extracted' ($files.Count -eq 1 -and $files[0] -like '*IntuneChocoDeployment-git.log')

# ---- permissions
$ready = @(Test-InsightReadiness -GrantedScopes @('DeviceManagementApps.ReadWrite.All', 'DeviceManagementConfiguration.ReadWrite.All'))
Test-Check 'readiness: apps and scripts ready, device views missing' (($ready | Where-Object Function -eq 'Get-InsightAppInstallStatus').Ready -and -not ($ready | Where-Object Function -eq 'Get-InsightDeviceRunStates').Ready -and (($ready | Where-Object Function -eq 'Get-InsightDeviceRunStates').Missing -contains 'DeviceManagementManagedDevices.Read.All'))
$claims = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"scp":"DeviceManagementApps.Read.All Group.Read.All"}')).TrimEnd('=').Replace('+', '-').Replace('/', '_')
Test-Check 'token scopes read from the scp claim' ((Get-InsightTokenScopes "x.$claims.y") -contains 'Group.Read.All')
Test-Check 'registration requests the insight scope' ((Get-Content (Join-Path $repo 'PackTune-Main.ps1') -Raw) -match 'GraphInsightScopes' -and $script:GraphInsightScopes -contains 'DeviceManagementManagedDevices.Read.All')

Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failed) { throw "$script:Failed check(s) failed." }
'All checks passed.'
