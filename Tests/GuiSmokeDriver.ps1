# Dot-sourced by Start-IntuneChocoTool.ps1 when INTUNECHOCO_SMOKE is set (see Tests\Invoke-GuiSmoke.ps1).
# Puts the window off-screen and walks through the steps below on the UI thread; each step returns $true when it is
# done (or $false to be asked again on the next tick), so background tasks can finish in between.
# Screenshots of every page and dialog land in the output folder (shot-NN-*.png).

$script:SmokeOut = $env:INTUNECHOCO_SMOKE_OUT
$script:SmokeResults = New-Object System.Collections.ArrayList
$window.WindowStartupLocation = 'Manual'
$window.Left = -20000; $window.Top = -20000
$window.ShowActivated = $false
$window.ShowInTaskbar = $false

function Test-Smoke([string]$Name, [bool]$Ok, $Detail) {
    $line = if ($Ok) { "PASS $Name" } else { "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" } else { '' }) }
    [void]$script:SmokeResults.Add($line)
}
function Save-SmokeShot([string]$Name) {
    $window.UpdateLayout()
    $w = [int]$window.ActualWidth; $h = [int]$window.ActualHeight
    $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($window.Content)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [IO.File]::Create((Join-Path $script:SmokeOut "shot-$Name.png"))
    try { $enc.Save($fs) } finally { $fs.Dispose() }
}
function Get-SmokeLog { $script:UiLogLines -join "`n" }
function Get-JobLog { (@($script:JobRows | ForEach-Object { $_.Data.Log | ForEach-Object { $_.Text } }) ) -join "`n" }
# Without a kind: no task except the icon rendering, which runs on its own pool next to everything else
function Test-Idle([string]$Kind) { -not @($script:Tasks | Where-Object { if ($Kind) { $_.Job.Kind -eq $Kind } else { $_.Job.Kind -ne 'icons' } }).Count }
function Get-StoreApps { @(Get-Content (Join-Path $env:LOCALAPPDATA 'fake-intune.json') -Raw | ConvertFrom-Json | ForEach-Object { $_ }) }
function Get-StoreApp([string]$Package) { @(Get-StoreApps | Where-Object { $_.notes -like "*package=$Package;*" })[-1] }
function Find-Visual($Parent, [type]$Type) {
    for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Parent); $i++) {
        $c = [System.Windows.Media.VisualTreeHelper]::GetChild($Parent, $i)
        if ($c -is $Type) { return $c }
        $r = Find-Visual $c $Type; if ($r) { return $r }
    }
}
function Get-Card([string]$Key) { @($script:CardCollection | Where-Object { (Get-AppKey $_.Data) -eq $Key })[0] }
function Test-GeneratedScripts([string]$Folder, [string]$What) {
    # The scripts that run on the devices must at least be valid PowerShell, without leftover placeholders
    foreach ($file in Get-ChildItem $Folder -Filter '*.ps1' -Recurse) {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
        $text = Get-Content $file.FullName -Raw
        Test-Smoke "$What script $($file.Name) is valid" ($errors.Count -eq 0 -and $text -notmatch '__[A-Z]+__') (@($errors | ForEach-Object { $_.Message }) -join '; ')
    }
    $install = Get-Content (Join-Path $Folder 'source\install.ps1') -Raw
    $update = Get-Content (Join-Path $Folder 'source\update.ps1') -Raw
    Test-Smoke "$What scripts share the device lock" ($install -match 'Global.IntuneChocoDeployment"' -and $install -match 'Enter-DeploymentLock' -and $update -match 'Enter-DeploymentLock')
    Test-Smoke "$What helper folder is protected by SID" ($install -match 'Protect-Folder' -and $install -match 'S-1-5-18' -and $install -match 'S-1-5-32-544')
}

# Fake Graph for the insight functions (counts, status, status script, import): script text, run inside the task runspaces
$script:InsightFake = @'
param([string]$Method, [string]$Path, $Body)
$Dir = $env:LOCALAPPDATA
$P = [uri]::UnescapeDataString($Path)
$Now = (Get-Date).ToUniversalTime()
if ($P -like '*/deviceStatuses*') {
    return @{ value = @(
        @{ deviceId = 'md-1'; deviceName = 'PC-0142'; userPrincipalName = 'j.weber@example.test'; installState = 'failed'; installStateDetail = 'installFailed'; displayVersion = '23.1'; errorCode = 1; lastSyncDateTime = $Now.ToString('o') }
        @{ deviceId = 'md-2'; deviceName = 'NB-0288'; userPrincipalName = 'a.keller@example.test'; installState = 'pendingInstall'; installStateDetail = 'pending'; displayVersion = '23.1'; lastSyncDateTime = $Now.ToString('o') }
        @{ deviceId = 'md-3'; deviceName = 'PC-0001'; userPrincipalName = 'm.schulz@example.test'; installState = 'installed'; installStateDetail = 'ok'; displayVersion = '26.6.0'; lastSyncDateTime = $Now.ToString('o') }
        @{ deviceId = 'md-4'; deviceName = 'PC-0002'; userPrincipalName = 'shared@example.test'; installState = 'installed'; installStateDetail = 'ok'; displayVersion = '26.6.0'; lastSyncDateTime = $Now.AddDays(-12).ToString('o') }
    ) }
}
if ($P -like '*/deviceHealthScripts/*/deviceRunStates*') {
    $Out = '{"f":[{"p":"7zip.install","s":"c","t":"11:50","a":"upgrade","e":1,"c":"Download blocked by the Chocolatey rate limit","v":"23.1","g":"26.6.0"}],"o":[]}'
    return @{ value = @(@{ detectionState = 'success'; lastStateUpdateDateTime = $Now.ToString('o'); preRemediationDetectionScriptOutput = $Out; managedDevice = @{ id = 'md-1'; deviceName = 'PC-0142'; userPrincipalName = 'j.weber@example.test' } }) }
}
if ($P -like '*/deviceHealthScripts/*/assign') { return @{} }
if ($P -like '*/deviceHealthScripts*') {
    if ($Method -eq 'POST') { Set-Content (Join-Path $Dir 'fake-health.json') '{"id":"hs-1"}'; return @{ id = 'hs-1' } }
    if (Test-Path (Join-Path $Dir 'fake-nolicense.txt')) { throw 'Graph GET failed (403): forbidden, the tenant has no license for this (fake)' }
    if ($P -like '*top=1*') { return @{ value = @() } }
    if (Test-Path (Join-Path $Dir 'fake-health.json')) { return @{ value = @(@{ id = 'hs-1'; displayName = 'IntuneChocoDeployment status' }) } }
    return @{ value = @() }
}
if ($P -like '*mobileApps/*' -and $Method -eq 'PATCH') { Add-Content (Join-Path $Dir 'fake-patches.log') $P; return @{} }
if ($P -like '*/mobileApps?*') {
    if ($P -like '*winGetApp*') { return @{ value = @() } }
    return @{ value = @(
        [pscustomobject]@{ id = 'i1'; displayName = 'Zoom Workplace'; notes = ''; installCommandLine = 'winget install --id Zoom.Zoom -e --silent'; createdDateTime = '2026-01-01T10:00:00Z'; displayVersion = '' }
        [pscustomobject]@{ id = 'i2'; displayName = 'Own VPN'; notes = ''; installCommandLine = 'msiexec /i OwnVpn.msi /qn'; createdDateTime = '2026-01-02T10:00:00Z'; displayVersion = '' }
        [pscustomobject]@{ id = 'i3'; displayName = 'Greenshot'; notes = ''; installCommandLine = 'choco install greenshot -y --version 1.3.290'; createdDateTime = '2026-01-03T10:00:00Z'; displayVersion = '' }
        [pscustomobject]@{ id = 'i4'; displayName = 'Sample managed'; notes = 'PoweredByChocolatey;package=sample.pkg;version=latest;update=Startup;grace=48;source=;delay=5-60'; installCommandLine = ''; createdDateTime = '2026-01-04T10:00:00Z'; displayVersion = '' }
    ) }
}
throw "Fake Graph: $Method $P"
'@

$script:SmokeSteps = [System.Collections.ArrayList]@(
    @{ Name = 'start page'; Do = {
        Test-Smoke 'fake module counts as installed' $script:ModuleState.Ok $script:ModuleState.Version
        Test-Smoke 'readiness shows 5 items' ($ui.ReadinessPanel.Children.Count -eq 5) $ui.ReadinessPanel.Children.Count
        Test-Smoke 'signed out: split button shown, account pill hidden' ((-not (Test-SignedIn)) -and $ui.PanelSignedOut.Visibility -eq 'Visible' -and $ui.BtnAccount.Visibility -eq 'Collapsed' -and $ui.BtnSignIn.IsEnabled)
        Test-Smoke 'navigation has the five entries, no package source switch' ($ui.NavStart -and $ui.NavApps -and $ui.NavTenant -and $ui.NavActivity -and $ui.NavSettings -and $ui.NavHelp -and -not $ui.ContainsKey('SrcWinget'))
        Test-Smoke 'help dialog opens' ($(Show-Help; $ui.DialogLayer.Visibility -eq 'Visible' -and $ui.DlgHelp.Visibility -eq 'Visible' -and $ui.HelpBody.Children.Count -ge 4))
        Save-SmokeShot '00-help'
        Close-Dialog
        Test-Smoke 'dialog closes' ($ui.DialogLayer.Visibility -eq 'Collapsed')
        Test-Smoke 'Keevault detection runs' ($null -ne (Find-KeevaultMcp).Installed)
        $true } }
    @{ Name = 'sign-in can be cancelled'; Phase = 0; Do = {
        param($s)
        # A browser that never answers (the user closed the window): the sign-in must end on Cancel
        if ($s.Phase -eq 0) { $s.Phase = 1; $script:SignInTest = @{ Authority = $env:INTUNECHOCO_SMOKE_AUTHORITY; UrlHandler = 'param($Url)' }; Connect-Intune; return $false }
        if ($s.Phase -eq 1) {
            if (-not @($script:Tasks | Where-Object { $_.Job.Kind -eq 'connect' -and $_.Job.Status -eq 'running' }).Count) { return $false }
            $s.Phase = 2
            Test-Smoke 'button offers to cancel while the sign-in waits' ($ui.BtnSignIn.Content -eq 'Cancel sign-in' -and $ui.BtnSignIn.IsEnabled -and -not $ui.BtnSignInMenu.IsEnabled) $ui.BtnSignIn.Content
            & $script:ClickActions[$ui.BtnSignIn]
            return $false
        }
        if (-not (Test-Idle 'connect')) { return $false }
        Test-Smoke 'cancelled sign-in ends and is logged' ((-not (Test-SignedIn)) -and ((Get-SmokeLog) + (Get-JobLog)) -match 'Sign-in cancelled')
        Test-Smoke 'sign in is offered again' ($ui.BtnSignIn.Content -eq 'Sign in' -and $ui.BtnSignIn.IsEnabled -and $ui.BtnSignInMenu.IsEnabled) $ui.BtnSignIn.Content
        $true } }
    @{ Name = 'set up everything'; Started = $false; Waited = 0; Do = {
        param($s)
        if (-not $s.Started) {
            $s.Started = $true
            # No app registration yet: the item is red, says why and offers Create; green items have no button
            $cfg = Get-IntuneChocoSettings; $cfg.ClientID = ''; [void](Save-IntuneChocoSettings -Settings $cfg); $script:Settings = Get-IntuneChocoSettings
            Show-Page 'Start'
            $cards = @(Get-ReadinessItems)
            $appreg = $cards | Where-Object Key -eq 'appreg'
            Test-Smoke 'missing app registration is red with a reason' ($appreg.State -eq 'bad' -and $appreg.Text -like '*app registration*') $appreg.Text
            $buttons = @($ui.ReadinessPanel.Children | ForEach-Object { @($_.Child.Children | Where-Object { $_ -is [System.Windows.Controls.Button] }) | ForEach-Object { [string]$_.Content } })
            Test-Smoke 'only items that are not ready have a button (Create, Sign in)' (($buttons -join ',') -eq 'Create,Sign in') ($buttons -join ',')
            Test-Smoke 'status report is optional and not counted' (($cards | Where-Object Key -eq 'status').Optional -and $ui.TxtReadinessSummary.Text -like '*3 of 4 not ready*' -or $ui.TxtReadinessSummary.Text -like '*of 4*') $ui.TxtReadinessSummary.Text
            Test-Smoke 'set up everything offered' ($ui.BtnSetupAll.Visibility -eq 'Visible' -and $ui.TxtReadinessSummary.Text -like '*not ready*') $ui.TxtReadinessSummary.Text
            Save-SmokeShot '01-start'
            # Instead of a browser: request the sign-in URL; the stand-in authority redirects to the loopback port
            $script:SignInTest.UrlHandler = 'param($Url) $global:SmokeClient = New-Object System.Net.WebClient; [void]$global:SmokeClient.DownloadStringTaskAsync([uri]$Url)'
            $script:SignInTest.GraphUrl = $env:INTUNECHOCO_SMOKE_AUTHORITY
            & $script:ClickActions[$ui.BtnSetupAll]
            return $false
        }
        $s.Waited++
        if (($script:SetupRunning -or -not (Test-Idle)) -and $s.Waited -lt 1500) { return $false }
        $log = Get-SmokeLog + (Get-JobLog)
        Test-Smoke 'set up finished' ((-not $script:SetupRunning) -and $log -match 'Everything is set up') (($log -split "`n" | Select-Object -Last 3) -join ' | ')
        Test-Smoke 'app registration created with admin consent' ($log -match "App registration 'Intune Chocolatey Deployment' created" -and $log -match 'Admin consent granted: DeviceManagementApps\.ReadWrite\.All')
        Test-Smoke 'tenant and client id saved' ((Get-IntuneChocoSettings).ClientID -eq '11111111-2222-3333-4444-555555555555' -and (Get-IntuneChocoSettings).TenantID -eq 'contoso.onmicrosoft.com')
        $names = @(Get-StoreApps | ForEach-Object { $_.displayName })
        Test-Smoke 'Chocolatey and the winget runtime deployed by the set up' (@($script:TenantApps | Where-Object IsChocolatey).Count -eq 1 -and $script:RuntimeId -and ($names -contains 'Chocolatey') -and ($names -contains 'winget runtime')) ($names -join ', ')
        Test-Smoke 'all required items green, set up button gone' (@(Get-ReadinessItems | Where-Object { $_.State -ne 'ok' -and -not $_.Optional }).Count -eq 0 -and $ui.BtnSetupAll.Visibility -eq 'Collapsed') $ui.TxtReadinessSummary.Text
        $true } }
    @{ Name = 'sign in'; Do = {
        Test-Smoke 'signed in through the browser flow (PKCE, loopback)' (Test-SignedIn)
        Test-Smoke 'account pill shows name and tenant, split button gone' ($ui.BtnAccount.Visibility -eq 'Visible' -and $ui.PanelSignedOut.Visibility -eq 'Collapsed' -and $script:AccountText -like '*Test Admin*contoso.onmicrosoft.com*') $script:AccountText
        Test-Smoke 'token carries refresh token and client id' ($Global:AccessToken.RefreshToken -eq 'refresh-Test Admin' -and $Global:AccessToken.ClientID -eq '11111111-2222-3333-4444-555555555555')
        $Global:AccessToken.ExpiresOn = (Get-Date).ToUniversalTime().AddMinutes(2)
        Update-UiToken
        $identity = Get-IntuneChocoIdentity
        Test-Smoke 'expiring token renewed silently' ($identity.Name -eq 'Test Admin renewed' -and ([datetime]$identity.ExpiresOn) -gt (Get-Date).ToUniversalTime().AddMinutes(30)) $identity.Name
        Test-Smoke 'renewed token handed to the tasks' ($script:Shared.Auth.AccessToken.RefreshToken -eq 'refresh-Test Admin renewed')
        $cultureBefore = [Threading.Thread]::CurrentThread.CurrentCulture.Name
        $direct = 'not reached'
        do { $direct = @(Get-IntuneWin32App).Count } while ($false)
        Test-Smoke 'fake module gives up silently when called directly (like the real one)' ($direct -eq 'not reached') $direct
        Test-Smoke 'module call works through Invoke-IntuneModule' (@(Invoke-IntuneModule { Get-IntuneWin32App }).Count -ge 1)
        try { Invoke-IntuneModule { Write-Warning 'gave up' 3>$null; break }; Test-Smoke 'a module give-up becomes an error' $false }
        catch { Test-Smoke 'a module give-up becomes an error' ($_.Exception.Message -like '*gave up without a result*') $_.Exception.Message }
        Test-Smoke 'culture restored after the module call' ([Threading.Thread]::CurrentThread.CurrentCulture.Name -eq $cultureBefore)
        Test-Smoke 'missing permissions would be offered (none missing here)' (@(Get-MissingScopes).Count -eq 0) (@(Get-MissingScopes) -join ',')
        $missing = @(Test-InsightReadiness -GrantedScopes @('DeviceManagementApps.ReadWrite.All') | Where-Object { -not $_.Ready })
        Test-Smoke 'readiness check names missing scopes (grant new permissions)' ($missing.Count -gt 0)
        $true } }
    @{ Name = 'status report setup'; Phase = 0; Do = {
        param($s)
        if ($s.Phase -eq 0) {
            $s.Phase = 1
            if (-not (Test-Idle)) { $s.Phase = 0; return $false }
            Test-Smoke 'status script missing: optional item offers Set up' ($script:StatusScript.State -eq 'Missing' -and (Get-ReadinessItems | Where-Object Key -eq 'status').Fix -eq 'Set up') ($script:StatusScript | ConvertTo-Json -Compress)
            Start-StatusScriptSetup
            return $false
        }
        if (-not (Test-Idle)) { return $false }
        Test-Smoke 'status script created and assigned' ($script:StatusScript.State -eq 'Present' -and (Test-Path (Join-Path $env:LOCALAPPDATA 'fake-health.json')) -and (Get-JobLog) -match 'created|assigned') ($script:StatusScript | ConvertTo-Json -Compress)
        $true } }
    @{ Name = 'apps list'; Started = $false; Waited = 0; Do = {
        param($s)
        if (-not $s.Started) { $s.Started = $true; Show-Page 'Apps'; return $false }
        $s.Waited++
        if (-not (Test-Idle 'meta') -and $s.Waited -lt 1500) { return $false }
        Update-CatalogRows; Update-AppList
        $cards = @($script:CardCollection)
        Test-Smoke 'one list shows every catalog app' ($cards.Count -eq $script:Catalog.Count) "$($cards.Count) of $($script:Catalog.Count)"
        Test-Smoke 'category chips with counts (All + categories)' ($script:Chips.Count -ge 5 -and $script:Chips['All'].Content -like "All*$($script:Catalog.Count)") ($script:Chips['All'].Content)
        Test-Smoke 'default view: All sources selected, no source switch in the header' ($ui.FltAll.IsChecked -and $script:SourceFilter -eq 'All')
        $zip = $script:SourceRows | Where-Object { $_.CatalogId -eq '7zip.install' } | Select-Object -First 1
        Test-Smoke '7-Zip has both sources with versions' ($zip.Sources.Count -eq 2 -and $zip.ChocoVersion -and $zip.WingetVersion) ($zip | Select-Object ChocoVersion, WingetVersion, Recommended | ConvertTo-Json -Compress)
        $rec = @($script:SourceRows | Where-Object RecommendedMarked)
        Test-Smoke 'a recommended source is marked where versions differ' ($rec.Count -ge 0) $rec.Count
        $zipCard = Get-Card '7zip.install'
        Test-Smoke 'card shows source tags with versions' (@($zipCard.Items | ForEach-Object { $_['Text'] }) -join ',' -match 'winget .*Choco ' ) (@($zipCard.Items | ForEach-Object { $_['Text'] }) -join ',')
        Test-Smoke 'license badge on AnyDesk' ((Get-Card 'anydesk')['Badge'] -eq 'Check license') (Get-Card 'anydesk')['Badge']
        # source filter keeps the exclusive semantics of the backend
        foreach ($f in 'Winget', 'Chocolatey', 'Both') {
            $ui["Flt$(if ($f -eq 'Chocolatey') { 'Choco' } else { $f })"].IsChecked = $true
            $expected = @(Select-IntuneChocoSourceApps -Apps $script:SourceRows -Filter $f).Count
            Test-Smoke "source filter $f shows $expected apps" ($script:CardCollection.Count -eq $expected) $script:CardCollection.Count
        }
        $ui.FltAll.IsChecked = $true
        $script:Chips['Browsers'].IsChecked = $true
        Test-Smoke 'category chip narrows the list' ($script:CardCollection.Count -eq @($script:SourceRows | Where-Object Category -eq 'Browsers').Count) $script:CardCollection.Count
        Save-SmokeShot '02-apps'
        $script:Chips['All'].IsChecked = $true
        $true } }
    @{ Name = 'filter, selection, details'; Do = {
        $ui.TxtFilter.Text = 'scratch'
        Test-Smoke 'filter narrows to Scratch' ($script:CardCollection.Count -eq 1) $script:CardCollection.Count
        Test-Smoke 'filter hint hidden while typing' ($ui.HintFilter.Visibility -eq 'Collapsed')
        Set-AppSelected $script:CardCollection[0].Data $true
        $ui.TxtFilter.Text = '7-zip'
        Set-AppSelected $script:CardCollection[0].Data $true
        Test-Smoke 'selection kept across filters' ($script:Selected.Count -eq 2 -and $script:Selected.Contains('scratch') -and $script:Selected.Contains('7zip.install')) (@($script:Selected.Keys) -join ',')
        Test-Smoke 'card shows the selected state' ((Get-Card '7zip.install')['Selected'] -eq 'True')
        Test-Smoke 'floating bar shows count and Review and deploy' ($ui.SelectionBar.Visibility -eq 'Visible' -and $ui.TxtSelectionCount.Text -eq '2 apps selected' -and $ui.BtnReview.IsEnabled) $ui.TxtSelectionCount.Text
        Show-AppDetails (Get-Card '7zip.install').Data
        Test-Smoke 'details side panel shows the clicked app with both sources' ($ui.PanelDetails.Visibility -eq 'Visible' -and $ui.TxtDetailTitle.Text -eq '7-Zip' -and $ui.TxtDetailSources.Text -match 'winget' -and $ui.TxtDetailSources.Text -match 'Chocolatey') $ui.TxtDetailSources.Text
        Test-Smoke 'details offer test in sandbox and custom icon' ($ui.BtnDetailTest.IsEnabled -and $ui.BtnCustomIcon.IsEnabled)
        $ui.TxtFilter.Text = ''
        Save-SmokeShot '03-selection-details'
        $true } }
    @{ Name = 'custom icon'; Do = {
        Add-Type -AssemblyName System.Drawing
        $bmpFile = Join-Path $script:SmokeOut 'custom.bmp'
        $b = New-Object System.Drawing.Bitmap 64, 64
        $g = [System.Drawing.Graphics]::FromImage($b); $g.Clear([System.Drawing.Color]::SteelBlue); $g.Dispose()
        $b.Save($bmpFile, [System.Drawing.Imaging.ImageFormat]::Bmp); $b.Dispose()
        Set-CustomIcon -Key 'scratch' -Path $bmpFile
        Test-Smoke 'custom icon stored as PNG' ([string]$script:CustomIcons['scratch'] -like 'iVBORw0KGgo*')
        Show-AppDetails (Get-Card 'scratch').Data
        Test-Smoke 'custom icon shown in details' ($ui.BtnCustomIconRemove.Visibility -eq 'Visible' -and $null -ne $ui.ImgDetail.Source)
        $true } }
    @{ Name = 'deploy dialog'; Started = $false; Waited = 0; Do = {
        param($s)
        if (-not $s.Started) {
            $s.Started = $true
            $ui.RbAvailable.IsChecked = $true
            Show-DeployDialog
            Test-Smoke 'deploy dialog opens with a row per app' ($ui.DlgDeploy.Visibility -eq 'Visible' -and $ui.PanelDeployRows.Children.Count -eq 2 -and $ui.TxtDeployTitle.Text -like 'Deploy 2 apps to contoso*') $ui.TxtDeployTitle.Text
            $zip = $script:DeployCombos | Where-Object { $_.Key -eq '7zip.install' }
            Test-Smoke 'per app source dropdown lists both sources, wide enough' ($zip.Combo.Items.Count -eq 2 -and $zip.Combo.Width -ge 280 -and $zip.Combo.SelectedItem) (@($zip.Combo.Items) -join ' | ')
            Test-Smoke 'recommended source is labelled when versions differ' ((@($zip.Combo.Items) -join '|') -match 'recommended' -or -not $zip.Src.RecommendedMarked) (@($zip.Combo.Items) -join ' | ')
            Test-Smoke 'dialog starts with the settings defaults' ($ui.CmbDeployAssign.SelectedIndex -eq 1 -and $ui.CmbDeployVersion.SelectedIndex -eq 0 -and $ui.PanelDeployGrace.Visibility -ne 'Visible')
            Test-Smoke 'dependency hint shown' ($ui.TxtDeployDependency.Inlines.Count -ge 2)
            $ui.CmbDeployUpdate.SelectedIndex = 2
            Test-Smoke 'grace period appears for the user prompt' ($ui.PanelDeployGrace.Visibility -eq 'Visible' -and $ui.TxtDeployUpdateHelp.Text -like '*installed anyway*')
            $ui.TxtDeployGrace.Text = 'x'
            try { [void](Read-PolicyControls 'Deploy'); Test-Smoke 'invalid grace period rejected' $false } catch { Test-Smoke 'invalid grace period rejected' ($_.Exception.Message -like '*90 days*') $_.Exception.Message }
            $ui.CmbDeployUpdate.SelectedIndex = 1
            Save-SmokeShot '04-deploy-dialog'
            # Both apps from Chocolatey: the fake winget source only knows a few apps
            foreach ($entry in $script:DeployCombos) { $entry.Combo.SelectedIndex = [array]::IndexOf($entry.Sources, 'Chocolatey') }
            Start-Deploy
            Test-Smoke 'dialog closes and Activity opens' ($ui.DialogLayer.Visibility -eq 'Collapsed' -and $script:CurrentPage -eq 'Activity')
            Test-Smoke 'selection cleared after queueing' ($script:Selected.Count -eq 0 -and $ui.SelectionBar.Visibility -eq 'Collapsed')
            Test-Smoke 'jobs show up in the activity list' ($script:JobRows.Count -ge 2) $script:JobRows.Count
            Test-Smoke 'activity badge counts the running jobs' ($ui.BadgeActivity.Visibility -eq 'Visible') $ui.TxtBadgeActivity.Text
            Save-SmokeShot '05-activity-running'
            return $false
        }
        $s.Waited++
        if (-not (Test-Idle) -and $s.Waited -lt 1500) { return $false }
        $apps = Get-StoreApps
        $names = @($apps | ForEach-Object { $_.displayName })
        Test-Smoke '7-Zip and Scratch created next to the dependency apps' (($names -contains '7-Zip') -and ($names -contains 'Scratch') -and $apps.Count -eq 4) ($names -join ', ')
        $zip = $apps | Where-Object { $_.displayName -eq '7-Zip' }
        $scratch = $apps | Where-Object { $_.displayName -eq 'Scratch' }
        Test-Smoke '7-Zip icon converted from SVG' ($zip.hasIcon -and $zip.iconValid)
        Test-Smoke 'Scratch has the custom icon' ($scratch.hasIcon -and $scratch.iconValid)
        Test-Smoke 'apps assigned as available' (@($apps | Where-Object { $_.displayName -in '7-Zip', 'Scratch' -and $_.assignment -eq 'available' }).Count -eq 2)
        Test-Smoke 'notes carry the package id and the update settings' ($zip.notes -match '^PoweredByChocolatey;package=7zip\.install;version=latest;update=Startup;grace=48;source=[^;]*;delay=\d+-\d+;cfg=[A-Za-z0-9_-]+$') $zip.notes
        $log = Get-SmokeLog
        Test-Smoke 'log shows both successes' (($log -match '\[7zip\.install\] created in Intune') -and ($log -match '\[scratch\] created in Intune'))
        Test-Smoke 'finished jobs are marked Done' (@($script:JobRows | Where-Object { $_['Status'] -eq 'Done' }).Count -ge 2) (@($script:JobRows | ForEach-Object { $_['Status'] }) -join ',')
        Test-Smoke 'toast announces the result' ($ui.ToastHost.Children.Count -ge 1)
        Show-Page 'Activity'
        Save-SmokeShot '06-activity-done'
        $true } }
    @{ Name = 'tenant'; Started = $false; Waited = 0; Do = {
        param($s)
        if (-not $s.Started) { $s.Started = $true; if (Test-Idle 'tenant') { Start-TenantRefresh }; return $false }
        $s.Waited++
        if (-not (Test-Idle) -and $s.Waited -lt 1500) { return $false }
        Show-Page 'Tenant'
        $rows = @($script:TenantRowList)
        Test-Smoke 'tenant lists dependency apps first, then the two apps' ($rows.Count -eq 4 -and $rows[0].Data.IsChocolatey -and $rows[1].Data.IsDependency) (($rows | ForEach-Object { $_['Title'] }) -join ', ')
        Test-Smoke 'subtitle counts apps and dependency apps' ($ui.TxtTenantCount.Text -like '2 apps and 2 dependency apps*contoso*') $ui.TxtTenantCount.Text
        $zip = $rows | Where-Object { $_['Title'] -eq '7-Zip' }
        Test-Smoke 'row shows package, source, version and assignment' ($zip['Sub'] -like '7zip.install*Chocolatey' -and $zip['Assigned'] -eq 'Available' -and $zip['Version'] -eq 'Always newest') ($zip['Sub'] + '|' + $zip['Assigned'] + '|' + $zip['Version'])
        Test-Smoke 'device counts linked from the install status' ($zip['Ok'] -eq '2 installed' -and $zip['Bad'] -eq '1 failed') ($zip['Ok'] + '|' + $zip['Bad'])
        Test-Smoke 'nav badge shows the devices with problems' ($ui.BadgeTenant.Visibility -eq 'Visible' -and $ui.TxtBadgeTenant.Text -like '*problem*') $ui.TxtBadgeTenant.Text
        $ui.LstTenant.SelectedItem = $zip
        Test-Smoke 'panel shows the selected app with version and update mode' ($ui.ScrollTenantApp.Visibility -eq 'Visible' -and $ui.TxtTenantAppTitle.Text -eq '7-Zip' -and $ui.RbTenantStartup.IsChecked -and $ui.CmbTenantVersion.SelectedIndex -eq 0)
        Test-Smoke 'panel summarises when updates install' ($ui.TxtTenantWhen.Text -like '*10:00 to 15:00*' -and $ui.TxtTenantConditions.Text) "$($ui.TxtTenantWhen.Text) | $($ui.TxtTenantConditions.Text)"
        Test-Smoke 'Available note shown for an Available app' ($ui.TxtTenantAvailableNote.Visibility -eq 'Visible')
        Test-Smoke 'open, test, remove enabled for a selected app' ($ui.BtnTenantOpen.IsEnabled -and $ui.BtnTenantRemove.IsEnabled)
        $ui.LstTenant.SelectedItem = $rows[0]
        Test-Smoke 'dependency app has no update controls' ($ui.GbTenantPolicy.Visibility -eq 'Collapsed' -and $ui.BtnTenantApply.Visibility -eq 'Collapsed')
        $ui.LstTenant.SelectedItem = $zip
        Save-SmokeShot '07-tenant'
        $true } }
    @{ Name = 'catalog knows the tenant'; Do = {
        Show-Page 'Apps'
        $marked = @($script:CardCollection | Where-Object { $_['Badge'] -eq 'In tenant' } | ForEach-Object { Get-AppKey $_.Data }) -join ','
        Test-Smoke 'deployed apps are marked in the list' ($marked -eq '7zip.install,scratch') $marked
        $ui.TxtFilter.Text = 'scratch'
        Set-AppSelected $script:CardCollection[0].Data $true
        try { Show-DeployDialog; Start-Deploy; Test-Smoke 'app in the tenant is not deployed again' $false }
        catch { Test-Smoke 'app in the tenant is not deployed again' ($_.Exception.Message -like '*already in the tenant*' -and (Test-Idle 'deploy')) $_.Exception.Message }
        Close-Dialog
        Clear-Selection
        $ui.TxtFilter.Text = ''
        $true } }
    @{ Name = 'remove from Intune'; Phase = 0; Do = {
        param($s)
        if ($s.Phase -eq 0) {
            $s.Phase = 1
            Show-Page 'Tenant'
            $ui.LstTenant.SelectedItem = @($script:TenantRowList | Where-Object { $_.Data.IsChocolatey })[0]
            try { & $script:ClickActions[$ui.BtnTenantRemove]; Test-Smoke 'Chocolatey is not removed while apps depend on it' $false }
            catch { Test-Smoke 'Chocolatey is not removed while apps depend on it' ($_.Exception.Message -like '*dependency of*') $_.Exception.Message }
            $ui.LstTenant.SelectedItem = @($script:TenantRowList | Where-Object { $_.Data.Package -eq 'scratch' })[0]
            & $script:ClickActions[$ui.BtnTenantRemove]
            return $false
        }
        if (-not (Test-Idle)) { return $false }
        $rows = @($script:TenantRowList)
        Test-Smoke 'Scratch removed from the tenant' ($rows.Count -eq 3 -and -not @($rows | Where-Object { $_.Data.Package -eq 'scratch' }).Count -and (Get-SmokeLog) -match '\[scratch\] removed from Intune') $rows.Count
        Test-Smoke 'list no longer marks Scratch' (-not $script:TenantPackages.ContainsKey('scratch') -and $script:TenantPackages.ContainsKey('7zip.install'))
        $true } }
    @{ Name = 'search both repositories'; Started = $false; Do = {
        param($s)
        if (-not $s.Started) { $s.Started = $true; Show-Page 'Apps'; $ui.TxtFilter.Text = 'notepad'; Start-AppSearch; return $false }
        if (-not (Test-Idle 'search') -or -not (Test-Idle 'meta')) { return $false }
        $rows = @($script:SearchRows)
        Test-Smoke 'search merges both repositories into rows' ($rows.Count -gt 0 -and @($rows | Where-Object { $_.Name -like 'Notepad*' }).Count) (($rows | ForEach-Object { "$($_.Name)[$($_.Sources -join '/')]" }) -join ', ')
        $npp = $script:SourceRows | Where-Object { $_.CatalogId -eq 'notepadplusplus.install' -or $_.Name -like 'Notepad++*' } | Select-Object -First 1
        Test-Smoke 'a catalog app found in both is one card with both sources' ($npp.Sources.Count -eq 2 -and @($script:CardCollection | Where-Object { $_['Title'] -eq $npp.Name }).Count -eq 1) (($npp.Sources -join ',') + ' ' + @($script:CardCollection | ForEach-Object { $_['Title'] }) -join ';')
        Test-Smoke 'hits not in the catalog are added to the list' ($script:CardCollection.Count -ge 1)
        Save-SmokeShot '08-search'
        $ui.TxtFilter.Text = ''
        $script:SearchRows = @(); $script:SearchTerm = ''
        Update-AppList
        $true } }
    @{ Name = 'winget deploy and runtime dependency'; Phase = 0; Do = {
        param($s)
        if ($s.Phase -eq 0) {
            $s.Phase = 1
            Clear-Selection
            $vlc = $script:SourceRows | Where-Object { $_.WingetId -eq 'VideoLAN.VLC' } | Select-Object -First 1
            Set-AppSelected $vlc $true
            $ui.RbAvailable.IsChecked = $true
            Show-DeployDialog
            $combo = $script:DeployCombos[0]
            $combo.Combo.SelectedIndex = [array]::IndexOf($combo.Sources, 'Winget')
            Test-Smoke 'winget source chosen per app in the dialog' ($combo.Sources[$combo.Combo.SelectedIndex] -eq 'Winget' -and $script:SourceChoice[(Get-AppKey $vlc)] -eq 'Winget')
            Start-Deploy
            return $false
        }
        if (-not (Test-Idle)) { return $false }
        $apps = Get-StoreApps
        $vlc = $apps | Where-Object { $_.notes -like 'PoweredByWinget;package=VideoLAN.VLC;version=latest;update=Startup;grace=48;source=;delay=*' }
        Test-Smoke 'winget VLC created with the catalog name' ($vlc.displayName -eq 'VLC media player' -and $vlc.assignment -eq 'available') (($apps | ForEach-Object { "$($_.displayName)|$($_.notes)" }) -join '; ')
        $vlcLog = (@((Get-JobLog) -split "`n" | Where-Object { $_ -match 'ependenc' }) -join ' | ')
        Test-Smoke 'winget app has the winget runtime dependency, no Chocolatey dependency' (($vlcLog -match 'Adding dependency for the winget runtime') -and ($vlcLog -notmatch 'dependency for chocolatey')) $vlcLog
        $pkg = Get-ChildItem (Join-Path $script:WorkRoot 'package\winget-VideoLAN.VLC\source\install.ps1') -ErrorAction SilentlyContinue
        Test-Smoke 'winget install script written' ($pkg -and (Get-Content $pkg.FullName -Raw) -match "'VideoLAN.VLC'")
        Test-GeneratedScripts (Join-Path $script:WorkRoot 'package\winget-VideoLAN.VLC') 'winget'
        # An older winget app without the dependency: banner offers to add it
        $store = Join-Path $env:LOCALAPPDATA 'fake-intune.json'
        $all = Get-StoreApps; ($all | Where-Object { $_.notes -like 'PoweredByWinget*' }).dependencies = @()
        ConvertTo-Json -InputObject @($all) -Depth 6 | Set-Content $store
        Start-RuntimeCheck
        return $true
        return $false } }
    @{ Name = 'runtime dependency banner'; Phase = 0; Do = {
        param($s)
        if ($s.Phase -eq 0) {
            if (-not (Test-Idle)) { return $false }
            Show-Page 'Tenant'; Update-TenantRows -Force
            Test-Smoke 'banner offers the missing winget runtime dependency' ($ui.BannerRuntime.Visibility -eq 'Visible' -and $ui.TxtBannerRuntime.Text -like '*VLC*') $ui.TxtBannerRuntime.Text
            $ui.LstTenant.SelectedItem = @($script:TenantRowList | Where-Object { $_.Data.Package -eq 'VideoLAN.VLC' })[0]
            Test-Smoke 'panel of the app mentions it too' ($ui.TxtDependencyNote.Visibility -eq 'Visible')
            Save-SmokeShot '09-tenant-runtime-banner'
            & $script:ClickActions[$ui.BtnBannerRuntime]
            $s.Phase = 1
            return $false
        }
        if (-not (Test-Idle)) { return $false }
        $vlc = Get-StoreApps | Where-Object { $_.notes -like 'PoweredByWinget*' }
        Test-Smoke 'dependency added, banner gone' (@($vlc.dependencies).Count -eq 1 -and $ui.BannerRuntime.Visibility -eq 'Collapsed') "$(@($vlc.dependencies).Count) / $($ui.BannerRuntime.Visibility)"
        $true } }
    @{ Name = 'update settings and schedule'; Phase = 0; Do = {
        param($s)
        switch ($s.Phase) {
            0 {
                # Chocolatey app with its own settings at the deployment: pinned, user prompt, 3 days, own schedule
                Show-Page 'Apps'; Clear-Selection
                $s.Package = 'putty.install'
                $row = $script:SourceRows | Where-Object { $_.ChocoId -eq $s.Package } | Select-Object -First 1
                Set-AppSelected $row $true
                $ui.RbAvailable.IsChecked = $true
                Show-DeployDialog
                $script:DeployCombos[0].Combo.SelectedIndex = [array]::IndexOf($script:DeployCombos[0].Sources, 'Chocolatey')
                $ui.CmbDeployUpdate.SelectedIndex = 2
                $ui.TxtDeployGrace.Text = '3'; $ui.CmbDeployGraceUnit.SelectedIndex = 1; $ui.CmbDeployVersion.SelectedIndex = 1
                Test-Smoke 'deploy dialog links to the schedule' ($ui.BtnDeploySchedule.Visibility -eq 'Visible' -and $ui.TxtDeploySchedule.Text)
                & $script:ClickActions[$ui.BtnDeploySchedule]
                Test-Smoke 'schedule dialog opens for the new apps (no apply-to switch)' ($ui.DlgSchedule.Visibility -eq 'Visible' -and $ui.SegSchedule.Visibility -eq 'Collapsed' -and $ui.BtnScheduleApply.Content -eq 'Use for these apps') $ui.BtnScheduleApply.Content
                $ui.SchFrom.Text = '12:00'; $ui.SchTo.Text = '13:00'; $ui.SchMains.IsChecked = $true; $ui.SchStart.IsChecked = $false
                $ui.SchD6.IsChecked = $false; $ui.SchD7.IsChecked = $false
                Update-ScheduleSummary
                Test-Smoke 'one-line summary follows the fields' ($ui.TxtScheduleSummary.Text -like 'Summary: Daily 12:00 to 13:00*mains power*' -or $ui.TxtScheduleSummary.Text -like '*Mon to Fri*12:00 to 13:00*mains*') $ui.TxtScheduleSummary.Text
                Save-SmokeShot '10-schedule-dialog'
                $ui.SchFrom.Text = '25:00'
                try { [void](Read-ScheduleControls); Test-Smoke 'invalid time rejected' $false } catch { Test-Smoke 'invalid time rejected' ($_.Exception.Message -like '*time like 10:00*') $_.Exception.Message }
                $ui.SchFrom.Text = '12:00'
                & $script:ClickActions[$ui.BtnScheduleApply]
                Test-Smoke 'schedule is kept for the deployment, deploy dialog is back' ($ui.DlgDeploy.Visibility -eq 'Visible' -and $script:DeploySchedule.OnlyOnMains -and $ui.TxtDeploySchedule.Text -like '*12:00 to 13:00*') $ui.TxtDeploySchedule.Text
                Start-Deploy
                $s.Phase = 1
                return $false
            }
            1 {
                if (-not (Test-Idle)) { return $false }
                $app = Get-StoreApp $s.Package
                Test-Smoke 'deployment carries update settings and schedule' ($app.notes -match 'update=Custom;grace=72;source=[^;]*;delay=\d+-\d+;cfg=[A-Za-z0-9_-]+$' -and $app.notes -notmatch 'version=latest' -and $app.displayVersion -ne 'latest') $app.notes
                $cfg = ConvertFrom-ChocoAppNotes $app.notes
                Test-Smoke 'schedule reached the notes' ($cfg.Schedule.WindowFrom -eq '12:00' -and $cfg.Schedule.OnlyOnMains -and -not $cfg.Schedule.TriggerStart -and $cfg.Schedule.WindowDays -eq '12345') ($cfg.Schedule | ConvertTo-Json -Compress)
                $install = Get-Content (Join-Path $script:WorkRoot "package\$($s.Package)\source\install.ps1") -Raw
                Test-Smoke 'install script has the update routine' ($install -match "\`$Mode = 'Custom'" -and $install -match '\$GraceHours = 72')
                Test-GeneratedScripts (Join-Path $script:WorkRoot "package\$($s.Package)") 'Chocolatey'
                $s.Detection = $app.detection
                Show-Page 'Tenant'
                $s.Waited = 0; $s.Phase = 2
                return $false
            }
            2 {
                if (-not (Test-Idle)) { return $false }
                Update-TenantRows -Force
                $row = @($script:TenantRowList | Where-Object { $_.Data.Package -eq $s.Package })[0]
                $ui.LstTenant.SelectedItem = $row
                Test-Smoke 'tenant lists version and update mode' ($row['Version'] -ne 'Always newest' -and $row['Updates'] -eq 'Ask user, 3 days') "$($row['Version']) / $($row['Updates'])"
                Test-Smoke 'panel shows the three explained choices, Ask the user selected' ($ui.RbTenantCustom.IsChecked -and $ui.TxtTenantGrace.Text -eq '3' -and $ui.CmbTenantGraceUnit.SelectedIndex -eq 1 -and $ui.PanelTenantGrace.Visibility -eq 'Visible')
                Test-Smoke 'panel pins the version' ($ui.CmbTenantVersion.SelectedIndex -ge 1 -and $ui.CmbTenantVersion.SelectedItem -eq $row.Data.Version) "$($ui.CmbTenantVersion.SelectedItem)"
                Test-Smoke 'panel summarises the schedule of the app' ($ui.TxtTenantWhen.Text -like '*') $ui.TxtTenantWhen.Text
                # Schedule dialog from the panel: change and apply (in place, the app is Available but the schedule path uses Update-IntuneChocoApp)
                $ui.RbTenantStartup.IsChecked = $true
                & $script:ClickActions[$ui.BtnTenantSchedule]
                Test-Smoke 'schedule dialog opens for the app with its values' ($ui.DlgSchedule.Visibility -eq 'Visible' -and $ui.SegSchedule.Visibility -eq 'Visible' -and $ui.SchFrom.Text -eq '12:00' -and [bool]$ui.SchMains.IsChecked -and $ui.TxtScheduleTitle.Text -like '*PuTTY*') $ui.TxtScheduleTitle.Text
                $ui.SchIdle.IsChecked = $true; $ui.SchIdleMin.SelectedIndex = 3
                $ui.SchRetry.SelectedIndex = 2; $ui.SchRetryCount.Text = '2'
                Update-ScheduleSummary
                Test-Smoke 'summary mentions the idle condition' ($ui.TxtScheduleSummary.Text -like '*15 min idle*') $ui.TxtScheduleSummary.Text
                Test-Smoke 'apply button says Apply in Intune' ($ui.BtnScheduleApply.Content -eq 'Apply in Intune') $ui.BtnScheduleApply.Content
                $ui.CmbTenantVersion.SelectedIndex = 0
                $s.Uploads = (Get-StoreApp $s.Package).uploads
                & $script:ClickActions[$ui.BtnScheduleApply]
                $s.Phase = 3
                return $false
            }
            3 {
                if (-not (Test-Idle)) { return $false }
                $app = Get-StoreApp $s.Package
                Test-Smoke 'schedule applied in place through Update-IntuneChocoApp' ($app.notes -match 'version=latest;update=Startup' -and $app.uploads -eq ($s.Uploads + 1) -and $app.detection -ne $s.Detection) "$($app.notes) / $($app.uploads)"
                $cfg = ConvertFrom-ChocoAppNotes $app.notes
                Test-Smoke 'new schedule reached the app' ($cfg.Schedule.IdleMinutes -eq 15 -and $cfg.Schedule.RetryMode -eq 'Every' -and $cfg.Schedule.RetryCount -eq 2 -and $cfg.Schedule.WindowFrom -eq '12:00') ($cfg.Schedule | ConvertTo-Json -Compress)
                $install = Get-Content (Join-Path $script:WorkRoot "package\$($s.Package)\source\install.ps1") -Raw
                Test-Smoke 'new install script has the new routine' ($install -match "\`$Mode = 'Startup'")
                # Default for new apps, from the same dialog
                $row = @($script:TenantRowList | Where-Object { $_.Data.Package -eq $s.Package })[0]
                $ui.LstTenant.SelectedItem = $row
                & $script:ClickActions[$ui.BtnTenantSchedule]
                $ui.RbSchDefault.IsChecked = $true
                Test-Smoke 'switching to the default shows Save as default' ($ui.BtnScheduleApply.Content -eq 'Save as default') $ui.BtnScheduleApply.Content
                $ui.SchMains.IsChecked = $false; $ui.SchPresentation.IsChecked = $true
                & $script:ClickActions[$ui.BtnScheduleApply]
                $saved = Get-Content $script:SettingsPath -Raw | ConvertFrom-Json
                Test-Smoke 'default schedule saved in the settings' ($saved.UpdateSchedule -match 'NoPresentation' -and (Get-ChocoScheduleDefaults).NoPresentation -and -not (Get-ChocoScheduleDefaults).OnlyOnMains) $saved.UpdateSchedule
                Show-Page 'Settings'
                Test-Smoke 'settings summarise the default schedule' ($ui.TxtDefaultSchedule.Text -like '*presentations*') $ui.TxtDefaultSchedule.Text
                # Release through Publish-IntuneChocoRelease: an Available app is superseded by a new app
                Show-Page 'Tenant'
                $zip = @($script:TenantRowList | Where-Object { $_.Data.Package -eq '7zip.install' })[0]
                $ui.LstTenant.SelectedItem = $zip
                $ui.RbTenantCustom.IsChecked = $true; $ui.TxtTenantGrace.Text = '12'; $ui.CmbTenantGraceUnit.SelectedIndex = 0
                $s.Before = @(Get-StoreApps).Count
                & $script:ClickActions[$ui.BtnTenantApply]
                $s.Phase = 4
                return $false
            }
            4 {
                if (-not (Test-Idle)) { return $false }
                $apps = Get-StoreApps
                $zips = @($apps | Where-Object { $_.notes -like '*package=7zip.install;*' })
                $new = $zips | Where-Object { $_.notes -match 'update=Custom;grace=12' }
                $old = $zips | Where-Object { $_.notes -notmatch 'update=Custom;grace=12' }
                Test-Smoke 'Available app is released as a new app that supersedes the old one' ($apps.Count -eq $s.Before + 1 -and $new -and @($new.supersedence).targetId -contains $old.id) "$($apps.Count) / $($s.Before)"
                Test-Smoke 'tenant lists the app once per version' (@($script:TenantRowList | Where-Object { $_.Data.Package -eq '7zip.install' }).Count -eq 2)
                $true
            }
        } } }
    @{ Name = 'status of one app'; Phase = 0; Do = {
        param($s)
        if ($s.Phase -eq 0) {
            $s.Phase = 1
            $zip = @($script:TenantRowList | Where-Object { $_.Data.Package -eq '7zip.install' -and $_.Data.UpdateMode -eq 'Custom' })[0]
            Test-Smoke 'row links to the status page' ($zip -and $zip['Ok'])
            Show-AppStatus $zip.Data
            return $false
        }
        if (-not (Test-Idle)) { return $false }
        Test-Smoke 'status page shows the counters' ($ui.TxtStatOk.Text -eq '2' -and $ui.TxtStatWait.Text -eq '1' -and $ui.TxtStatFail.Text -eq '1' -and $ui.TxtStatStale.Text -eq '1') "$($ui.TxtStatOk.Text)/$($ui.TxtStatWait.Text)/$($ui.TxtStatFail.Text)/$($ui.TxtStatStale.Text)"
        Test-Smoke 'device table lists the devices, failed first' ($script:DeviceRowList.Count -eq 4 -and $script:DeviceRowList[0]['Title'] -eq 'PC-0142' -and $script:DeviceRowList[0]['Status'] -eq 'Failed') (($script:DeviceRowList | ForEach-Object { $_['Title'] + ':' + $_['Status'] }) -join ', ')
        Test-Smoke 'cause comes from the device report' ($script:DeviceRowList[0]['Cause'] -like '*rate limit*') $script:DeviceRowList[0]['Cause']
        Test-Smoke 'device log shows the reported lines and the retry hint' ($ui.BoxDeviceLog.Visibility -eq 'Visible' -and $ui.TxtDeviceLog.Text -like '*rate limit*' -and $ui.TxtRetryHint.Text -like '*retries by itself*') $ui.TxtDeviceLog.Text
        $info = Get-InsightDiagnosticsInfo -ManagedDeviceId $script:DeviceRowList[0].Data.DeviceId -Package '7zip.install'
        Test-Smoke 'diagnostics point to the Intune admin center device page' ($info.Url -like '*intune.microsoft.com*md-1*' -and $info.Hint -like '*Collect diagnostics*') $info.Url
        Test-Smoke 'status script present: no banner' ($ui.BoxStatusScript.Visibility -eq 'Collapsed')
        Save-SmokeShot '11-status'
        # Without the status script the page degrades to the install status; without the license it says so
        $script:StatusScript = @{ State = 'Missing' }
        Update-StatusBanner
        Test-Smoke 'missing status script: banner offers the setup' ($ui.BoxStatusScript.Visibility -eq 'Visible' -and $ui.BtnStatusScript.Visibility -eq 'Visible')
        Set-Content (Join-Path $env:LOCALAPPDATA 'fake-nolicense.txt') 'x'
        $script:StatusScript = $null
        Start-StatusCheck
        return $true
        return $false } }
    @{ Name = 'status without Remediations license'; Do = {
        if (-not (Test-Idle)) { return $false }
        Test-Smoke 'no license: marked not available, degrade message' ($script:StatusScript.State -eq 'NotAvailable' -and $ui.BoxStatusScript.Visibility -eq 'Visible' -and $ui.BtnStatusScript.Visibility -eq 'Collapsed' -and $ui.TxtStatusScript.Text -like '*Remediations*') $ui.TxtStatusScript.Text
        $item = Get-ReadinessItems | Where-Object Key -eq 'status'
        Test-Smoke 'start page: optional item says it is not available' ($item.Text -like 'Not available*' -and -not $item.Fix) $item.Text
        Save-SmokeShot '12-status-degraded'
        Remove-Item (Join-Path $env:LOCALAPPDATA 'fake-nolicense.txt')
        $script:StatusScript = $null; Start-StatusCheck
        $true } }
    @{ Name = 'import dialog'; Phase = 0; Do = {
        param($s)
        switch ($s.Phase) {
            0 {
                if (-not (Test-Idle)) { return $false }
                Show-Page 'Tenant'
                $script:ImportApps = $null
                & $script:ClickActions[$ui.BtnImport]
                Test-Smoke 'import dialog opens with three sources' ($ui.DlgImport.Visibility -eq 'Visible' -and $ui.RbImpThis.IsChecked -and $ui.RbImpOther -and $ui.RbImpFile)
                $s.Phase = 1; return $false
            }
            1 {
                if (-not (Test-Idle)) { return $false }
                Update-ImportRows
                $rows = @($script:ImportRowList)
                $by = @{}; foreach ($r in $rows) { $by[$r['Title']] = $r }
                Test-Smoke 'table lists classified apps, infrastructure hidden' ($rows.Count -ge 4 -and -not ($rows | Where-Object { $_['Title'] -eq 'Chocolatey' })) (($rows | ForEach-Object { $_['Title'] }) -join ', ')
                Test-Smoke 'winget Win32 app: take over, selectable' ($by['Zoom Workplace']['Kind'] -eq 'Win32 with winget' -and $by['Zoom Workplace']['Action'] -eq 'Take over' -and $by['Zoom Workplace']['CanPick'] -eq 'True' -and $by['Zoom Workplace']['Found'] -like '*Zoom.Zoom*') ($by['Zoom Workplace'] | ConvertTo-Json -Compress)
                Test-Smoke 'Chocolatey app shows its pinned version' ($by['Greenshot']['Settings'] -like '*1.3.290*' -and $by['Greenshot']['Action'] -eq 'Take over')
                Test-Smoke 'own installer cannot be managed, dimmed and not selectable' ($by['Own VPN']['Action'] -eq 'Cannot be managed' -and $by['Own VPN']['CanPick'] -eq 'False' -and $by['Own VPN']['Opacity'] -lt 1)
                Test-Smoke 'already managed app is listed as managed' ($by['Sample managed']['Action'] -eq 'Already managed')
                Test-Smoke 'summary counts the selected apps' ($ui.TxtImportSummary.Text -like '2 of * apps selected*' -and $ui.BtnImportGo.Content -eq 'Take over 2 apps') "$($ui.TxtImportSummary.Text) / $($ui.BtnImportGo.Content)"
                Save-SmokeShot '13-import'
                $by['Greenshot']['Checked'] = 'False'; Update-ImportSummary
                Test-Smoke 'unchecking updates the button' ($ui.BtnImportGo.Content -eq 'Take over 1 app') $ui.BtnImportGo.Content
                & $script:ClickActions[$ui.BtnImportGo]
                $s.Phase = 2; return $false
            }
            2 {
                if (-not (Test-Idle)) { return $false }
                $patches = Get-Content (Join-Path $env:LOCALAPPDATA 'fake-patches.log') -ErrorAction SilentlyContinue
                Test-Smoke 'take over writes the notes to the selected app only' (@($patches).Count -eq 1 -and $patches -like '*mobileApps/i1*') ($patches -join ',')
                Test-Smoke 'import closes the dialog and shows the job' ($ui.DialogLayer.Visibility -eq 'Collapsed' -and $script:CurrentPage -eq 'Activity')
                # Export file round trip: export the managed apps, read them again as candidates
                $file = Join-Path $script:SmokeOut 'export.json'
                $script:ImportApps = @(Get-InsightTenantApps -Context (New-InsightGraphContext -Invoke ([scriptblock]::Create($script:InsightFake))) -DefaultUpdateMode 'Startup' -DefaultGraceHours 48)
                Export-ManagedApps $file
                $doc = Get-Content $file -Raw | ConvertFrom-Json
                Test-Smoke 'export writes the managed apps without ids' ($doc.format -eq 'IntuneChocoDeployment.Export' -and @($doc.apps).Count -eq 1 -and (Get-Content $file -Raw) -notmatch 'i4') (Get-Content $file -Raw)
                Show-Page 'Tenant'; Show-ImportDialog
                $ui.RbImpFile.IsChecked = $true
                Test-Smoke 'export file source shows the file chooser' ($ui.PanelImpFile.Visibility -eq 'Visible')
                @{ format = 'IntuneChocoDeployment.Export'; version = 1; exported = '2026-01-01'; apps = @(@{ displayName = 'Scratch'; source = 'Chocolatey'; package = 'scratch'; version = ''; updateMode = 'Startup'; graceHours = 48; packageSource = '' }) } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $script:SmokeOut 'export2.json')
                Read-ImportFile (Join-Path $script:SmokeOut 'export2.json')
                Test-Smoke 'file rows are offered as Create here' ($script:ImportRowList.Count -eq 1 -and $script:ImportRowList[0]['Action'] -eq 'Create here' -and $script:ImportRowList[0]['Kind'] -eq 'Export file') ($script:ImportRowList[0] | ConvertTo-Json -Compress)
                Save-SmokeShot '14-import-file'
                $ui.RbImpOther.IsChecked = $true
                Test-Smoke 'another tenant source asks for tenant and client ID' ($ui.PanelImpOther.Visibility -eq 'Visible' -and $ui.TxtImportEmpty.Text -like '*client ID*')
                $ui.RbImpFile.IsChecked = $true
                Read-ImportFile (Join-Path $script:SmokeOut 'export2.json')
                $script:ImportExisting = @()
                & $script:ClickActions[$ui.BtnImportGo]
                $s.Phase = 3; return $false
            }
            3 {
                if (-not (Test-Idle)) { return $false }
                Test-Smoke 'app from the export file created in this tenant' (@(Get-StoreApps | Where-Object { $_.notes -like '*package=scratch;*' }).Count -eq 1) (@(Get-StoreApps | ForEach-Object { $_.displayName }) -join ',')
                $true
            }
        } } }
    @{ Name = 'activity: failure, retry, clear'; Phase = 0; Do = {
        param($s)
        if ($s.Phase -eq 0) {
            $s.Phase = 1
            [void](Start-UiTask -Kind 'deploy' -Title 'Deploying Broken (test)' -Display 'Broken app' -Package 'broken' -Work 'throw "Upload failed: the Intune session expired. Sign in again and retry."')
            return $false
        }
        if ($s.Phase -eq 1) {
            if (-not (Test-Idle)) { return $false }
            $row = $script:JobRows[0]
            Test-Smoke 'failed job is red with its reason and a Retry button' ($row['Status'] -eq 'Failed' -and $row['Sub'] -like 'Upload failed*' -and $row['RetryVis'] -eq 'Visible') ($row['Status'] + '|' + $row['Sub'])
            Test-Smoke 'failure raises a toast' (@($script:Toasts | Where-Object { $_.Kind -eq 'bad' }).Count -ge 1)
            $row.Data.LogOpen = $true; Update-JobRow $row.Data
            Test-Smoke 'log expands with the message' ($row['LogVis'] -eq 'Visible' -and $row['Log'] -like '*Upload failed*')
            Show-Page 'Activity'
            Save-SmokeShot '15-activity-failed'
            $count = $script:JobRows.Count
            Restart-Job $row.Data
            Test-Smoke 'retry starts the job again' ($script:JobRows.Count -eq $count -and $script:JobRows[0]['Status'] -in 'Waiting', 'Running', 'Failed')
            $s.Phase = 2; return $false
        }
        if (-not (Test-Idle)) { return $false }
        & $script:ClickActions[$ui.BtnLogClear]
        Test-Smoke 'Clear finished removes the done jobs' ($script:JobRows.Count -eq 0 -and $ui.TxtJobsEmpty.Visibility -eq 'Visible') $script:JobRows.Count
        Test-Smoke 'log files are written per day' (Test-Path (Join-Path $script:LogFolder ('{0:yyyy-MM-dd}.log' -f (Get-Date))))
        $true } }
    @{ Name = 'sandbox test'; Phase = 0; Do = {
        param($s)
        $lab = Join-Path $env:LOCALAPPDATA 'fake-sandbox'
        switch ($s.Phase) {
            0 {
                Show-Page 'Settings'
                Test-Smoke 'settings show the update defaults' ($ui.CmbDefaultUpdate.SelectedIndex -eq 1 -and $ui.CmbDefaultVersion.SelectedIndex -eq 0)
                $ui.TxtSandboxStudioPath.Text = Join-Path (Split-Path $env:INTUNECHOCO_SMOKE) 'Fakes\MsixSandboxStudio'
                Save-Settings
                Test-Smoke 'sandbox studio found' ((Find-SandboxStudio) -like '*Fakes*MsixSandboxStudio.psd1') (Find-SandboxStudio)
                Test-Smoke 'settings show where the studio is' ($ui.TxtSandboxStudioState.Text -like 'Found:*Fakes*') $ui.TxtSandboxStudioState.Text
                Start-PackageTest -Package 'putty.install' -Source 'Chocolatey' -Title 'PuTTY' -Version 'latest' -Policy @{ UpdateMode = 'Custom'; GraceHours = 24 }
                try { Start-PackageTest -Package 'putty.install' -Source 'Chocolatey' -Version 'latest' -Policy @{ UpdateMode = 'Off'; GraceHours = 24 }; Test-Smoke 'only one sandbox test at a time' $false }
                catch { Test-Smoke 'only one sandbox test at a time' ($_.Exception.Message -like '*already running*') $_.Exception.Message }
                $s.Phase = 1
                return $false
            }
            1 {
                if (-not (Test-Idle 'test')) { return $false }
                Test-Smoke 'Chocolatey test ran in the lab' (Test-Path (Join-Path $lab 'Choco-putty.install\started.txt'))
                Test-Smoke 'result in a toast and the log' ((Get-SmokeLog) -match 'sandbox test passed' -and @($script:Toasts | Where-Object { $_.Text -like '*passed*' }).Count -ge 1)
                # From the details panel of the apps list (winget source)
                Show-Page 'Apps'
                $vlc = $script:SourceRows | Where-Object { $_.WingetId -eq 'VideoLAN.VLC' } | Select-Object -First 1
                $script:SourceChoice[(Get-AppKey $vlc)] = 'Winget'
                Show-AppDetails $vlc
                & $script:ClickActions[$ui.BtnDetailTest]
                $s.Phase = 2
                return $false
            }
            2 {
                if (-not (Test-Idle 'test')) { return $false }
                $source = Join-Path $lab 'Winget-VideoLAN.VLC\source'
                Test-Smoke 'winget test from the details panel ran in the lab' (Test-Path (Join-Path $lab 'Winget-VideoLAN.VLC\started.txt'))
                Test-Smoke 'winget test sets up winget first' ((Get-Content (Join-Path $source 'Install.ps1') -Raw) -match 'Repair-WinGetPackageManager')
                foreach ($file in Get-ChildItem $source -Filter '*.ps1') {
                    $errors = $null
                    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
                    Test-Smoke "lab script $($file.Name) is valid" ($errors.Count -eq 0) (@($errors | ForEach-Object { $_.Message }) -join '; ')
                }
                $ui.TxtSandboxStudioPath.Text = ''
                Save-Settings
                $true
            }
        } } }
    @{ Name = 'settings'; Do = {
        Show-Page 'Settings'
        Test-Smoke 'settings show the tenant and the preferred source' ($ui.TxtTenantId.Text -eq 'contoso.onmicrosoft.com' -and $ui.CmbPreferredSource.SelectedItem -eq 'Chocolatey') "$($ui.TxtTenantId.Text) / $($ui.CmbPreferredSource.SelectedItem)"
        Test-Smoke 'settings offer grant new permissions and the default schedule' ($ui.BtnSettingsGrant.Content -like '*grant new permissions*' -and $ui.BtnDefaultSchedule)
        Save-SmokeShot '16-settings'
        $ui.TxtDelayMin.Text = '30'; $ui.TxtDelayMax.Text = '10'
        try { Save-Settings; Test-Smoke 'invalid delay range rejected' $false } catch { Test-Smoke 'invalid delay range rejected' ($_.Exception.Message -like '*delay*') $_.Exception.Message }
        $ui.TxtDelayMin.Text = '10'; $ui.TxtDelayMax.Text = '90'
        $ui.TxtPackageSource.Text = 'https://proget.example.test/nuget/choco/'
        $ui.CmbPreferredSource.SelectedIndex = 0
        Save-Settings
        $saved = Get-Content $script:SettingsPath -Raw | ConvertFrom-Json
        Test-Smoke 'settings saved incl. preferred source and schedule' ($saved.UpdateDelayMaxMinutes -eq 90 -and $saved.PackageSource -like 'https://proget*' -and $saved.Source -eq 'Winget' -and $saved.UpdateSchedule -match 'NoPresentation') ($saved | ConvertTo-Json -Compress)
        Test-Smoke 'preferred source reaches the bar next to Review and deploy' ($ui.RbPreferWinget.IsChecked -and $script:Preferred -eq 'Winget')
        Test-Smoke 'settings keep the app registration per tenant' ($saved.TenantClients -eq 'contoso.onmicrosoft.com=11111111-2222-3333-4444-555555555555') $saved.TenantClients
        $ui.CmbPreferredSource.SelectedIndex = 1; Save-Settings
        $true } }
    @{ Name = 'account of another tenant (Keevault choice)'; Do = {
        $same = Resolve-AccountTenant 'admin@contoso.onmicrosoft.com'
        Test-Smoke 'account of the tenant signs in there' ($same.TenantID -eq 'contoso.onmicrosoft.com' -and $same.ClientID -eq '11111111-2222-3333-4444-555555555555')
        try { [void](Resolve-AccountTenant 'adm@fabrikam.onmicrosoft.com'); Test-Smoke 'unknown tenant stops with a reason' $false }
        catch { Test-Smoke 'unknown tenant stops with a reason' ($_.Exception.Message -like '*fabrikam.onmicrosoft.com*no app registration*Create*') $_.Exception.Message }
        $appreg = Get-ReadinessItems | Where-Object Key -eq 'appreg'
        Test-Smoke 'switched to the new tenant, Create offered' ($script:Settings.TenantID -eq 'fabrikam.onmicrosoft.com' -and -not $script:Settings.ClientID -and $appreg.Fix -eq 'Create') "$($script:Settings.TenantID) / $($appreg.Fix)"
        $back = Resolve-AccountTenant 'admin@contoso.onmicrosoft.com'
        Test-Smoke 'known tenant uses its own app registration' ($back.TenantID -eq 'contoso.onmicrosoft.com' -and $back.ClientID -eq '11111111-2222-3333-4444-555555555555') "$($back.TenantID) / $($back.ClientID)"
        Switch-Tenant $back.TenantID $back.ClientID
        Test-Smoke 'tenant switched back' ($script:Settings.TenantID -eq 'contoso.onmicrosoft.com' -and $script:Settings.ClientID -eq '11111111-2222-3333-4444-555555555555')
        $true } }
    @{ Name = 'sign out'; Do = {
        Test-Smoke 'account menu offers sign out and the other tenants' ($true)
        Disconnect-Intune
        Test-Smoke 'signed out: split button back, pill gone' ((-not (Test-SignedIn)) -and $ui.PanelSignedOut.Visibility -eq 'Visible' -and $ui.BtnAccount.Visibility -eq 'Collapsed' -and $ui.BtnSignIn.IsEnabled)
        Test-Smoke 'Review and deploy disabled when signed out' ($(Show-Page 'Apps'; Set-AppSelected $script:SourceRows[0] $true; -not $ui.BtnReview.IsEnabled))
        Clear-Selection
        Test-Smoke 'tenant list cleared on sign-out' ($script:TenantRowList.Count -eq 0 -and $ui.TxtTenantEmpty.Text -like 'Sign in*')
        Test-Smoke 'In tenant marks cleared on sign-out' (-not @($script:CardCollection | Where-Object { $_['Badge'] -eq 'In tenant' }).Count)
        $logFile = Join-Path $script:LogFolder ('{0:yyyy-MM-dd}.log' -f (Get-Date))
        Test-Smoke 'activity is written to the log file' ((Test-Path $logFile) -and (Get-Content $logFile -Raw) -match 'created in Intune')
        Show-Page 'Start'
        Save-SmokeShot '17-start-signed-out'
        $true } }
)

$script:SmokeTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:SmokeTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:SmokeTimer.Add_Tick({
    try {
        if ($script:SmokeSteps.Count -eq 0) {
            $script:SmokeTimer.Stop()
            $script:SmokeResults | Set-Content (Join-Path $script:SmokeOut 'results.txt')
            $window.Close()
            return
        }
        $step = $script:SmokeSteps[0]
        try { $done = & $step.Do $step }
        catch { Test-Smoke "step '$($step.Name)'" $false "$($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)"; $done = $true }
        if ($done) { $script:SmokeSteps.RemoveAt(0) }
    }
    catch {
        [void]$script:SmokeResults.Add("FAIL driver: $($_.Exception.Message)")
        $script:SmokeResults | Set-Content (Join-Path $script:SmokeOut 'results.txt')
        $window.Close()
    }
})
$window.Add_ContentRendered({ $script:SmokeTimer.Start() })
