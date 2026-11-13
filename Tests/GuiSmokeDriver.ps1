# Dot-sourced by Start-IntuneChocoTool.ps1 when INTUNECHOCO_SMOKE is set (see Tests\Invoke-GuiSmoke.ps1).
# Puts the window off-screen and walks through the steps below on the UI thread; each step returns $true when it is
# done (or $false to be asked again on the next tick), so background tasks can finish in between.

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
function Get-SmokeLog { @($ui.LogList.Items | ForEach-Object { $_.Line }) -join "`n" }
# Without a kind: no task except the icon rendering, which runs on its own pool next to everything else
function Test-Idle([string]$Kind) { -not @($script:Tasks | Where-Object { if ($Kind) { $_.Job.Kind -eq $Kind } else { $_.Job.Kind -ne 'icons' } }).Count }

$script:SmokeSteps = [System.Collections.ArrayList]@(
    @{ Name = 'start page'; Do = {
        Test-Smoke 'fake module counts as installed' $script:ModuleState.Ok $script:ModuleState.Version
        Test-Smoke 'readiness shows at least 4 items' ($ui.ReadinessPanel.Children.Count -ge 4) $ui.ReadinessPanel.Children.Count
        Test-Smoke 'signed out at start' ((-not (Test-SignedIn)) -and $ui.BtnSignIn.IsEnabled -and -not $ui.BtnSignOut.IsEnabled)
        Test-Smoke 'help flyout opens' ($(Show-Help; $ui.HelpPanel.Visibility -eq 'Visible' -and $ui.HelpBody.Children.Count -ge 4))
        Save-SmokeShot '01-start-help'
        $ui.HelpPanel.Visibility = 'Collapsed'
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
        Test-Smoke 'cancelled sign-in ends and is logged' ((-not (Test-SignedIn)) -and (Get-SmokeLog) -match 'Sign-in cancelled')
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
            Test-Smoke 'set up everything offered' ($ui.BtnSetupAll.Visibility -eq 'Visible' -and $ui.TxtReadinessSummary.Text -like '*not ready*') $ui.TxtReadinessSummary.Text
            Save-SmokeShot '02-readiness'
            # Instead of a browser: request the sign-in URL; the stand-in authority redirects to the loopback port
            $script:SignInTest.UrlHandler = 'param($Url) $global:SmokeClient = New-Object System.Net.WebClient; [void]$global:SmokeClient.DownloadStringTaskAsync([uri]$Url)'
            $script:SignInTest.GraphUrl = $env:INTUNECHOCO_SMOKE_AUTHORITY
            & $script:ClickActions[$ui.BtnSetupAll]
            return $false
        }
        $s.Waited++
        if (($script:SetupRunning -or -not (Test-Idle)) -and $s.Waited -lt 1200) { return $false }
        $log = Get-SmokeLog
        Test-Smoke 'set up finished' ((-not $script:SetupRunning) -and $log -match 'Everything is set up') (($log -split "`n" | Select-Object -Last 3) -join ' | ')
        Test-Smoke 'app registration created with admin consent' ($log -match "App registration 'Intune Chocolatey Deployment' created" -and $log -match 'Admin consent granted: DeviceManagementApps\.ReadWrite\.All')
        Test-Smoke 'tenant and client id saved' ((Get-IntuneChocoSettings).ClientID -eq '11111111-2222-3333-4444-555555555555' -and (Get-IntuneChocoSettings).TenantID -eq 'contoso.onmicrosoft.com') "$((Get-IntuneChocoSettings).TenantID) / $((Get-IntuneChocoSettings).ClientID)"
        Test-Smoke 'Chocolatey deployed by the set up' (@($script:TenantApps | Where-Object IsChocolatey).Count -eq 1)
        Test-Smoke 'all items green, no buttons left' (@(Get-ReadinessItems | Where-Object { $_.State -ne 'ok' }).Count -eq 0 -and $ui.BtnSetupAll.Visibility -eq 'Collapsed') $ui.TxtReadinessSummary.Text
        $true } }
    @{ Name = 'sign in'; Do = {
        Test-Smoke 'signed in through the browser flow (PKCE, loopback)' (Test-SignedIn)
        Test-Smoke 'header shows the account' ($ui.TxtConnectionStatus.Text -like '*admin@contoso.onmicrosoft.com*') $ui.TxtConnectionStatus.Text
        Test-Smoke 'sign in disabled, sign out enabled' ((-not $ui.BtnSignIn.IsEnabled) -and $ui.BtnSignOut.IsEnabled)
        Test-Smoke 'token carries refresh token and client id' ($Global:AccessToken.RefreshToken -eq 'refresh-Test Admin' -and $Global:AccessToken.ClientID -eq '11111111-2222-3333-4444-555555555555')
        # An expiring token is renewed silently with the refresh token
        $Global:AccessToken.ExpiresOn = (Get-Date).ToUniversalTime().AddMinutes(2)
        Update-UiToken
        $identity = Get-IntuneChocoIdentity
        Test-Smoke 'expiring token renewed silently' ($identity.Name -eq 'Test Admin renewed' -and ([datetime]$identity.ExpiresOn) -gt (Get-Date).ToUniversalTime().AddMinutes(30)) $identity.Name
        Test-Smoke 'renewed token handed to the tasks' ($script:Shared.Auth.AccessToken.RefreshToken -eq 'refresh-Test Admin renewed')
        # The module leaves with "break" when it distrusts the sign-in: that must surface as an error, not as silence.
        # Called directly (as the module's own check sees it under a German date format) nothing comes back ...
        $cultureBefore = [Threading.Thread]::CurrentThread.CurrentCulture.Name
        $direct = 'not reached'
        do { $direct = @(Get-IntuneWin32App).Count } while ($false)
        Test-Smoke 'fake module gives up silently when called directly (like the real one)' ($direct -eq 'not reached') $direct
        # ... through Invoke-IntuneModule the same call works, and a give-up becomes an error
        Test-Smoke 'module call works through Invoke-IntuneModule' (@(Invoke-IntuneModule { Get-IntuneWin32App }).Count -eq 1)   # Chocolatey, from the set up
        try { Invoke-IntuneModule { Write-Warning 'gave up' 3>$null; break }; Test-Smoke 'a module give-up becomes an error' $false }
        catch { Test-Smoke 'a module give-up becomes an error' ($_.Exception.Message -like '*gave up without a result*') $_.Exception.Message }
        Test-Smoke 'culture restored after the module call' ([Threading.Thread]::CurrentThread.CurrentCulture.Name -eq $cultureBefore) [Threading.Thread]::CurrentThread.CurrentCulture.Name
        $true } }
    @{ Name = 'catalog infos'; Started = $false; Waited = 0; Do = {
        param($s)
        if (-not $s.Started) { $s.Started = $true; Show-Page 'Catalog'; return $false }
        $s.Waited++
        if (-not (Test-Idle 'meta') -and $s.Waited -lt 1200) { return $false }
        Update-CatalogGrid
        $rows = @($ui.DgCatalog.ItemsSource)
        Test-Smoke 'catalog lists all apps' ($rows.Count -eq $script:Catalog.Count) "$($rows.Count) of $($script:Catalog.Count)"
        $loaded = @($rows | Where-Object Found).Count
        Test-Smoke 'package infos loaded from the feed' ($loaded -ge $rows.Count - 3) "$loaded of $($rows.Count)"
        $zip = $rows | Where-Object Key -eq '7zip.install' | Select-Object -First 1
        Test-Smoke '7-Zip has version and publisher' ($zip.Version -and $zip.Authors) "$($zip.Version) / $($zip.Authors)"
        Test-Smoke 'license note on AnyDesk' ([bool](@($rows | Where-Object { $_.Key -eq 'anydesk' -and $_.StatusText -eq 'License' }).Count))
        Save-SmokeShot '02-catalog'
        $true } }
    @{ Name = 'catalog filter and selection'; Do = {
        $ui.TxtCatalogFilter.Text = 'scratch'
        Test-Smoke 'filter narrows to Scratch' (@($ui.DgCatalog.ItemsSource).Count -eq 1) @($ui.DgCatalog.ItemsSource).Count
        $ui.DgCatalog.SelectedItem = @($ui.DgCatalog.ItemsSource)[0]
        $ui.TxtCatalogFilter.Text = '7-zip'
        [void]$ui.DgCatalog.SelectedItems.Add(@($ui.DgCatalog.ItemsSource)[0])
        Test-Smoke 'selection kept across filters' ($script:Selected.Count -eq 2 -and $script:Selected.Contains('scratch') -and $script:Selected.Contains('7zip.install')) (@($script:Selected.Keys) -join ',')
        Test-Smoke 'catalog shows the Intune name' (@($ui.DgCatalog.ItemsSource)[0].Title -eq '7-Zip') @($ui.DgCatalog.ItemsSource)[0].Title
        Test-Smoke 'details show the clicked app' ($ui.TxtDetailTitle.Text -like '*7-Zip*') $ui.TxtDetailTitle.Text
        Test-Smoke 'deploy button enabled' ($ui.BtnDeploy.IsEnabled -and $ui.BtnDeploy.Content -eq 'Deploy 2 apps') $ui.BtnDeploy.Content
        Save-SmokeShot '03-selection'
        $true } }
    @{ Name = 'custom icon'; Do = {
        # A generated BMP goes through the conversion to PNG
        Add-Type -AssemblyName System.Drawing
        $bmpFile = Join-Path $script:SmokeOut 'custom.bmp'
        $b = New-Object System.Drawing.Bitmap 64, 64
        $g = [System.Drawing.Graphics]::FromImage($b); $g.Clear([System.Drawing.Color]::SteelBlue); $g.Dispose()
        $b.Save($bmpFile, [System.Drawing.Imaging.ImageFormat]::Bmp); $b.Dispose()
        Clear-Selection
        $ui.TxtCatalogFilter.Text = 'scratch'
        [void]$ui.DgCatalog.SelectedItems.Add(@($ui.DgCatalog.ItemsSource)[0])
        Set-CustomIcon -Key 'scratch' -Path $bmpFile
        Test-Smoke 'custom icon stored as PNG' ([string]$script:CustomIcons['scratch'] -like 'iVBORw0KGgo*')
        Test-Smoke 'custom icon shown in details' ($ui.BtnCustomIconRemove.Visibility -eq 'Visible' -and $null -ne $ui.ImgDetail.Source)
        $ui.TxtCatalogFilter.Text = '7-zip'
        [void]$ui.DgCatalog.SelectedItems.Add(@($ui.DgCatalog.ItemsSource)[0])
        $ui.TxtCatalogFilter.Text = ''
        Test-Smoke 'two apps selected again' ($script:Selected.Count -eq 2) (@($script:Selected.Keys) -join ',')
        $true } }
    @{ Name = 'deploy'; Started = $false; Waited = 0; Do = {
        param($s)
        if (-not $s.Started) {
            $s.Started = $true
            $ui.RbAvailable.IsChecked = $true
            Start-Deploy
            Test-Smoke 'selection cleared after queueing' ($script:Selected.Count -eq 0)
            Test-Smoke 'busy indicator shown' ($ui.BusyPanel.Visibility -eq 'Visible') $ui.BusyText.Text
            Save-SmokeShot '04-deploying'
            return $false
        }
        $s.Waited++
        if (-not (Test-Idle) -and $s.Waited -lt 1200) { return $false }
        $apps = @(Get-Content (Join-Path $env:LOCALAPPDATA 'fake-intune.json') -Raw | ConvertFrom-Json | ForEach-Object { $_ })
        $names = @($apps | ForEach-Object { $_.displayName })
        Test-Smoke 'Chocolatey, 7-Zip and Scratch created with catalog names' ($apps.Count -eq 3 -and ($names -contains 'Chocolatey') -and ($names -contains '7-Zip') -and ($names -contains 'Scratch')) ($names -join ', ')
        $zip = $apps | Where-Object { $_.displayName -eq '7-Zip' }
        $scratch = $apps | Where-Object { $_.displayName -eq 'Scratch' }
        Test-Smoke '7-Zip icon converted from SVG' ($zip.hasIcon -and $zip.iconValid)
        Test-Smoke 'Scratch has the custom icon' ($scratch.hasIcon -and $scratch.iconValid)
        Test-Smoke 'apps assigned as available' (@($apps | Where-Object { $_.displayName -ne 'Chocolatey' -and $_.assignment -eq 'available' }).Count -eq 2)
        Test-Smoke 'notes carry the package id and the update settings' ($zip.notes -match '^PoweredByChocolatey;package=7zip\.install;version=latest;update=Startup;grace=48;source=[^;]*;delay=\d+-\d+$') $zip.notes
        $log = Get-SmokeLog
        Test-Smoke 'log shows both successes' (($log -match '\[7zip\.install\] created in Intune') -and ($log -match '\[scratch\] created in Intune'))
        Test-Smoke 'no errors in the log' (-not ($log -match 'failed')) (($log -split "`n" | Where-Object { $_ -match 'failed' }) -join ' | ')
        $true } }
    @{ Name = 'tenant'; Started = $false; Do = {
        param($s)
        if (-not $s.Started) { $s.Started = $true; Show-Page 'Tenant'; if (Test-Idle 'tenant') { Start-TenantRefresh }; return $false }
        if (-not (Test-Idle 'tenant')) { return $false }
        $rows = @($ui.DgTenant.ItemsSource)
        Test-Smoke 'tenant lists 3 apps, Chocolatey first' ($rows.Count -eq 3 -and $rows[0].IsChocolatey) (($rows | ForEach-Object { $_.DisplayName }) -join ', ')
        $ui.DgTenant.SelectedIndex = 1
        Test-Smoke 'open, copy and remove enabled for a selected app' ($ui.BtnTenantOpen.IsEnabled -and $ui.BtnTenantCopy.IsEnabled -and $ui.BtnTenantRemove.IsEnabled)
        Save-SmokeShot '05-tenant'
        $true } }
    @{ Name = 'catalog knows the tenant'; Do = {
        Show-Page 'Catalog'
        $rows = @($ui.DgCatalog.ItemsSource)
        $marked = @($rows | Where-Object { $_.StatusText -eq 'In tenant' } | ForEach-Object { $_.Key }) -join ','
        Test-Smoke 'deployed apps are marked in the catalog' ($marked -eq '7zip.install,scratch') $marked
        # List position and sorting survive a rebuild of the rows (infos and icons come in while the user scrolls)
        $ui.DgCatalog.Items.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription('Title', 'Descending')))
        $ui.DgCatalog.UpdateLayout()
        $scroll = Find-VisualChild $ui.DgCatalog ([System.Windows.Controls.ScrollViewer])
        $scroll.ScrollToVerticalOffset(30); $ui.DgCatalog.UpdateLayout()
        Update-CatalogGrid
        $ui.DgCatalog.UpdateLayout()
        $scroll = Find-VisualChild $ui.DgCatalog ([System.Windows.Controls.ScrollViewer])
        Test-Smoke 'scroll position kept on rebuild' ($scroll.VerticalOffset -eq 30) $scroll.VerticalOffset
        Test-Smoke 'sorting kept on rebuild' ($ui.DgCatalog.Items[0].Title -eq (@($rows | ForEach-Object { $_.Title } | Sort-Object -Descending)[0])) $ui.DgCatalog.Items[0].Title
        $ui.DgCatalog.Items.SortDescriptions.Clear()
        Update-CatalogGrid
        # An app that is already there is not queued again
        $ui.TxtCatalogFilter.Text = 'scratch'
        Test-Smoke 'filter hint hidden while typing' ($ui.HintCatalogFilter.Visibility -eq 'Collapsed')
        [void]$ui.DgCatalog.SelectedItems.Add(@($ui.DgCatalog.ItemsSource)[0])
        try { Start-Deploy; Test-Smoke 'app in the tenant is not deployed again' $false }
        catch { Test-Smoke 'app in the tenant is not deployed again' ($_.Exception.Message -like '*already in the tenant*' -and (Test-Idle 'deploy')) $_.Exception.Message }
        Clear-Selection
        $ui.TxtCatalogFilter.Text = ''
        $true } }
    @{ Name = 'remove from Intune'; Phase = 0; Do = {
        param($s)
        if ($s.Phase -eq 0) {
            $s.Phase = 1
            Show-Page 'Tenant'
            # Chocolatey stays while other apps depend on it
            $ui.DgTenant.SelectedItem = @($ui.DgTenant.ItemsSource | Where-Object IsChocolatey)[0]
            try { & $script:ClickActions[$ui.BtnTenantRemove]; Test-Smoke 'Chocolatey is not removed while apps depend on it' $false }
            catch { Test-Smoke 'Chocolatey is not removed while apps depend on it' ($_.Exception.Message -like '*dependency of*') $_.Exception.Message }
            $ui.DgTenant.SelectedItem = @($ui.DgTenant.ItemsSource | Where-Object { $_.Package -eq 'scratch' })[0]
            & $script:ClickActions[$ui.BtnTenantRemove]
            return $false
        }
        if (-not (Test-Idle 'remove') -or -not (Test-Idle 'tenant')) { return $false }
        $rows = @($ui.DgTenant.ItemsSource)
        Test-Smoke 'Scratch removed from the tenant' ($rows.Count -eq 2 -and -not @($rows | Where-Object { $_.Package -eq 'scratch' }).Count -and (Get-SmokeLog) -match '\[scratch\] removed from Intune') $rows.Count
        Test-Smoke 'catalog no longer marks Scratch' (-not $script:TenantPackages.ContainsKey('scratch') -and $script:TenantPackages.ContainsKey('7zip.install'))
        $true } }
    @{ Name = 'search'; Started = $false; Do = {
        param($s)
        if (-not $s.Started) { $s.Started = $true; Show-Page 'Search'; $ui.TxtSearch.Text = 'notepad'; Start-Search; return $false }
        if (-not (Test-Idle 'search')) { return $false }
        $rows = @($ui.DgSearch.ItemsSource)
        Test-Smoke 'search finds notepad packages' ($rows.Count -gt 0 -and @($rows | Where-Object { $_.Id -like 'notepad*' }).Count) $rows.Count
        if ($rows.Count) { $ui.DgSearch.SelectedItem = $rows[0] }
        Test-Smoke 'search result shows details' ($ui.DetailBody.Visibility -eq 'Visible')
        Save-SmokeShot '06-search'
        $true } }
    @{ Name = 'catalog icons'; Waited = 0; Do = {
        param($s)
        # SVG icons are rendered to PNG in the background, PNG icons are downloaded by WPF: wait for both
        if ($s.Waited -eq 0) { Show-Page 'Catalog'; $ui.CmbCategory.SelectedItem = 'Browsers' }
        $s.Waited++
        if ((-not (Test-Idle 'icons') -and $s.Waited -lt 1200) -or $s.Waited -lt 10) { return $false }
        if (-not $s.Rebuilt) { Update-CatalogGrid; $s.Rebuilt = $true; $s.Loaded = $s.Waited; return $false }
        if ($s.Waited -lt $s.Loaded + 8) { return $false }   # WPF loads the images asynchronously
        $rows = @($ui.DgCatalog.ItemsSource)
        Test-Smoke 'all browser rows have an icon (SVG rendered)' (@($rows | Where-Object IconUrl).Count -eq $rows.Count) "$(@($rows | Where-Object IconUrl).Count) of $($rows.Count)"
        $cached = @(Get-ChildItem $script:IconCacheDir -Filter *.png -ErrorAction SilentlyContinue).Count
        $svg = @($script:Shared.Meta.Values | ForEach-Object { [string]$_.IconUrl } | Where-Object { $_ -match '\.svg(\?|#|$)' } | Sort-Object -Unique).Count
        Test-Smoke 'every SVG icon cached as PNG' ($svg -gt 0 -and $cached -ge $svg) "$cached of $svg"
        Save-SmokeShot '09-catalog-icons'
        function Find-Visual($Parent, [type]$Type) {
            for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Parent); $i++) {
                $c = [System.Windows.Media.VisualTreeHelper]::GetChild($Parent, $i)
                if ($c -is $Type) { return $c }
                $r = Find-Visual $c $Type; if ($r) { return $r }
            }
        }
        # The icon column really shows an image in every row (a binding error leaves the cell empty silently)
        $shown = 0
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $row = $ui.DgCatalog.ItemContainerGenerator.ContainerFromIndex($i)
            $img = if ($row) { Find-Visual $row ([System.Windows.Controls.Image]) }
            if ($img -and $img.Source) { $shown++ }
        }
        Test-Smoke 'icon column shows an image in every browser row' ($shown -eq $rows.Count) "$shown of $($rows.Count)"
        $ui.CmbCategory.SelectedIndex = 0
        $true } }
    @{ Name = 'winget catalog'; Phase = 0; Waited = 0; Do = {
        param($s)
        if ($s.Phase -eq 0) {
            $s.Phase = 1
            Show-Page 'Catalog'
            Test-Smoke 'source switch shows Chocolatey as active' ($ui.SrcChocolatey.IsChecked -and -not $ui.SrcWinget.IsChecked)
            & $script:ClickActions[$ui.SrcChocolatey]
            Test-Smoke 'clicking the active source changes nothing' ($script:Source -eq 'Chocolatey')
            & $script:ClickActions[$ui.SrcWinget]
            Test-Smoke 'source switch moves to winget' ($script:Source -eq 'Winget' -and $ui.SrcWinget.IsChecked -and -not $ui.SrcChocolatey.IsChecked -and $ui.HintSearch.Text -like '*winget*')
            Test-Smoke 'winget catalog lists the apps with a winget id' (@($ui.DgCatalog.ItemsSource).Count -eq @($script:Catalog | Where-Object WingetId).Count) @($ui.DgCatalog.ItemsSource).Count
            Test-Smoke 'switching the source clears the selection' ($script:Selected.Count -eq 0)
            return $false
        }
        $s.Waited++
        if (-not (Test-Idle 'meta') -and $s.Waited -lt 1200) { return $false }
        if ($s.Waited -lt 4) { return $false }
        $rows = @($ui.DgCatalog.ItemsSource)
        $vlc = $rows | Where-Object { $_.Id -eq 'VideoLAN.VLC' }
        Test-Smoke "winget infos from the manifest: $($vlc.Authors), $($vlc.License)" ($vlc.Found -and $vlc.Version -eq '3.0.24' -and $vlc.Authors -and $vlc.License) ($vlc | Select-Object Id, Version, Authors, License | ConvertTo-Json -Compress)
        Test-Smoke 'winget row lends the Chocolatey icon' ([bool]$vlc.RawIconUrl) $vlc.RawIconUrl
        # Fixed package instead of the live repository (every catalog id may exist there by now)
        $unknown = New-PackageRow -Id 'Contoso.DoesNotExist' -Name 'Contoso' -Category 'Test' -Source 'Winget' `
            -Meta ([pscustomobject]@{ Found = $false; NotFound = $true; Name = 'Contoso.DoesNotExist'; Error = 'was not found' })
        Test-Smoke 'unknown winget id shows as not found' ($unknown.StatusText -eq 'Not found' -and $unknown.Status -eq 'Error') "$($unknown.StatusText)|$($unknown.Status)"
        Test-Smoke 'license note on winget AnyDesk' ((@($rows | Where-Object { $_.Id -eq 'AnyDesk.AnyDesk' })[0]).LicenseNote -like '*AnyDesk license*')
        $ui.DgCatalog.SelectedItem = $vlc
        Test-Smoke 'details point to winget-pkgs' ($ui.BtnDetailChoco.Content -eq 'winget-pkgs' -and $ui.TxtDetailMeta.Text -like '*license*') $ui.TxtDetailMeta.Text
        Save-SmokeShot '10-winget-catalog'
        $true } }
    @{ Name = 'winget deploy'; Phase = 0; Do = {
        param($s)
        if ($s.Phase -eq 0) {
            $s.Phase = 1
            Clear-Selection
            # VLC is new; 7-Zip already exists in the tenant as the Chocolatey app of the same name
            foreach ($id in 'VideoLAN.VLC', '7zip.7zip') { [void]$ui.DgCatalog.SelectedItems.Add(@($ui.DgCatalog.ItemsSource | Where-Object { $_.Id -eq $id })[0]) }
            Test-Smoke 'two winget apps selected' ($script:Selected.Count -eq 2 -and $script:Selected.Contains('winget:videolan.vlc')) (@($script:Selected.Keys) -join ',')
            Start-Deploy
            return $false
        }
        if (-not (Test-Idle)) { return $false }
        $apps = @(Get-Content (Join-Path $env:LOCALAPPDATA 'fake-intune.json') -Raw | ConvertFrom-Json | ForEach-Object { $_ })
        $vlc = $apps | Where-Object { $_.notes -like 'PoweredByWinget;package=VideoLAN.VLC;version=latest;update=Startup;grace=48;source=;delay=*' }
        Test-Smoke 'winget VLC created with the catalog name' ($vlc.displayName -eq 'VLC media player' -and $vlc.assignment -eq 'available') (($apps | ForEach-Object { "$($_.displayName)|$($_.notes)" }) -join '; ')
        Test-Smoke 'winget VLC has the borrowed icon and the publisher from the manifest' ($vlc.hasIcon -and $vlc.iconValid -and $vlc.publisher -and $vlc.publisher -ne '-') $vlc.publisher
        $vlcLog = (@((Get-SmokeLog) -split "`n" | Where-Object { $_ -match '\[VideoLAN\.VLC\]' })) -join "`n"
        Test-Smoke 'winget app has the winget runtime dependency, no Chocolatey dependency' (($vlcLog -match 'Adding dependency for the winget runtime') -and ($vlcLog -notmatch 'dependency for chocolatey')) $vlcLog
        Test-Smoke 'same app from the other source is not created twice' ((Get-SmokeLog) -match '\[7zip\.7zip\] .*already deployed' -and @($apps | Where-Object { $_.displayName -eq '7-Zip' }).Count -eq 1)
        $pkg = Get-ChildItem (Join-Path $script:WorkRoot 'package\winget-VideoLAN.VLC\source\install.ps1') -ErrorAction SilentlyContinue
        Test-Smoke 'winget install script written' ($pkg -and (Get-Content $pkg.FullName -Raw) -match "'VideoLAN.VLC'" -and (Get-Content $pkg.FullName -Raw) -match 'Intune-Winget-Updates')
        $true } }
    @{ Name = 'winget tenant and search'; Phase = 0; Do = {
        param($s)
        if ($s.Phase -eq 0) { $s.Phase = 1; if (Test-Idle 'tenant') { Start-TenantRefresh }; return $false }
        if ($s.Phase -eq 1) {
            if (-not (Test-Idle 'tenant')) { return $false }
            $row = @($ui.DgTenant.ItemsSource | Where-Object { $_.Package -eq 'VideoLAN.VLC' })[0]
            Test-Smoke 'tenant shows the winget app with its source' ($row -and $row.Source -eq 'Winget' -and $row.StatusText -eq 'winget') ($row | ConvertTo-Json -Compress)
            Test-Smoke 'winget catalog marks VLC as in tenant' ((@($ui.DgCatalog.ItemsSource | Where-Object { $_.Id -eq 'VideoLAN.VLC' })[0]).StatusText -eq 'In tenant')
            Test-Smoke 'Chocolatey catalog does not mark the winget VLC' (-not $script:TenantPackages.ContainsKey('vlc'))
            $s.Phase = 2
            Show-Page 'Search'
            $ui.TxtSearch.Text = 'notepad'
            Start-Search
            return $false
        }
        if (-not (Test-Idle 'search') -or -not (Test-Idle 'meta')) { return $false }
        $rows = @($ui.DgSearch.ItemsSource)
        Test-Smoke "winget search finds and ranks: $(($rows | ForEach-Object Id) -join ', ')" ($rows.Count -ge 2 -and $rows[0].Id -like 'Notepad*' -and $rows[0].Source -eq 'Winget') ''
        $npp = $rows | Where-Object { $_.Id -eq 'Notepad++.Notepad++' }
        Test-Smoke 'search result completed from the manifest' ($npp.Authors -like 'Notepad++*') $npp.Authors
        Save-SmokeShot '11-winget-search'
        & $script:ClickActions[$ui.SrcChocolatey]
        $saved = Get-Content $script:SettingsPath -Raw | ConvertFrom-Json
        Test-Smoke 'back to Chocolatey, source saved' ($script:Source -eq 'Chocolatey' -and $saved.Source -eq 'Chocolatey' -and @($ui.DgCatalog.ItemsSource).Count -eq $script:Catalog.Count)
        $true } }
    @{ Name = 'update settings per app'; Phase = 0; Do = {
        param($s)
        function Get-StoreApp([string]$Package) { @(Get-Content (Join-Path $env:LOCALAPPDATA 'fake-intune.json') -Raw | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_.notes -like "*package=$Package;*" })[0] }
        function Test-GeneratedScripts([string]$Folder, [string]$What) {
            # The scripts that run on the devices must at least be valid PowerShell, without leftover placeholders
            foreach ($file in Get-ChildItem $Folder -Filter '*.ps1' -Recurse) {
                $errors = $null
                [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
                $text = Get-Content $file.FullName -Raw
                Test-Smoke "$What script $($file.Name) is valid" ($errors.Count -eq 0 -and $text -notmatch '__[A-Z]+__') (@($errors | ForEach-Object { $_.Message }) -join '; ')
            }
            # Review findings: lock, protected folders, no marker without tasks, Custom checks at startup
            $install = Get-Content (Join-Path $Folder 'source\install.ps1') -Raw
            $update = Get-Content (Join-Path $Folder 'source\update.ps1') -Raw
            Test-Smoke "$What scripts share the device lock" ($install -match 'Global.IntuneChocoDeployment"' -and $install -match 'Enter-DeploymentLock' -and $update -match 'Enter-DeploymentLock')
            Test-Smoke "$What helper folder is protected by SID" ($install -match 'Protect-Folder' -and $install -match 'S-1-5-18' -and $install -match 'S-1-5-32-544' -and $install -match 'SetAccessRuleProtection\(\$true')
            Test-Smoke "$What install fails without its tasks" ($install -match 'could not be registered[^\n]*\n[\s\S]{0,200}exit 1' -and $install -notmatch 'Set-Content -Path \(Join-Path \$AppRoot "policy.txt"\)')
            Test-Smoke "$What startup task checks in Custom mode" ($install -match '\$StartupStep = if \(\$Mode -eq "Custom"\) \{ "Check" \}' -and $install -match '-Daily')
            if ($What -eq 'Chocolatey') {
                Test-Smoke 'Chocolatey uninstall removes dependencies' ($install -match 'uninstall \$Package -y --no-progress --remove-dependencies')
                Test-Smoke 'Chocolatey check asks for the one package' ($update -match 'search \$Package --exact --limit-output' -and $update -notmatch 'outdated')
                Test-Smoke 'Chocolatey updates itself once a day' ($update -match 'upgrade chocolatey' -and $update -match 'Test-ChocolateyUpdateDue')
            }
            else {
                $detection = Get-Content (Join-Path $Folder 'detection.ps1') -Raw
                Test-Smoke 'winget installs only machine scope' ($install -notmatch 'trying without scope' -and $update -notmatch 'upgrade @Common @VersionArguments \| Out-Null')
                Test-Smoke 'winget uninstall without source' ($install -match 'uninstall --id \$Id --exact --silent')
                Test-Smoke 'winget detection uses the exit code' ($detection -match 'list --id \$Id --exact --source winget' -and $detection -notmatch 'Escape')
            }
        }
        switch ($s.Phase) {
            0 {
                # Chocolatey app with its own settings at the deployment: pinned, user prompt, 3 days
                Show-Page 'Catalog'
                Clear-Selection
                $s.Package = 'putty.install'
                $row = @($ui.DgCatalog.ItemsSource | Where-Object { $_.Id -eq $s.Package })[0]
                Test-Smoke 'deploy panel starts with the settings defaults' ($ui.CmbDeployUpdate.SelectedIndex -eq 1 -and $ui.CmbDeployVersion.SelectedIndex -eq 0 -and $ui.PanelDeployGrace.Visibility -ne 'Visible')
                $ui.CmbDeployUpdate.SelectedIndex = 2
                Test-Smoke 'grace period appears for the user prompt' ($ui.PanelDeployGrace.Visibility -eq 'Visible' -and $ui.TxtDeployUpdateHelp.Text -like '*installed anyway*')
                $ui.TxtDeployGrace.Text = 'x'
                try { [void](Read-PolicyControls 'Deploy'); Test-Smoke 'invalid grace period rejected' $false } catch { Test-Smoke 'invalid grace period rejected' ($_.Exception.Message -like '*90 days*') $_.Exception.Message }
                $ui.TxtDeployGrace.Text = '3'; $ui.CmbDeployGraceUnit.SelectedIndex = 1; $ui.CmbDeployVersion.SelectedIndex = 1
                [void]$ui.DgCatalog.SelectedItems.Add($row)
                Test-Smoke 'test button for one selected app' $ui.BtnTestSelected.IsEnabled
                Save-SmokeShot '12-deploy-update-settings'
                Start-Deploy
                $s.Phase = 1
                return $false
            }
            1 {
                if (-not (Test-Idle)) { return $false }
                $app = Get-StoreApp $s.Package
                Test-Smoke 'deployment carries the update settings' ($app.notes -match 'update=Custom;grace=72;source=[^;]*;delay=\d+-\d+$' -and $app.notes -notmatch 'version=latest' -and $app.displayVersion -ne 'latest') $app.notes
                $install = Get-Content (Join-Path $script:WorkRoot "package\$($s.Package)\source\install.ps1") -Raw
                Test-Smoke 'install script has the update routine' ($install -match "\`$Mode = 'Custom'" -and $install -match '\$GraceHours = 72')
                Test-GeneratedScripts (Join-Path $script:WorkRoot "package\$($s.Package)") 'Chocolatey'
                $s.Detection = $app.detection
                Reset-DeployPolicy
                Start-TenantRefresh
                $s.Phase = 2
                return $false
            }
            2 {
                if (-not (Test-Idle 'tenant')) { return $false }
                Show-Page 'Tenant'
                $row = @($ui.DgTenant.ItemsSource | Where-Object { $_.Package -eq $s.Package })[0]
                $ui.DgTenant.SelectedItem = $row
                Test-Smoke 'tenant lists version and update mode' ($row.VersionText -eq $row.Version -and $row.UpdateText -eq 'User prompt, installed after 3 day(s)') "$($row.VersionText) / $($row.UpdateText)"
                Test-Smoke 'panel shows the settings of the app' ($ui.GbTenantPolicy.Visibility -eq 'Visible' -and $ui.CmbTenantUpdate.SelectedIndex -eq 2 -and $ui.TxtTenantGrace.Text -eq '3' -and $ui.CmbTenantVersion.SelectedItem -eq $row.Version) "$($ui.CmbTenantUpdate.SelectedIndex)/$($ui.TxtTenantGrace.Text)/$($ui.CmbTenantVersion.SelectedItem)"
                Save-SmokeShot '13-tenant-update-settings'
                # Later change: updates off, follow the latest version again
                $ui.CmbTenantUpdate.SelectedIndex = 0
                Start-AppPolicyUpdate -App $row -Version 'latest' -Policy (Read-PolicyControls 'Tenant')
                $s.Phase = 3
                return $false
            }
            3 {
                if (-not (Test-Idle 'policy') -or -not (Test-Idle 'tenant')) { return $false }
                $app = Get-StoreApp $s.Package
                Test-Smoke 'later change reaches the app in Intune' ($app.notes -match 'version=latest;update=Off' -and $app.displayVersion -eq 'latest' -and $app.uploads -eq 2) "$($app.notes) / $($app.uploads)"
                Test-Smoke 'detection rule changes, devices apply it' ($app.detection -and $app.detection -ne $s.Detection)
                $install = Get-Content (Join-Path $script:WorkRoot "package\$($s.Package)\source\install.ps1") -Raw
                Test-Smoke 'new install script has the new routine' ($install -match "\`$Mode = 'Off'")
                $row = @($ui.DgTenant.ItemsSource | Where-Object { $_.Package -eq $s.Package })[0]
                Test-Smoke 'tenant shows the new settings' ($row.UpdateText -eq 'Off' -and $row.VersionText -eq 'Latest') "$($row.VersionText) / $($row.UpdateText)"
                # A winget app gets the same routine
                $vlc = @($ui.DgTenant.ItemsSource | Where-Object { $_.Package -eq 'VideoLAN.VLC' })[0]
                Test-Smoke 'winget app is deployed with a policy' ($vlc.HasPolicy -and $vlc.UpdateText -eq 'At every startup') "$($vlc.HasPolicy) / $($vlc.UpdateText)"
                $ui.DgTenant.SelectedItem = $vlc
                $ui.CmbTenantUpdate.SelectedIndex = 2; $ui.TxtTenantGrace.Text = '12'; $ui.CmbTenantGraceUnit.SelectedIndex = 0
                $s.WingetDetection = (Get-StoreApp 'VideoLAN.VLC').detection
                Start-AppPolicyUpdate -App $vlc -Version 'latest' -Policy (Read-PolicyControls 'Tenant')
                $s.Phase = 4
                return $false
            }
            4 {
                if (-not (Test-Idle 'policy') -or -not (Test-Idle 'tenant')) { return $false }
                $app = Get-StoreApp 'VideoLAN.VLC'
                Test-Smoke 'winget app changed in Intune' ($app.notes -match '^PoweredByWinget;package=VideoLAN\.VLC;version=latest;update=Custom;grace=12;source=;delay=\d+-\d+$' -and $app.detection -ne $s.WingetDetection) $app.notes
                $folder = Join-Path $script:WorkRoot 'package\winget-VideoLAN.VLC'
                $install = Get-Content (Join-Path $folder 'source\install.ps1') -Raw
                Test-Smoke 'winget install script has the routine' ($install -match "\`$Mode = 'Custom'" -and $install -match '\$GraceHours = 12' -and $install -match 'Intune-Winget-Updates')
                Test-Smoke 'winget prompt starts the winget task' ((Get-Content (Join-Path $folder 'source\notify.ps1') -Raw) -match '\\Intune-Winget-Updates\\Update')
                Test-Smoke 'winget detection checks the policy' ((Get-Content (Join-Path $folder 'detection.ps1') -Raw) -match 'policy\.txt')
                Test-GeneratedScripts $folder 'winget'
                $s.Phase = 5
                # Package ids with a plus survive the notes
                Test-Smoke 'package id with plus read from the notes' ((ConvertFrom-ChocoAppNotes 'PoweredByWinget;package=Notepad++.Notepad++;version=latest;update=Off;grace=48').Package -eq 'Notepad++.Notepad++')
                Test-Smoke 'old notes without policy keep the old behavior' ((ConvertFrom-ChocoAppNotes 'PoweredByChocolatey;package=vlc').UpdateMode -eq 'Startup' -and -not (ConvertFrom-ChocoAppNotes 'PoweredByChocolatey;package=vlc').HasPolicy)
                # Versions to choose from, in both sources
                $s.Waited = 0
                return $false
            }
            5 {
                $s.Waited++
                if (-not (Test-Idle 'versions') -and $s.Waited -lt 600) { return $false }
                $choices = @($ui.CmbTenantVersion.ItemsSource)
                Test-Smoke 'version list has the latest and real versions' ($choices[0] -eq 'Always the latest version' -and $choices.Count -ge 2 -and $choices -contains '3.0.24') ($choices -join ', ')
                $true
            }
        } } }
    @{ Name = 'sandbox test'; Phase = 0; Do = {
        param($s)
        $lab = Join-Path $env:LOCALAPPDATA 'fake-sandbox'
        switch ($s.Phase) {
            0 {
                # The fake studio: the smoke test must never open a real sandbox
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
                Test-Smoke 'Chocolatey test uses the deployed scripts with Chocolatey first' ((Get-Content (Join-Path $lab 'Choco-putty.install\source\Install.ps1') -Raw) -match 'chocolatey\.org/install\.ps1' -and (Test-Path (Join-Path $lab 'Choco-putty.install\source\choco-app.ps1')) -and (Get-Content (Join-Path $lab 'Choco-putty.install\source\choco-app.ps1') -Raw) -match "\`$Mode = 'Custom'")
                Test-Smoke 'result in the activity panel' ((Get-SmokeLog) -match 'sandbox test passed') ''
                Start-PackageTest -Package 'VideoLAN.VLC' -Source 'Winget' -Title 'VLC' -Version 'latest' -Policy @{ UpdateMode = 'Startup'; GraceHours = 24 }
                $s.Phase = 2
                return $false
            }
            2 {
                if (-not (Test-Idle 'test')) { return $false }
                $source = Join-Path $lab 'Winget-VideoLAN.VLC\source'
                Test-Smoke 'winget test ran in the lab' (Test-Path (Join-Path $lab 'Winget-VideoLAN.VLC\started.txt'))
                Test-Smoke 'winget test sets up winget first' ((Get-Content (Join-Path $source 'Install.ps1') -Raw) -match 'Repair-WinGetPackageManager' -and (Get-Content (Join-Path $source 'choco-app.ps1') -Raw) -match "'VideoLAN\.VLC'")
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
        Test-Smoke 'settings show the tenant' ($ui.TxtTenantId.Text -eq 'contoso.onmicrosoft.com') $ui.TxtTenantId.Text
        Save-SmokeShot '07-settings'
        $ui.TxtDelayMin.Text = '30'; $ui.TxtDelayMax.Text = '10'
        try { Save-Settings; Test-Smoke 'invalid delay range rejected' $false } catch { Test-Smoke 'invalid delay range rejected' ($_.Exception.Message -like '*delay*') $_.Exception.Message }
        $ui.TxtDelayMin.Text = '10'; $ui.TxtDelayMax.Text = '90'
        $ui.TxtPackageSource.Text = 'https://proget.contoso.com/nuget/choco/'
        Save-Settings
        $saved = Get-Content $script:SettingsPath -Raw | ConvertFrom-Json
        Test-Smoke 'settings saved' ($saved.UpdateDelayMaxMinutes -eq 90 -and $saved.PackageSource -eq 'https://proget.contoso.com/nuget/choco/')
        Test-Smoke 'deploy defaults follow the settings' ($ui.TxtDeployDefaults.Text -like '*proget*10 to 90*') $ui.TxtDeployDefaults.Text
        Test-Smoke 'settings keep the app registration per tenant' ($saved.TenantClients -eq 'contoso.onmicrosoft.com=11111111-2222-3333-4444-555555555555') $saved.TenantClients
        $true } }
    @{ Name = 'account of another tenant (Keevault choice)'; Do = {
        # Same tenant: nothing changes
        $same = Resolve-AccountTenant 'admin@contoso.onmicrosoft.com'
        Test-Smoke 'account of the tenant signs in there' ($same.TenantID -eq 'contoso.onmicrosoft.com' -and $same.ClientID -eq '11111111-2222-3333-4444-555555555555')
        # Unknown tenant: the tool switches there and offers to create its app registration
        try { [void](Resolve-AccountTenant 'adm@fabrikam.onmicrosoft.com'); Test-Smoke 'unknown tenant stops with a reason' $false }
        catch { Test-Smoke 'unknown tenant stops with a reason' ($_.Exception.Message -like '*fabrikam.onmicrosoft.com*no app registration*Create*') $_.Exception.Message }
        $appreg = Get-ReadinessItems | Where-Object Key -eq 'appreg'
        Test-Smoke 'switched to the new tenant, Create offered' ($script:Settings.TenantID -eq 'fabrikam.onmicrosoft.com' -and -not $script:Settings.ClientID -and $appreg.Fix -eq 'Create') "$($script:Settings.TenantID) / $($appreg.Fix)"
        # Back with an account of a known tenant: its app registration is used again
        $back = Resolve-AccountTenant 'admin@contoso.onmicrosoft.com'
        Test-Smoke 'known tenant uses its own app registration' ($back.TenantID -eq 'contoso.onmicrosoft.com' -and $back.ClientID -eq '11111111-2222-3333-4444-555555555555') "$($back.TenantID) / $($back.ClientID)"
        Switch-Tenant $back.TenantID $back.ClientID
        Test-Smoke 'tenant switched back' ($script:Settings.TenantID -eq 'contoso.onmicrosoft.com' -and $script:Settings.ClientID -eq '11111111-2222-3333-4444-555555555555')
        $true } }
    @{ Name = 'sign out'; Do = {
        Disconnect-Intune
        Test-Smoke 'signed out' ((-not (Test-SignedIn)) -and $ui.TxtConnectionStatus.Text -eq 'Not signed in to Intune' -and $ui.BtnSignIn.IsEnabled)
        Test-Smoke 'deploy disabled when signed out' ($(Show-Page 'Catalog'; -not $ui.BtnDeploy.IsEnabled))
        Test-Smoke 'tenant marks cleared on sign-out' (-not @($ui.DgCatalog.ItemsSource | Where-Object { $_.StatusText -eq 'In tenant' }).Count)
        $logFile = Join-Path $script:LogFolder ('{0:yyyy-MM-dd}.log' -f (Get-Date))
        Test-Smoke 'activity is written to the log file' ((Test-Path $logFile) -and (Get-Content $logFile -Raw) -match 'created in Intune')
        Show-Page 'Start'
        Save-SmokeShot '08-start-signed-out'
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
        catch { Test-Smoke "step '$($step.Name)'" $false $_.Exception.Message; $done = $true }
        if ($done) { $script:SmokeSteps.RemoveAt(0) }
    }
    catch {
        [void]$script:SmokeResults.Add("FAIL driver: $($_.Exception.Message)")
        $script:SmokeResults | Set-Content (Join-Path $script:SmokeOut 'results.txt')
        $window.Close()
    }
})
$window.Add_ContentRendered({ $script:SmokeTimer.Start() })
