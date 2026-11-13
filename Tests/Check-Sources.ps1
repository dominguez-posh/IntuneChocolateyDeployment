<#
.SYNOPSIS
    Non-GUI checks of the source functions (PackTune-Sources.ps1, PackTune-Release.ps1):
    recommended source, filter, merged search, deploy per source, winget runtime dependency, release through
    supersedence versus in-place update. Fake IntuneWin32App module and fake feed data, no network, no tenant.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Check-Sources.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneSources-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $work 'PackTune') -Force | Out-Null
$env:LOCALAPPDATA = $work
$env:PSModulePath = (Join-Path $PSScriptRoot 'Fakes') + ';' + $env:PSModulePath

$script:Failed = 0
function Test-Check([string]$Name, $Ok, $Detail) {
    if ($Ok) { "PASS  $Name" } else { $script:Failed++; "FAIL  $Name  $Detail" }
}

. (Join-Path $repo 'PackTune-Main.ps1')
Import-Module IntuneWin32App -Force

# Signed in (fake token), stand-ins for everything that would reach the network
$Global:AccessToken = [pscustomobject]@{ ExpiresOn = (Get-Date).AddHours(2).ToUniversalTime(); access_token = 'x.e30.y' }
$Global:AuthenticationHeader = @{ Authorization = 'Bearer x'; ExpiresOn = $Global:AccessToken.ExpiresOn }
$Global:AccessTokenTenantID = 'contoso.onmicrosoft.com'
$script:Png = 'iVBORw0KGgo='
$script:ChocoFeed = @{ googlechrome = '120.0.1'; firefox = '130.0'; '7zip' = '24.09'; notepadplusplus = '8.7.1'; vlc = '3.0.20'; 'only.choco' = '1.0' }
$script:WingetFeed = @{ 'Google.Chrome' = '121.0.5'; 'Mozilla.Firefox' = '130.0.0'; '7zip.7zip' = '25.01'; 'Notepad++.Notepad++' = '8.7'; 'VideoLAN.VLC' = ''; 'Other.WingetOnly' = '2.0' }
$script:ChocoVersions = @{ vlc = @('3.0.18', '3.0.19', '3.0.20'); '7zip' = @('24.08', '24.09'); 'only.choco' = @('0.9', '1.0') }
$script:FeedCalls = 0
function Assert-WingetClient { }
function Get-ChocoInfo { param([string]$ChocoName)
    $script:FeedCalls++
    if (-not $script:ChocoFeed.ContainsKey($ChocoName.ToLower())) { throw "Chocolatey package '$ChocoName' was not found on the feed" }
    [pscustomobject]@{ Name = $ChocoName.ToLower(); Title = "Title $ChocoName"; Version = $script:ChocoFeed[$ChocoName.ToLower()]; Summary = 's'; Description = "Description of $ChocoName"; Authors = 'Author'; SoftwareSite = 'https://example.org'; SoftwareLicense = $null; IconUrl = $null; Downloads = 1; IsLatest = $true; LicenseNote = $null }
}
function Get-WingetInfo { param([string]$WingetId)
    $script:FeedCalls++
    if (-not $script:WingetFeed.ContainsKey($WingetId)) { throw "winget package '$WingetId' was not found in the winget source" }
    [pscustomobject]@{ Name = $WingetId; Title = "Title $WingetId"; Version = $script:WingetFeed[$WingetId]; Summary = 's'; Description = "Description of $WingetId"; Authors = 'Publisher'; SoftwareSite = 'https://example.org'; SoftwareLicense = $null; License = $null; IconUrl = $null; Downloads = $null; IsLatest = $true; LicenseNote = $null; Source = 'Winget' }
}
function Search-ChocoPackage { param([string]$SearchPattern, [int]$Top)
    foreach ($Id in 'googlechrome', 'only.choco') { [pscustomobject]@{ Name = $Id; Title = "Title $Id"; Version = $script:ChocoFeed[$Id]; Authors = $null } }
}
function Search-WingetPackage { param([string]$SearchPattern, [int]$Top)
    foreach ($Id in 'Google.Chrome', 'Other.WingetOnly', 'Mozilla.Firefox') { [pscustomobject]@{ Name = $Id; Title = "Title $Id"; Version = $script:WingetFeed[$Id]; Authors = $null; Source = 'Winget' } }
}
function Get-ChocoPackageVersions { param([string]$ChocoName) @($script:ChocoVersions[$ChocoName.ToLower()]) }
function Get-WingetPackageVersions { param([string]$WingetId) @('2.0', '1.0') }
function Get-Store { @(Get-Content (Join-Path $env:LOCALAPPDATA 'fake-intune.json') -Raw | ConvertFrom-Json | ForEach-Object { $_ }) }
function Get-StoreApp([string]$Package) { @(Get-Store | Where-Object { $_.notes -like "*package=$Package;*" }) }

# --- recommended source: numeric, part by part
$cases = @(
    @('1.10', '1.9', 1), @('1.9', '1.10', -1), @('1.2', '1.2.0', 0), @('26.05', '25.01', 1), @('v2.0-beta', '2.0', 0), @('1.0', '', $null), @('abc', '1.0', $null), @('', '', $null)
)
foreach ($c in $cases) { $r = Compare-SourceVersion $c[0] $c[1]; Test-Check "compare '$($c[0])' '$($c[1])' = $($c[2])" ($r -eq $c[2] -and ($null -eq $r) -eq ($null -eq $c[2])) "got $r" }
$r = Get-RecommendedSource -HasChocolatey $true -HasWinget $true -ChocolateyVersion '120.0.1' -WingetVersion '121.0.5'
Test-Check 'higher winget version is recommended and marked' ($r.Source -eq 'Winget' -and $r.Marked)
$r = Get-RecommendedSource -HasChocolatey $true -HasWinget $true -ChocolateyVersion '130.0' -WingetVersion '129.9'
Test-Check 'higher Chocolatey version is recommended and marked' ($r.Source -eq 'Chocolatey' -and $r.Marked)
$r = Get-RecommendedSource -HasChocolatey $true -HasWinget $true -ChocolateyVersion '130.0' -WingetVersion '130.0.0'
Test-Check 'equal versions: no recommendation' ($null -eq $r.Source -and -not $r.Marked)
$r = Get-RecommendedSource -HasChocolatey $true -HasWinget $true -ChocolateyVersion '130.0' -WingetVersion ''
Test-Check 'unknown version: no recommendation' ($null -eq $r.Source)
$r = Get-RecommendedSource -HasChocolatey $false -HasWinget $true -WingetVersion '1.0'
Test-Check 'one source only: that source, not marked' ($r.Source -eq 'Winget' -and -not $r.Marked)

# --- catalog: ids of both sources
$catalog = @(Get-PackTuneCatalog)
$bad = @($catalog | Where-Object { $_.WingetId -and $_.WingetId -notmatch $script:WingetIdPattern })
Test-Check 'catalog winget ids are valid ids' ($bad.Count -eq 0) ($bad.WingetId -join ', ')
Test-Check 'catalog: Brackets has its winget id' (@($catalog | Where-Object { $_.Id -eq 'brackets' -and $_.WingetId -eq 'Adobe.Brackets' }).Count -eq 1)
$dup = @($catalog | Where-Object WingetId | Group-Object { $_.WingetId.ToLower() } | Where-Object Count -gt 1)
Test-Check 'catalog: no winget id twice' ($dup.Count -eq 0) ($dup.Name -join ', ')

# --- rows from the catalog with a cache (no feed call for what the cache has)
$cache = @{
    'googlechrome' = [pscustomobject]@{ Found = $true; Version = '120.0.1'; Title = 'Chrome' }
    'winget:google.chrome' = [pscustomobject]@{ Found = $true; Version = '121.0.5'; Title = 'Chrome' }
    'firefox' = [pscustomobject]@{ Found = $true; Version = '130.0' }
    'winget:mozilla.firefox' = [pscustomobject]@{ Found = $true; Version = '130.0.0' }
    'filezilla' = [pscustomobject]@{ Found = $true; Version = '3.0' }
}
$script:FeedCalls = 0
$rows = @(Get-PackTuneSourceApps -Cache $cache -NoFetch)
Test-Check 'one row per catalog entry, no feed call with -NoFetch' ($rows.Count -eq $catalog.Count -and $script:FeedCalls -eq 0) "rows $($rows.Count), calls $script:FeedCalls"
$chrome = $rows | Where-Object CatalogId -eq 'googlechrome'
Test-Check 'Chrome row: both sources, winget recommended' (($chrome.Sources -join ',') -eq 'Chocolatey,Winget' -and $chrome.Recommended -eq 'Winget' -and $chrome.RecommendedMarked -and $chrome.Source -eq 'Winget')
$firefox = $rows | Where-Object CatalogId -eq 'firefox'
Test-Check 'Firefox row: equal versions, default is the preferred source of the settings' ($null -eq $firefox.Recommended -and $firefox.Source -eq $script:Settings.Source)
$filezilla = $rows | Where-Object CatalogId -eq 'filezilla'
Test-Check 'FileZilla row: Chocolatey only, source set, not marked' (($filezilla.Sources -join ',') -eq 'Chocolatey' -and $filezilla.Recommended -eq 'Chocolatey' -and -not $filezilla.RecommendedMarked)
$both = @(Select-PackTuneSourceApps -Apps $rows -Filter Both)
$chocoOnly = @(Select-PackTuneSourceApps -Apps $rows -Filter Chocolatey)
$wingetOnly = @(Select-PackTuneSourceApps -Apps $rows -Filter Winget)
Test-Check 'filter: All = Both + Chocolatey only + winget only' ((@(Select-PackTuneSourceApps -Apps $rows -Filter All).Count) -eq ($both.Count + $chocoOnly.Count + $wingetOnly.Count))
Test-Check 'filter: Both has the apps with two ids' ($both.Count -eq @($catalog | Where-Object WingetId).Count -and $chocoOnly.Count -eq @($catalog | Where-Object { -not $_.WingetId }).Count -and $wingetOnly.Count -eq 0) "$($both.Count)/$($chocoOnly.Count)/$($wingetOnly.Count)"
Test-Check 'filter: Chocolatey only does not contain Chrome' ($chocoOnly.CatalogId -notcontains 'googlechrome' -and $chocoOnly.CatalogId -contains 'filezilla')
# a package the source does not know is no source of the app
$cache2 = @{ 'winget:google.chrome' = [pscustomobject]@{ Found = $false; NotFound = $true }; 'googlechrome' = [pscustomobject]@{ Found = $true; Version = '120.0' } }
$chrome2 = Get-PackTuneSourceApps -Cache $cache2 -NoFetch | Where-Object CatalogId -eq 'googlechrome'
Test-Check 'winget says not found: Chrome is Chocolatey only' (($chrome2.Sources -join ',') -eq 'Chocolatey' -and $null -eq $chrome2.WingetId)
# without a cache the feeds are asked and the answer is cached
$cache3 = @{}; $script:FeedCalls = 0
$null = Resolve-PackTuneSourceInfo -Source Winget -Id '7zip.7zip' -Cache $cache3
$null = Resolve-PackTuneSourceInfo -Source Winget -Id '7zip.7zip' -Cache $cache3
Test-Check 'feed read once, then from the cache' ($script:FeedCalls -eq 1 -and $cache3['winget:7zip.7zip'].Version -eq '25.01')

# --- merged search
$script:FeedCalls = 0
$found = @(Search-PackTuneApps -SearchPattern 'chrome' -Cache @{})
$names = $found | ForEach-Object { if ($_.CatalogId) { $_.CatalogId } elseif ($_.ChocoId) { $_.ChocoId } else { $_.WingetId } }
Test-Check 'search: Chrome of both sources is one row' (@($found | Where-Object CatalogId -eq 'googlechrome').Count -eq 1 -and $found.Count -eq 4) ($names -join ', ')
$c = $found | Where-Object CatalogId -eq 'googlechrome'
Test-Check 'search: merged row has both ids and versions' ($c.ChocoId -eq 'googlechrome' -and $c.WingetId -eq 'Google.Chrome' -and $c.ChocoVersion -eq '120.0.1' -and $c.WingetVersion -eq '121.0.5' -and $c.Recommended -eq 'Winget')
$ff = $found | Where-Object CatalogId -eq 'firefox'
Test-Check 'search: catalog app found by one source gets the other source from the feed' ($ff.ChocoId -eq 'firefox' -and $ff.ChocoVersion -eq '130.0' -and $ff.WingetVersion -eq '130.0.0' -and $null -eq $ff.Recommended)
$oc = $found | Where-Object ChocoId -eq 'only.choco'
$ow = $found | Where-Object WingetId -eq 'Other.WingetOnly'
Test-Check 'search: unknown packages stay separate rows of their source' ($oc -and -not $oc.WingetId -and $ow -and -not $ow.ChocoId -and $oc.Sources -eq 'Chocolatey' -and $ow.Sources -eq 'Winget')
$only = @(Search-PackTuneApps -SearchPattern 'chrome' -Cache @{} -Filter Both)
Test-Check 'search: filter Both' ($only.Count -eq 2)
function Search-WingetPackage { throw 'offline' }
$warn = @(); $partial = @(Search-PackTuneApps -SearchPattern 'chrome' -Cache @{} -NoFetch -WarningVariable warn -WarningAction SilentlyContinue)
Test-Check 'search: one source down, the other still answers with a warning' ($partial.Count -ge 2 -and $warn.Count -eq 1)

# --- deploy per source
$ids = @{ Assignment = 'Available'; IconBase64 = $script:Png }
$chromeRow = New-PackTuneSourceRow -Name 'Google Chrome' -CatalogId 'googlechrome' -ChocoId 'googlechrome' -WingetId 'Google.Chrome' -ChocoVersion '120.0.1' -WingetVersion '121.0.5'
$firefoxRow = New-PackTuneSourceRow -Name 'Mozilla Firefox' -CatalogId 'firefox' -ChocoId 'firefox' -WingetId 'Mozilla.Firefox' -ChocoVersion '131.0' -WingetVersion '130.0'
$vlcRow = New-PackTuneSourceRow -Name 'VLC' -CatalogId 'vlc' -ChocoId 'vlc' -WingetId 'VideoLAN.VLC' -ChocoVersion '3.0.20' -WingetVersion '3.0.20'
$id1 = New-PackTuneSourceApplication -App $chromeRow -Parameters $ids
$id2 = New-PackTuneSourceApplication -App $firefoxRow -Parameters $ids
$a1 = Get-Store | Where-Object id -eq $id1; $a2 = Get-Store | Where-Object id -eq $id2
Test-Check 'deploy: recommended source winget -> winget app' ($a1 -and $a1.notes -like 'PoweredByPackTune;from=Winget;package=Google.Chrome;*')
Test-Check 'deploy: recommended source Chocolatey -> Chocolatey app' ($a2 -and $a2.notes -like 'PoweredByPackTune;from=Chocolatey;package=firefox;*')
$id3 = New-PackTuneSourceApplication -App $vlcRow -Parameters $ids
$a3 = Get-Store | Where-Object id -eq $id3
Test-Check 'deploy: no recommendation -> preferred source of the settings' ($a3 -and ($a3.notes -like 'PoweredByWinget*') -eq ($script:Settings.Source -eq 'Winget')) $a3.notes
$npp = New-PackTuneSourceRow -Name 'Notepad++' -CatalogId 'notepadplusplus' -ChocoId 'notepadplusplus' -WingetId 'Notepad++.Notepad++' -ChocoVersion '8.7.1' -WingetVersion '8.7'
$npp.Source = 'Winget'
$id4 = New-PackTuneSourceApplication -App $npp -Parameters $ids
Test-Check 'deploy: the source chosen per app wins over the recommendation' ((Get-Store | Where-Object id -eq $id4).notes -like 'PoweredByPackTune;from=Winget;package=Notepad++.Notepad++;*')
$id5 = New-PackTuneSourceApplication -App $npp -Source Chocolatey -Parameters $ids
Test-Check '-Source overrides for all apps' ((Get-Store | Where-Object id -eq $id5).notes -like 'PoweredByPackTune;from=Chocolatey;package=notepadplusplus;*') ((Get-Store | Where-Object id -eq $id5).notes)
$err = $null
$null = New-PackTuneSourceApplication -App (New-PackTuneSourceRow -Name 'X' -ChocoId 'x') -Source Winget -ErrorVariable err -ErrorAction SilentlyContinue
Test-Check 'deploy: source the app does not have is an error' ($err.Count -eq 1)

# --- PackTune Runtime (one dependency app for both sources)
$runtime = @(Get-Store | Where-Object { $_.notes -like '*PackTuneRuntimeApp*' })
Test-Check 'runtime app is created once per tenant' ($runtime.Count -eq 1 -and $runtime[0].displayName -eq 'PackTune Runtime' -and $runtime[0].assignment -eq 'available')
Test-Check 'every new app of both sources depends on the one runtime (AutoInstall)' (@($a1.dependencies).targetId -contains $runtime[0].id -and @($a1.dependencies)[0].dependencyType -eq 'autoInstall' -and @((Get-Store | Where-Object id -eq $id4).dependencies).targetId -contains $runtime[0].id)
Test-Check 'Chocolatey apps depend on the same runtime, no separate Chocolatey app is created' (@($a2.dependencies).Count -eq 1 -and @($a2.dependencies).targetId -contains $runtime[0].id -and @(Get-Store | Where-Object { $_.displayName -eq 'Chocolatey' }).Count -eq 0 -and @(Get-Store | Where-Object { $_.displayName -eq 'winget runtime' }).Count -eq 0)
Test-Check 'runtime app is not listed as an app of the tool' (@(Get-PackTuneTenantApps | Where-Object { $_.Id -eq $runtime[0].id }).Count -eq 0)
$scripts = Get-PackTuneRuntimeScripts
foreach ($pair in @(@('install', $scripts.Install), @('detection', $scripts.Detection), @('update', $scripts.Update))) {
    $errors = $null; $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($pair[1], [ref]$tokens, [ref]$errors)
    Test-Check "runtime $($pair[0]) script: valid PowerShell, ASCII, no placeholder" ($errors.Count -eq 0 -and $pair[1] -notmatch '[^\x00-\x7F]' -and $pair[1] -notmatch '__[A-Z]+__') (@($errors | ForEach-Object Message) -join '; ')
}
Test-Check 'runtime install (both parts): Chocolatey bootstrap with retry, winget; mutex, SIDs, protected folders, 64-bit relaunch, provisioning' ($scripts.Install -match 'Global.IntuneChocoDeployment"' -and $scripts.Install -match 'Enter-DeploymentLock' -and $scripts.Install -match 'Exit-DeploymentLock' -and $scripts.Install -match 'S-1-5-18' -and $scripts.Install -match 'S-1-5-32-544' -and $scripts.Install -match 'Protect-Folder \$RuntimeRoot' -and $scripts.Install -match 'Sysnative' -and $scripts.Install -match 'Add-AppxProvisionedPackage' -and $scripts.Install -match 'DesktopAppInstaller_Dependencies' -and $scripts.Install -match 'community\.chocolatey\.org/install\.ps1' -and $scripts.Install -match 'Get-Random -Minimum 60 -Maximum 300' -and $scripts.Install -match 'chocolateyDownloadUrl')
Test-Check 'runtime detection: choco and winget work, marker revision, no time limit' ($scripts.Detection -match 'chocolatey\\bin\\choco\.exe' -and $scripts.Detection -match 'Get-Winget' -and $scripts.Detection -match 'ready\.txt' -and $scripts.Detection -match '--version' -and $scripts.Detection -notmatch 'TotalHours|AddHours|UtcNow|Get-Date')
Test-Check 'runtime install registers the daily update task for SYSTEM and copies update.ps1' ($scripts.Install -match 'Register-ScheduledTask' -and $scripts.Install -match 'S-1-5-18' -and $scripts.Install -match '-Daily' -and $scripts.Install -match 'Intune-Winget-Updates' -and $scripts.Install -match 'Update PackTune Runtime' -and $scripts.Install -match 'Copy-Item[^\n]*update\.ps1' -and $scripts.Install -match 'Write-ProtectedFile \(Join-Path \$RuntimeRoot "ready\.txt"\)' -and $scripts.Install -notmatch 'upgrade --id')
Test-Check 'runtime update script: mutex, protected folder check, device log, upgrade once per 20 hours' ($scripts.Update -match 'Enter-DeploymentLock' -and $scripts.Update -match 'Exit-DeploymentLock' -and $scripts.Update -match 'Test-ForeignItem' -and $scripts.Update -match 'Write-DeviceLog' -and $scripts.Update -match '\$LogId = "_packtune-runtime"' -and $scripts.Update -match '"upgrade", "chocolatey"' -and $scripts.Update -match 'upgrade --id Microsoft.AppInstaller' -and $scripts.Update -match 'TotalHours -lt 20' -and $scripts.Update -match 'Global.IntuneChocoDeployment"')
# every file the runtime install.ps1 copies from its own folder is in the package that was built
$runtimeSource = Join-Path $env:LOCALAPPDATA 'PackTune\package\_packtune-runtime\source'
$rtAst = [System.Management.Automation.Language.Parser]::ParseInput($scripts.Install, [ref]$null, [ref]$null)
$rtCopied = @($rtAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Join-Path' -and $n.Extent.Text -like 'Join-Path $PSScriptRoot *' }, $true) | ForEach-Object { $_.CommandElements[2].Value })
Test-Check 'runtime: every helper install.ps1 copies is in the package' ($rtCopied.Count -ge 1 -and @($rtCopied | Where-Object { -not (Test-Path -LiteralPath (Join-Path $runtimeSource $_)) }).Count -eq 0) "copied: $($rtCopied -join ','); folder: $(@(Get-ChildItem $runtimeSource -ErrorAction SilentlyContinue).Name -join ',')"
# security review: folders under %ProgramFiles%, signature pin, no winget from PATH (comments removed before matching)
function Get-CodeOnly([string]$Text) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    foreach ($t in @($tokens | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset } -Descending)) { $Text = $Text.Remove($t.Extent.StartOffset, $t.Extent.EndOffset - $t.Extent.StartOffset) }
    $Text
}
$rtInstall = Get-CodeOnly $scripts.Install; $rtDetection = Get-CodeOnly $scripts.Detection; $rtUpdate = Get-CodeOnly $scripts.Update
Test-Check 'runtime: folders under %ProgramFiles%\PackTune\Runtime, nothing under %ProgramData% of the tool' ($rtInstall -match '\$RuntimeRoot = Join-Path \$ToolRoot "Runtime"' -and $rtInstall -match 'Protect-Folder \$ToolRoot' -and $rtDetection -match '"PackTune\\Runtime\\ready\.txt"' -and $rtDetection -match 'ProgramW6432' -and ($rtInstall + $rtDetection + $rtUpdate) -notmatch 'IntuneWingetDeployment|IntuneChocoUpdates')
Test-Check 'runtime: App Installer bundle and dependencies must carry a valid Microsoft signature before provisioning' ($rtInstall -match 'Get-AuthenticodeSignature -LiteralPath \$Path' -and $rtInstall.Contains('"CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US"') -and $rtInstall -match '\[string\]\$Signature\.Status -ne "Valid" -or \$Signer -ne \$MicrosoftPublisher' -and $rtInstall.IndexOf('Assert-MicrosoftSigned $File') -gt 0 -and $rtInstall.IndexOf('Assert-MicrosoftSigned $File') -lt $rtInstall.IndexOf('Add-AppxProvisionedPackage -Online -PackagePath $Bundle -DependencyPackagePath'))
Test-Check 'runtime: winget only from WindowsApps, never from PATH' (($rtInstall + $rtDetection + $rtUpdate) -notmatch 'Get-Command winget' -and $rtDetection -match 'WindowsApps')
Test-Check 'runtime: revision in install and detection' ([int]$script:RuntimeRevision -ge 1 -and $scripts.Detection -match "\`$Revision = '$($script:RuntimeRevision)'")
# The signature check itself, on a signed and an unsigned file of this machine (read-only)
$sigAst = [System.Management.Automation.Language.Parser]::ParseInput($scripts.Install, [ref]$null, [ref]$null)
$sigFn = $sigAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-MicrosoftSigned' }, $true)
$MicrosoftPublisher = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
. ([scriptblock]::Create($sigFn.Extent.Text))
$unsigned = Join-Path $work 'fake.msixbundle'; 'not a package' | Set-Content $unsigned
Test-Check 'runtime: an unsigned download is refused' ($(try { Assert-MicrosoftSigned $unsigned; $false } catch { $_.Exception.Message -like '*not validly signed by Microsoft*' }))
# Chain root pinned to Microsoft Root Certificate Authority 2011 (an enterprise CA with the Microsoft subject must fail)
Test-Check 'runtime: signer chain must end in the Microsoft Root CA 2011' ($rtInstall -match '\$MicrosoftRoots = @\("8F43288AD272F3103B6FB1428485EA3014C0BCFE"\)' -and $rtInstall -match '\$Chain\.Build\(\$Signature\.SignerCertificate\)' -and $rtInstall -match '\$ChainRoot -notin \$MicrosoftRoots')
$edge = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
if (Test-Path -LiteralPath $edge) {
    # Edge is signed by "Microsoft Corporation" and chains to Root 2011: accepted with the real pin, refused with another root
    $MicrosoftRoots = @('8F43288AD272F3103B6FB1428485EA3014C0BCFE')
    Test-Check 'runtime: a Microsoft Corporation file chaining to Root 2011 is accepted' ($(try { Assert-MicrosoftSigned $edge; $true } catch { $false }))
    $MicrosoftRoots = @('0000000000000000000000000000000000000000')
    Test-Check 'runtime: same subject but another root is refused' ($(try { Assert-MicrosoftSigned $edge; $false } catch { $_.Exception.Message -like '*does not chain to the Microsoft root*' }))
    $MicrosoftRoots = @('8F43288AD272F3103B6FB1428485EA3014C0BCFE')
}
# Validly signed, but by "Microsoft Windows" (catalog), not by the App Installer publisher
Test-Check 'runtime: a valid signature of another Microsoft publisher is refused' ($(try { Assert-MicrosoftSigned "$env:SystemRoot\System32\notepad.exe"; $false } catch { $_.Exception.Message -like '*status Valid*' -or $_.Exception.Message -like '*not validly signed*' }))

$runtimeId = Get-PackTuneRuntimeWin32ID
Test-Check 'runtime app found again, not created twice' ($runtimeId -eq $runtime[0].id -and @(Get-Store | Where-Object { $_.notes -like '*PackTuneRuntimeApp*' }).Count -eq 1)
# a winget app from before the runtime existed
$legacy = Get-Store | Where-Object id -eq $id1
$stored = Get-Content (Join-Path $env:LOCALAPPDATA 'fake-intune.json') -Raw | ConvertFrom-Json
foreach ($s in @($stored)) { if ($s.id -eq $id1) { $s.dependencies = @() } }
ConvertTo-Json -InputObject @($stored) -Depth 6 | Set-Content (Join-Path $env:LOCALAPPDATA 'fake-intune.json')
$without = @(Get-PackTuneAppsWithoutRuntime)
Test-Check 'apps without the runtime dependency are found' ($without.Count -eq 1 -and $without[0].Id -eq $id1) "$($without.Count)"
$added = @(Add-PackTuneRuntimeDependency)
$after = Get-Store | Where-Object id -eq $id1
Test-Check 'dependency is added to the old winget app, others are left alone' ($added.Count -eq 1 -and @($added | Where-Object Added).Count -eq 1 -and @($after.dependencies).targetId -contains $runtimeId)
Test-Check 'adding it again changes nothing' (@(Add-PackTuneRuntimeDependency | Where-Object Added).Count -eq 0 -and @((Get-Store | Where-Object id -eq $id1).dependencies).Count -eq 1)


# --- migration of an existing tenant: old Chocolatey app and old winget runtime app
$Store = Join-Path $env:LOCALAPPDATA 'fake-intune.json'
$stored = @(Get-Content $Store -Raw | ConvertFrom-Json | ForEach-Object { $_ })
$oldChoco = [pscustomobject]@{ id = 'old-choco'; displayName = 'Chocolatey'; notes = 'FiredWithPowershell'; dependencies = @(); supersedence = @(); assignments = @() }
$oldWinget = [pscustomobject]@{ id = 'old-winget'; displayName = 'winget runtime'; notes = 'WingetRuntimeApp'; dependencies = @(); supersedence = @(); assignments = @() }
foreach ($s in $stored) {
    if ($s.id -eq $id2) { $s.dependencies = @([pscustomobject]@{ targetId = 'old-choco'; dependencyType = 'autoInstall' }) }
    if ($s.id -eq $id1) { $s.dependencies = @([pscustomobject]@{ targetId = 'old-winget'; dependencyType = 'autoInstall' }) }
}
ConvertTo-Json -InputObject @($stored + $oldChoco + $oldWinget) -Depth 6 | Set-Content $Store
$old = @(Get-PackTuneOldDependencyApps)
Test-Check 'old Chocolatey app and old winget runtime app are recognized' ($old.Count -eq 2 -and ($old | Where-Object Kind -eq 'Chocolatey').Id -eq 'old-choco' -and ($old | Where-Object Kind -eq 'WingetRuntime').Id -eq 'old-winget')
Test-Check 'old dependency apps are not apps of the runtime and not in the tool list as dependency of PackTune' (@(Get-PackTuneTenantApps | Where-Object { $_.Id -eq 'old-winget' }).Count -eq 0)
$state = Get-PackTuneRuntimeState
Test-Check 'readiness state: runtime present, apps still on old dependencies -> Migrate' ($state.State -eq 'Migrate' -and $state.RuntimePresent -and $state.RuntimeId -eq $runtimeId -and @($state.AppsOnOldDependencies).Count -ge 2 -and @($state.UnusedOld).Count -eq 0)
$unusedBefore = @(Get-PackTuneUnusedDependencyApps)
Test-Check 'old apps in use are not offered for removal' ($unusedBefore.Count -eq 0)
$choco2 = $false
try { Remove-PackTuneApp -Id 'old-choco' } catch { $choco2 = $_.Exception.Message -like '*Switch them to the PackTune Runtime*' }
Test-Check 'old Chocolatey app in use cannot be removed' ($choco2 -and @(Get-Store | Where-Object id -eq 'old-choco').Count -eq 1)
$moved = @(Switch-PackTuneAppsToRuntime)
$after1 = Get-Store | Where-Object id -eq $id1; $after2 = Get-Store | Where-Object id -eq $id2
Test-Check 'switch: apps get the runtime, the old dependency is taken away' (@($after1.dependencies).Count -eq 1 -and @($after1.dependencies).targetId -eq $runtimeId -and @($after2.dependencies).Count -eq 1 -and @($after2.dependencies).targetId -eq $runtimeId -and $moved.Count -ge 2 -and (@($moved | Where-Object OldRemoved).Count -ge 2))
Test-Check 'switch again changes nothing' (@(Switch-PackTuneAppsToRuntime).Count -eq 0)
$state = Get-PackTuneRuntimeState
Test-Check 'readiness state after the switch: Ready, both old apps unused' ($state.State -eq 'Ready' -and @($state.UnusedOld).Count -eq 2 -and @($state.AppsOnOldDependencies).Count -eq 0)
$dry = @(Remove-PackTuneUnusedDependencyApps -WhatIf)
Test-Check '-WhatIf lists the unused old apps and deletes nothing' ($dry.Count -eq 2 -and @(Get-Store | Where-Object id -in 'old-choco', 'old-winget').Count -eq 2)
Test-Check 'nothing is deleted automatically (switch left the old apps)' (@(Get-Store | Where-Object id -in 'old-choco', 'old-winget').Count -eq 2)
$gone = @(Remove-PackTuneUnusedDependencyApps)
Test-Check 'unused old dependency apps can be removed on request' ($gone.Count -eq 2 -and @(Get-Store | Where-Object id -in 'old-choco', 'old-winget').Count -eq 0)
# an old app that is still used by an app outside the tool stays on the list of used ones
$stored = @(Get-Content $Store -Raw | ConvertFrom-Json | ForEach-Object { $_ })
ConvertTo-Json -InputObject @($stored + [pscustomobject]@{ id = 'old-choco'; displayName = 'Chocolatey'; notes = 'FiredWithPowershell'; dependencies = @(); supersedence = @(); assignments = @() } + [pscustomobject]@{ id = 'foreign'; displayName = 'Other app'; notes = ''; dependencies = @([pscustomobject]@{ targetId = 'old-choco'; dependencyType = 'autoInstall' }); supersedence = @(); assignments = @() }) -Depth 6 | Set-Content $Store
Test-Check 'old app used by any app in the tenant is not offered for removal' (@(Get-PackTuneUnusedDependencyApps).Count -eq 0)
ConvertTo-Json -InputObject @(@(Get-Content $Store -Raw | ConvertFrom-Json | ForEach-Object { $_ }) | Where-Object { $_.id -notin 'old-choco', 'foreign' }) -Depth 6 | Set-Content $Store
# no runtime yet: state Missing
$none = @(Get-Content $Store -Raw | ConvertFrom-Json | ForEach-Object { $_ })
ConvertTo-Json -InputObject @($none | Where-Object { $_.notes -notlike '*PackTuneRuntimeApp*' }) -Depth 6 | Set-Content $Store
Test-Check 'readiness state without runtime: Missing' ((Get-PackTuneRuntimeState).State -eq 'Missing')
ConvertTo-Json -InputObject @($none) -Depth 6 | Set-Content $Store
Test-Check 'compat names of the interface point to the one runtime' ((get-ChocoWin32ID) -eq $runtimeId -and (Get-WingetRuntimeWin32ID -NoCreate) -eq $runtimeId)
# app registration: the old name is recognized, the owner check stays (see GUI smoke test for the creation path)
$reg = (Get-Command New-PackTuneAppRegistration).Parameters
Test-Check 'app registration is named PackTune and recognizes the old name' ($reg.DisplayName.Attributes.Count -ge 0 -and (Get-Content (Join-Path $repo 'PackTune-Main.ps1') -Raw) -match '\[string\]\$DisplayName = "PackTune"' -and (Get-Content (Join-Path $repo 'PackTune-Main.ps1') -Raw) -match 'FormerNames = @\("Intune Chocolatey Deployment"\)' -and (Get-Content (Join-Path $repo 'PackTune-Main.ps1') -Raw) -match 'you are not its only owner')
# --- release: supersedence for Available, in place for Required
$pin = @{ Assignment = 'Available'; IconBase64 = $script:Png; Version = '24.08' }
$availId = New-PackTuneChocolateyApp -ChocoName '7zip' @pin
Test-Check 'precondition: pinned Available Chocolatey app' ($availId -and (Get-PackTuneReleasePath -AppId $availId) -eq 'Supersedence')
$result = Publish-PackTuneRelease -AppId $availId -Version '24.09'
$old = Get-Store | Where-Object id -eq $availId
$new = Get-Store | Where-Object id -eq $result.AppId
Test-Check 'Available app: release goes through supersedence' ($result.Path -eq 'Supersedence' -and $result.AppId -ne $availId -and $result.OldAppId -eq $availId)
Test-Check 'new app: version, notes, name, icon and settings copied' ($new.displayVersion -eq '24.09' -and $new.notes -like '*package=7zip;version=24.09;*' -and $new.displayName -eq $old.displayName -and $new.hasIcon -and $new.description -eq $old.description -and $new.applicableArchitectures -eq $old.applicableArchitectures -and $new.publisher -eq $old.publisher) "$($new.notes)"
Test-Check 'new app supersedes the old one with type update' (@($new.supersedence).Count -eq 1 -and $new.supersedence[0].targetId -eq $availId -and $new.supersedence[0].supersedenceType -eq 'update')
Test-Check 'new app has the dependencies of the old one' (@($new.dependencies).Count -eq @($old.dependencies).Count -and @($new.dependencies).Count -ge 1 -and @($new.dependencies)[0].targetId -eq @($old.dependencies)[0].targetId)
Test-Check 'new app: same Available assignment with auto-update of superseded apps' (@($new.assignments).Count -eq 1 -and $new.assignments[0].Intent -eq 'available' -and $new.assignments[0].AutoUpdateSupersededApps -eq 'enabled')
Test-Check 'old app is untouched (content, assignment)' ($old.uploads -eq 1 -and $old.assignment -eq 'available' -and $old.notes -like '*version=24.08;*')
# Required: in place
$reqId = New-PackTuneChocolateyApp -ChocoName 'only.choco' -Assignment Required -IconBase64 $script:Png -Version '0.9'
Test-Check 'precondition: Required app takes the in-place path' ((Get-PackTuneReleasePath -AppId $reqId) -eq 'InPlace')
$appsBefore = (Get-Store).Count
$r2 = Publish-PackTuneRelease -AppId $reqId -Version '1.0'
$req = Get-Store | Where-Object id -eq $reqId
Test-Check 'Required app: updated in place, no new app' ($r2.Path -eq 'InPlace' -and $r2.AppId -eq $reqId -and (Get-Store).Count -eq $appsBefore -and $req.uploads -eq 2 -and $req.notes -like '*version=1.0;*' -and @($req.supersedence).Count -eq 0)
# Required and Available together: in place as well
$stored = Get-Content (Join-Path $env:LOCALAPPDATA 'fake-intune.json') -Raw | ConvertFrom-Json
foreach ($s in @($stored)) { if ($s.id -eq $reqId) { $s.assignments = @($s.assignments) + [pscustomobject]@{ Type = '#microsoft.graph.groupAssignmentTarget'; Intent = 'available'; GroupID = 'g1' } } }
ConvertTo-Json -InputObject @($stored) -Depth 6 | Set-Content (Join-Path $env:LOCALAPPDATA 'fake-intune.json')
Test-Check 'Required plus Available: in place' ((Get-PackTuneReleasePath -AppId $reqId) -eq 'InPlace')
# a failing release leaves nothing behind
$before = (Get-Store).Count
# (not $failed: variable names ignore case, that would be the failure counter $script:Failed)
$releaseThrew = $false
try { Publish-PackTuneRelease -AppId $availId -Version '9.9.9' | Out-Null } catch { $releaseThrew = $true }
Test-Check 'unknown version: error, no new app' ($releaseThrew -and (Get-Store).Count -eq $before)

# --- cleanup of superseded apps
$rows = @(Get-PackTuneSupersededApps)
Test-Check 'superseded app is found' ($rows.Count -eq 1 -and $rows[0].OldId -eq $availId -and $rows[0].NewId -eq $result.AppId -and $rows[0].NewVersion -eq '24.09')
$kept = @(Remove-PackTuneSupersededApps -InstallCount { param($Id) 3 })
Test-Check 'still installed on devices: stays' ($kept.Count -eq 1 -and -not $kept[0].Removed -and $kept[0].InstalledCount -eq 3 -and @(Get-Store | Where-Object id -eq $availId).Count -eq 1)
$unknown = @(Remove-PackTuneSupersededApps -InstallCount { param($Id) throw 'no status' })
Test-Check 'install status not readable: stays' (-not $unknown[0].Removed -and @(Get-Store | Where-Object id -eq $availId).Count -eq 1)
$dry = @(Remove-PackTuneSupersededApps -InstallCount { param($Id) 0 } -WhatIf)
Test-Check '-WhatIf removes nothing' (-not $dry[0].Removed -and @(Get-Store | Where-Object id -eq $availId).Count -eq 1)
$gone = @(Remove-PackTuneSupersededApps -InstallCount { param($Id) 0 })
Test-Check 'no device has it: old app removed, new app stays, relation cleared' ($gone[0].Removed -and @(Get-Store | Where-Object id -eq $availId).Count -eq 0 -and @(Get-Store | Where-Object id -eq $result.AppId).Count -eq 1 -and @((Get-Store | Where-Object id -eq $result.AppId).supersedence).Count -eq 0 -and @((Get-Store | Where-Object id -eq $result.AppId).dependencies).Count -ge 1)
Test-Check 'nothing left to clean up' (@(Remove-PackTuneSupersededApps -InstallCount { param($Id) 0 }).Count -eq 0)

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failed -gt 0) { "$script:Failed check(s) failed."; exit 1 }
'All checks passed.'
