# Dot-sourced by Start-PackTune.ps1 when PACKTUNE_SMOKE points here (see Tests\Record-Demo.ps1).
# Plays a short tour of the tool off-screen with the fakes of the smoke test (nothing reaches a tenant) and writes
# one PNG per frame plus frames.json (file and duration) to PACKTUNE_SMOKE_OUT. A pointer and step captions
# are drawn into the window, so the frames show what is clicked.

$script:DemoOut = $env:PACKTUNE_SMOKE_OUT
$window.WindowStartupLocation = 'Manual'
$window.Left = -20000; $window.Top = -20000
$window.ShowActivated = $false
$window.ShowInTaskbar = $false

# The demo environment has no WebView2 runtime: keep its "sign-in window not available" warning out of the pictures
$script:RealShowToast = ${function:Show-Toast}
function Show-Toast([string]$Text, [string]$Kind = 'info') { if ($Kind -eq 'warn' -and $Text -like 'The sign-in window*') { return }; & $script:RealShowToast $Text $Kind }

#region Overlay: pointer, click ring, caption

$demoRoot = $window.Content
$demoOverlay = New-Object System.Windows.Controls.Canvas
$demoOverlay.IsHitTestVisible = $false
[System.Windows.Controls.Grid]::SetRowSpan($demoOverlay, 99)
[System.Windows.Controls.Panel]::SetZIndex($demoOverlay, 1000)
[void]$demoRoot.Children.Add($demoOverlay)
# Raw mode (Tests\Record-Demo.ps1): the compositor draws pointer, click ring and captions from frames.json
if ($env:PACKTUNE_DEMO_RAW) { $demoOverlay.Opacity = 0 }
$script:Focus = $null; $script:LastBounds = $null; $script:Scene = 0

$demoPointer = New-Object System.Windows.Shapes.Path
$demoPointer.Data = [System.Windows.Media.Geometry]::Parse('M0,0 L0,18 L4.6,13.8 L7.8,21 L10.6,19.8 L7.6,12.8 L13.4,12.8 Z')
$demoPointer.Fill = [System.Windows.Media.Brushes]::Black
$demoPointer.Stroke = [System.Windows.Media.Brushes]::White
$demoPointer.StrokeThickness = 1.4
$demoPointer.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect -Property @{ BlurRadius = 4; ShadowDepth = 1; Opacity = 0.35 }
[void]$demoOverlay.Children.Add($demoPointer)

$demoRing = New-Object System.Windows.Shapes.Ellipse
$demoRing.Fill = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(110, 0, 103, 192))
$demoRing.Visibility = 'Collapsed'
[void]$demoOverlay.Children.Add($demoRing)

$demoCaption = New-Object System.Windows.Controls.Border
$demoCaption.CornerRadius = 18
$demoCaption.Padding = '16,9,18,9'
$demoCaption.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(235, 17, 24, 39))
$demoCaption.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect -Property @{ BlurRadius = 18; ShadowDepth = 3; Opacity = 0.3 }
$demoCaptionRow = New-Object System.Windows.Controls.StackPanel -Property @{ Orientation = 'Horizontal' }
$demoBadge = New-Object System.Windows.Controls.Border -Property @{ Width = 22; Height = 22; CornerRadius = 11; Margin = '0,0,10,0' }
$demoBadge.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(76, 194, 255))
$demoBadgeText = New-Object System.Windows.Controls.TextBlock -Property @{ FontSize = 12; FontWeight = 'Bold'; HorizontalAlignment = 'Center'; VerticalAlignment = 'Center' }
$demoBadgeText.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0, 36, 61))
$demoBadge.Child = $demoBadgeText
$demoCaptionText = New-Object System.Windows.Controls.TextBlock -Property @{ FontSize = 14.5; FontWeight = 'SemiBold'; VerticalAlignment = 'Center'; Foreground = [System.Windows.Media.Brushes]::White }
[void]$demoCaptionRow.Children.Add($demoBadge); [void]$demoCaptionRow.Children.Add($demoCaptionText)
$demoCaption.Child = $demoCaptionRow
$demoCaption.Opacity = 0
[void]$demoOverlay.Children.Add($demoCaption)

$script:DemoPos = @{ X = 640.0; Y = 470.0 }
function Set-PointerAt([double]$X, [double]$Y) {
    $script:DemoPos.X = $X; $script:DemoPos.Y = $Y
    [System.Windows.Controls.Canvas]::SetLeft($demoPointer, $X); [System.Windows.Controls.Canvas]::SetTop($demoPointer, $Y)
}
Set-PointerAt 640 470

function Get-Center($Element) {
    $Element.UpdateLayout()
    $p = $Element.TranslatePoint((New-Object System.Windows.Point ($Element.ActualWidth / 2), ($Element.ActualHeight / 2)), $demoRoot)
    $tl = $Element.TranslatePoint((New-Object System.Windows.Point 0, 0), $demoRoot)
    $script:LastBounds = @{ X = $tl.X; Y = $tl.Y; W = $Element.ActualWidth; H = $Element.ActualHeight }
    return @{ X = $p.X; Y = $p.Y }
}
function Get-RowElement($Grid, $Item) {
    $Grid.ScrollIntoView($Item); $Grid.UpdateLayout()
    $row = $Grid.ItemContainerGenerator.ContainerFromItem($Item)
    # Aim at the name column, not the middle of a wide row
    if ($row) { $c = Get-Center $row; return @{ X = [Math]::Min($c.X, 160); Y = $c.Y } }
}

#endregion

#region Frames

$script:Frames = New-Object System.Collections.ArrayList
$script:FrameWatch = [Diagnostics.Stopwatch]::StartNew()
$script:LastFrame = $null
function Save-Frame([int]$Cap = 0) {
    $window.UpdateLayout()
    $w = [int]$window.Content.ActualWidth; $h = [int]$window.Content.ActualHeight
    $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($demoRoot)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $name = 'f{0:d5}.png' -f $script:Frames.Count
    $fs = [IO.File]::Create((Join-Path $script:DemoOut $name))
    try { $enc.Save($fs) } finally { $fs.Dispose() }
    $now = $script:FrameWatch.ElapsedMilliseconds
    if ($script:LastFrame) { $script:LastFrame.ms = [int]($now - $script:LastFrame.at); if ($script:LastFrame.cap) { $script:LastFrame.ms = [Math]::Min($script:LastFrame.ms, $script:LastFrame.cap) } }
    $f = $script:Focus
    $ringAge = -1; if ($demoRing.Visibility -eq 'Visible') { $ringAge = [int]$demoRing.Tag }
    $capText = ''; $capNum = ''; if ($demoCaption.Opacity -ge 0.9) { $capText = $demoCaptionText.Text; $capNum = $demoBadgeText.Text }
    $script:LastFrame = [ordered]@{ file = $name; at = $now; ms = 100; cap = $Cap }
    # Pointer, focus rectangle (the element being targeted, $null between scenes), scene, click ring age and caption for Tests\Render-Showcase.ps1
    $script:LastFrame.px = [Math]::Round($script:DemoPos.X, 1); $script:LastFrame.py = [Math]::Round($script:DemoPos.Y, 1)
    $script:LastFrame.fx = $null; $script:LastFrame.fy = $null; $script:LastFrame.fw = $null; $script:LastFrame.fh = $null
    if ($f) { $script:LastFrame.fx = [Math]::Round($f.X, 1); $script:LastFrame.fy = [Math]::Round($f.Y, 1); $script:LastFrame.fw = [Math]::Round($f.W, 1); $script:LastFrame.fh = [Math]::Round($f.H, 1) }
    $script:LastFrame.scene = $script:Scene; $script:LastFrame.ring = $ringAge; $script:LastFrame.caption = $capText; $script:LastFrame.captionNumber = $capNum
    [void]$script:Frames.Add($script:LastFrame)
}

#endregion

#region Tour

function Show-Caption([string]$Number, [string]$Text) {
    $script:CaptionTarget = @{ Number = $Number; Text = $Text }
    $script:Focus = $null; if ($Number) { $script:Scene = [int]$Number } else { $script:Scene = 0 }
}
function Find-AppRow([string]$Key) { @($script:SourceRows | Where-Object { (Get-AppKey $_) -eq $Key })[0] }
function Get-ListCenter($Element) { $c = Get-Center $Element; @{ X = [Math]::Min($c.X, 420); Y = $c.Y } }
function Select-ByName([string]$Name) { Set-AppSelected (@($script:SourceRows | Where-Object { $_.Name -eq $Name })[0]) $true }

# Each step: optional Caption, Target (element or point to move to), Click (runs after the pointer arrived),
# Until (wait for background work: frames are then taken in fast forward), Hold (ms to stay afterwards)
$script:Tour = [System.Collections.ArrayList]@(
    @{ Do = {
        $script:EmbeddedAvailableOverride = $false; $script:SandboxOverride = @{ Present = $true; Studio = $true }; Update-SandboxState
        $cfg = Get-PackTuneSettings; $cfg.ClientID = ''; [void](Save-PackTuneSettings -Settings $cfg); $script:Settings = Get-PackTuneSettings
        $script:InsightFake = Get-Content (Join-Path (Split-Path $env:PACKTUNE_SMOKE) 'InsightFake.txt') -Raw
        $script:SignInTest = @{ Authority = $env:PACKTUNE_SMOKE_AUTHORITY; GraphUrl = $env:PACKTUNE_SMOKE_AUTHORITY
            UrlHandler = 'param($Url) $global:DemoClient = New-Object System.Net.WebClient; [void]$global:DemoClient.DownloadStringTaskAsync([uri]$Url)' }
        Show-Page 'Start'; Start-CatalogPrefetch }; Hold = 500 }
    @{ Caption = @('1', 'Set up once: module, app registration, sign-in, dependency apps'); Hold = 2200 }
    @{ Target = { Get-Center $ui.BtnSetupAll }; Click = { & $script:ClickActions[$ui.BtnSetupAll] }
       Until = { -not $script:SetupRunning -and (Test-DemoIdle) }; Hold = 2200 }
    @{ Do = { Start-StatusScriptSetup }; Until = { Test-DemoIdle }; Hold = 1800 }
    @{ Caption = @('2', 'Pick apps from one list with winget and Chocolatey'); Target = { Get-Center $ui.NavApps }; Click = { Show-Page 'Apps' }
       Until = { Test-DemoIdle 'meta' }; Hold = 700 }
    @{ Target = { Get-Center $ui.TxtFilter }; Click = { $ui.TxtFilter.Focus() | Out-Null }; Hold = 150 }
    @{ Type = 'zip'; Hold = 400 }
    @{ Target = { Get-Center ($ui.CardList.ItemContainerGenerator.ContainerFromIndex(0)) }; Click = { Set-AppSelected $script:CardCollection[0].Data $true }; Hold = 900 }
    @{ Target = { Get-Center $ui.TxtFilter }; Click = { $ui.TxtFilter.Text = '' }; Hold = 100 }
    @{ Type = 'notepad'; Hold = 400 }
    @{ Target = { Get-Center ($ui.CardList.ItemContainerGenerator.ContainerFromIndex(0)) }; Click = { Set-AppSelected $script:CardCollection[0].Data $true }; Hold = 900 }
    @{ Target = { Get-Center $ui.TxtFilter }; Click = { $ui.TxtFilter.Text = '' }; Hold = 100 }
    @{ Type = 'vlc'; Hold = 400 }
    @{ Target = { Get-Center ($ui.CardList.ItemContainerGenerator.ContainerFromIndex(0)) }; Click = { Set-AppSelected $script:CardCollection[0].Data $true }; Hold = 600 }
    @{ Click = { $ui.TxtFilter.Text = ''; Show-AppDetails (Find-AppRow '7zip.install') }; Hold = 2400 }
    @{ Target = { Get-Center $ui.BtnDetailClose }; Click = { $script:DetailRow = $null; $ui.PanelDetails.Visibility = 'Collapsed'; Update-SelectionBar }; Hold = 300 }
    @{ Caption = @('3', 'Review: choose the source per app, then deploy'); Target = { Get-Center $ui.BtnReview }; Click = { Show-DeployDialog }; Hold = 2200 }
    @{ Target = { Get-Center $script:DeployCombos[1].Combo }; Click = { $c = $script:DeployCombos[1]; $c.Combo.SelectedIndex = ($c.Combo.SelectedIndex + 1) % $c.Sources.Count }; Hold = 2200 }
    @{ Target = { Get-Center $ui.BtnDeployGo }; Click = { Start-Deploy }; Hold = 200 }
    @{ Caption = @('4', 'Deployments run in the background, with progress'); Until = { Test-DemoIdle }; Hold = 1800 }
    @{ Caption = @('5', 'In tenant: version, update mode, schedule per app'); Target = { Get-Center $ui.NavTenant }; Click = { Show-Page 'Tenant' }
       Until = { Test-DemoIdle }; Hold = 900 }
    @{ Target = { Get-ListCenter ($ui.LstTenant.ItemContainerGenerator.ContainerFromItem(@($script:TenantRowList | Where-Object { $_['Title'] -eq '7-Zip' })[0])) }
       Click = { $ui.LstTenant.SelectedItem = @($script:TenantRowList | Where-Object { $_['Title'] -eq '7-Zip' })[0] }; Hold = 1600 }
    @{ Target = { Get-Center $ui.BtnTenantSchedule }; Click = { & $script:ClickActions[$ui.BtnTenantSchedule] }; Hold = 3200 }
    @{ Target = { Get-Center $ui.BtnScheduleCancel }; Click = { Close-Dialog }; Hold = 500 }
    @{ Caption = @('6', 'Install status per device, with the cause of a failure'); Target = { Get-ListCenter ($ui.LstTenant.ItemContainerGenerator.ContainerFromItem(@($script:TenantRowList | Where-Object { $_['Title'] -eq '7-Zip' })[0])) }
       Click = { Show-AppStatus (@($script:TenantRowList | Where-Object { $_['Title'] -eq '7-Zip' })[0]).Data }; Until = { Test-DemoIdle }; Hold = 3800 }
    @{ Target = { Get-Center $ui.NavApps }; Click = { Show-Page 'Apps' }; Caption = @('', ''); Hold = 1800 }
)

function Test-DemoIdle([string]$Kind) { -not @($script:Tasks | Where-Object { if ($Kind) { $_.Job.Kind -eq $Kind } else { $_.Job.Kind -ne 'icons' } }).Count }

$script:Step = $null
$script:DemoTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:DemoTimer.Interval = [TimeSpan]::FromMilliseconds(70)
$script:DemoTimer.Add_Tick({
    try {
        # Caption fades out, swaps text, fades in
        if ($script:CaptionTarget) {
            if ($demoCaption.Opacity -gt 0 -and $demoCaptionText.Text -ne $script:CaptionTarget.Text) { $demoCaption.Opacity = [Math]::Max(0.0, $demoCaption.Opacity - 0.34) }
            else {
                $demoCaptionText.Text = $script:CaptionTarget.Text; $demoBadgeText.Text = $script:CaptionTarget.Number
                $demoBadge.Visibility = if ($script:CaptionTarget.Number) { 'Visible' } else { 'Collapsed' }
                $demoCaption.UpdateLayout()
                [System.Windows.Controls.Canvas]::SetLeft($demoCaption, ($demoRoot.ActualWidth - $demoCaption.ActualWidth) / 2)
                [System.Windows.Controls.Canvas]::SetTop($demoCaption, $demoRoot.ActualHeight - 150)
                if ($script:CaptionTarget.Text) { $demoCaption.Opacity = [Math]::Min(1.0, $demoCaption.Opacity + 0.34) }
                if ($demoCaption.Opacity -ge 1 -or -not $script:CaptionTarget.Text) { $script:CaptionTarget = $null }
            }
        }
        # Click ring grows and fades
        if ($demoRing.Visibility -eq 'Visible') {
            $demoRing.Tag = [int]$demoRing.Tag + 1
            $size = 14 + 9 * [int]$demoRing.Tag
            $demoRing.Width = $size; $demoRing.Height = $size; $demoRing.Opacity = 1 - [int]$demoRing.Tag / 6
            [System.Windows.Controls.Canvas]::SetLeft($demoRing, $script:DemoPos.X - $size / 2); [System.Windows.Controls.Canvas]::SetTop($demoRing, $script:DemoPos.Y - $size / 2)
            if ([int]$demoRing.Tag -ge 6) { $demoRing.Visibility = 'Collapsed' }
        }

        if (-not $script:Step) {
            if ($script:Tour.Count -eq 0) {
                $script:DemoTimer.Stop()
                Save-Frame
                $script:Frames | ConvertTo-Json | Set-Content (Join-Path $script:DemoOut 'frames.json')
                $window.Close()
                return
            }
            $script:Step = $script:Tour[0]; $script:Tour.RemoveAt(0)
            $script:Step.Phase = 'start'
        }
        $s = $script:Step
        switch ($s.Phase) {
            'start' {
                if ($s.Do) { & $s.Do }
                if ($s.Caption) { Show-Caption $s.Caption[0] $s.Caption[1] }
                $s.Phase = if ($s.Target) { 'move' } elseif ($s.Type) { 'type' } else { 'wait' }
                if ($s.Target) { $t = & $s.Target; $script:Focus = $script:LastBounds; $s.From = @{ X = $script:DemoPos.X; Y = $script:DemoPos.Y }; $s.To = @{ X = $t.X - 2; Y = $t.Y - 2 }; $s.N = 0 }
                $s.Typed = 0; $s.Since = $null
            }
            'move' {
                $script:FastFrame = 70
                $s.N++
                $k = [Math]::Min(1, $s.N / 8); $e = 1 - [Math]::Pow(1 - $k, 3)
                Set-PointerAt ($s.From.X + ($s.To.X - $s.From.X) * $e) ($s.From.Y + ($s.To.Y - $s.From.Y) * $e)
                if ($k -ge 1) {
                    $s.Phase = 'wait'
                    if ($s.Click) { $demoRing.Tag = 0; $demoRing.Visibility = 'Visible'; & $s.Click }
                }
            }
            'type' {
                $script:FastFrame = 90
                $s.Typed++
                $ui.TxtFilter.Text = $s.Type.Substring(0, [Math]::Min($s.Typed, $s.Type.Length))
                if ($s.Typed -ge $s.Type.Length) { $s.Phase = 'wait' }
            }
            'wait' {
                if ($s.Until -and -not (& $s.Until)) { $s.Skip++; if ($s.Skip % 6 -ne 1) { $script:NoFrame = $true } else { $script:FastFrame = 200 }; break }
                if (-not $s.Since) { $s.Since = $script:FrameWatch.ElapsedMilliseconds }
                if ($script:FrameWatch.ElapsedMilliseconds - $s.Since -ge ([int]$s.Hold * 0.3)) { $script:Step = $null }
            }
        }
        if (-not $script:NoFrame) { Save-Frame ([int]$script:FastFrame) }
        $script:NoFrame = $false; $script:FastFrame = 0
    }
    catch {
        "FAIL demo: $($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)" | Set-Content (Join-Path $script:DemoOut 'error.txt')
        $script:DemoTimer.Stop()
        $window.Close()
    }
})
$window.Add_ContentRendered({ $script:DemoTimer.Start() })

#endregion
