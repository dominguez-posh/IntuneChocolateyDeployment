# Dot-sourced by Start-IntuneChocoTool.ps1 when INTUNECHOCO_SMOKE points here (see Tests\Record-Demo.ps1).
# Plays a short tour of the tool off-screen with the fakes of the smoke test (nothing reaches a tenant) and writes
# one PNG per frame plus frames.json (file and duration) to INTUNECHOCO_SMOKE_OUT. A pointer and step captions
# are drawn into the window, so the frames show what is clicked.

$script:DemoOut = $env:INTUNECHOCO_SMOKE_OUT
$window.WindowStartupLocation = 'Manual'
$window.Left = -20000; $window.Top = -20000
$window.ShowActivated = $false
$window.ShowInTaskbar = $false

#region Overlay: pointer, click ring, caption

$demoRoot = $window.Content
$demoOverlay = New-Object System.Windows.Controls.Canvas
$demoOverlay.IsHitTestVisible = $false
[System.Windows.Controls.Grid]::SetRowSpan($demoOverlay, 99)
[System.Windows.Controls.Panel]::SetZIndex($demoOverlay, 1000)
[void]$demoRoot.Children.Add($demoOverlay)

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
function Save-Frame {
    $window.UpdateLayout()
    $w = [int]$window.ActualWidth; $h = [int]$window.ActualHeight
    $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($demoRoot)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $name = 'f{0:d5}.png' -f $script:Frames.Count
    $fs = [IO.File]::Create((Join-Path $script:DemoOut $name))
    try { $enc.Save($fs) } finally { $fs.Dispose() }
    $now = $script:FrameWatch.ElapsedMilliseconds
    if ($script:LastFrame) { $script:LastFrame.ms = [int]($now - $script:LastFrame.at) }
    $script:LastFrame = [ordered]@{ file = $name; at = $now; ms = 100 }
    [void]$script:Frames.Add($script:LastFrame)
}

#endregion

#region Tour

function Show-Caption([string]$Number, [string]$Text) { $script:CaptionTarget = @{ Number = $Number; Text = $Text } }
function Find-AppRow([string]$Key) { @($script:SourceRows | Where-Object { (Get-AppKey $_) -eq $Key })[0] }
function Use-Chocolatey { foreach ($entry in $script:DeployCombos) { $entry.Combo.SelectedIndex = [array]::IndexOf($entry.Sources, 'Chocolatey') } }

# Each step: optional Caption, Target (element or point to move to), Click (runs after the pointer arrived),
# Until (wait for background work), Hold (ms to stay afterwards)
$script:Tour = [System.Collections.ArrayList]@(
    @{ Do = {
        $cfg = Get-IntuneChocoSettings; $cfg.ClientID = ''; [void](Save-IntuneChocoSettings -Settings $cfg); $script:Settings = Get-IntuneChocoSettings
        $script:SignInTest = @{ Authority = $env:INTUNECHOCO_SMOKE_AUTHORITY; GraphUrl = $env:INTUNECHOCO_SMOKE_AUTHORITY
            UrlHandler = 'param($Url) $global:DemoClient = New-Object System.Net.WebClient; [void]$global:DemoClient.DownloadStringTaskAsync([uri]$Url)' }
        Show-Page 'Start' }; Hold = 600 }
    @{ Caption = @('1', 'Set up once: module, app registration with consent, sign-in, dependency apps'); Hold = 1800 }
    @{ Target = { Get-Center $ui.BtnSetupAll }; Click = { & $script:ClickActions[$ui.BtnSetupAll] }
       Until = { -not $script:SetupRunning -and (Test-DemoIdle) }; Hold = 1800 }
    @{ Caption = @('2', 'Pick apps from one list with winget and Chocolatey'); Target = { Get-Center $ui.NavApps }; Click = { Show-Page 'Apps' }
       Until = { Test-DemoIdle 'meta' }; Hold = 900 }
    @{ Target = { Get-Center $ui.TxtFilter }; Click = { $ui.TxtFilter.Focus() | Out-Null }; Hold = 200 }
    @{ Type = 'firefox'; Hold = 500 }
    @{ Target = { Get-Center ($ui.CardList.ItemContainerGenerator.ContainerFromIndex(0)) }; Click = { Set-AppSelected $script:CardCollection[0].Data $true }; Hold = 600 }
    @{ Target = { Get-Center $ui.TxtFilter }; Click = { $ui.TxtFilter.Text = '' }; Hold = 150 }
    @{ Type = '7-zip'; Hold = 400 }
    @{ Click = { Set-AppSelected $script:CardCollection[0].Data $true }; Hold = 500 }
    @{ Target = { Get-Center $ui.TxtFilter }; Click = { $ui.TxtFilter.Text = '' }; Hold = 150 }
    @{ Caption = @('3', 'Review: source per app, assignment and updates, then deploy'); Target = { Get-Center $ui.BtnReview }; Click = { $ui.RbRequired.IsChecked = $true; Show-DeployDialog; Use-Chocolatey }; Hold = 2200 }
    @{ Target = { Get-Center $ui.BtnDeployGo }; Click = { Start-Deploy }; Hold = 300 }
    @{ Caption = @('4', 'Package, upload, dependency and assignment run in the background'); Until = { Test-DemoIdle }; Hold = 1500 }
    @{ Caption = @('5', 'Your apps in Intune: version, update mode, release new versions'); Target = { Get-Center $ui.NavTenant }; Click = { Show-Page 'Tenant' }
       Until = { Test-DemoIdle }; Hold = 900 }
    @{ Click = { $ui.LstTenant.SelectedItem = @($script:TenantRowList | Where-Object { $_.Data.Package -eq '7zip.install' })[0] }; Hold = 2600 }
    @{ Do = { Close-Dialog }; Caption = @('', ''); Hold = 400 }
)

function Test-DemoIdle([string]$Kind) { -not @($script:Tasks | Where-Object { if ($Kind) { $_.Job.Kind -eq $Kind } else { $_.Job.Kind -ne 'icons' } }).Count }

$script:Step = $null
$script:DemoTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:DemoTimer.Interval = [TimeSpan]::FromMilliseconds(70)
$script:DemoTimer.Add_Tick({
    try {
        # Caption fades out, swaps text, fades in
        if ($script:CaptionTarget) {
            if ($demoCaption.Opacity -gt 0 -and $demoCaptionText.Text -ne $script:CaptionTarget.Text) { $demoCaption.Opacity = [Math]::Max(0, $demoCaption.Opacity - 0.34) }
            else {
                $demoCaptionText.Text = $script:CaptionTarget.Text; $demoBadgeText.Text = $script:CaptionTarget.Number
                $demoBadge.Visibility = if ($script:CaptionTarget.Number) { 'Visible' } else { 'Collapsed' }
                $demoCaption.UpdateLayout()
                [System.Windows.Controls.Canvas]::SetLeft($demoCaption, ($demoRoot.ActualWidth - $demoCaption.ActualWidth) / 2)
                [System.Windows.Controls.Canvas]::SetTop($demoCaption, $demoRoot.ActualHeight - 150)
                if ($script:CaptionTarget.Text) { $demoCaption.Opacity = [Math]::Min(1, $demoCaption.Opacity + 0.34) }
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
                if ($s.Target) { $t = & $s.Target; $s.From = @{ X = $script:DemoPos.X; Y = $script:DemoPos.Y }; $s.To = @{ X = $t.X - 2; Y = $t.Y - 2 }; $s.N = 0 }
                $s.Typed = 0; $s.Since = $null
            }
            'move' {
                $s.N++
                $k = [Math]::Min(1, $s.N / 11); $e = 1 - [Math]::Pow(1 - $k, 3)
                Set-PointerAt ($s.From.X + ($s.To.X - $s.From.X) * $e) ($s.From.Y + ($s.To.Y - $s.From.Y) * $e)
                if ($k -ge 1) {
                    $s.Phase = 'wait'
                    if ($s.Click) { $demoRing.Tag = 0; $demoRing.Visibility = 'Visible'; & $s.Click }
                }
            }
            'type' {
                $s.Typed++
                $ui.TxtFilter.Text = $s.Type.Substring(0, [Math]::Min($s.Typed, $s.Type.Length))
                if ($s.Typed -ge $s.Type.Length) { $s.Phase = 'wait' }
            }
            'wait' {
                if ($s.Until -and -not (& $s.Until)) { break }
                if (-not $s.Since) { $s.Since = $script:FrameWatch.ElapsedMilliseconds }
                if ($script:FrameWatch.ElapsedMilliseconds - $s.Since -ge [int]$s.Hold) { $script:Step = $null }
            }
        }
        Save-Frame
    }
    catch {
        "FAIL demo: $($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)" | Set-Content (Join-Path $script:DemoOut 'error.txt')
        $script:DemoTimer.Stop()
        $window.Close()
    }
})
$window.Add_ContentRendered({ $script:DemoTimer.Start() })

#endregion
