#requires -Version 5.1
<#
.SYNOPSIS
    Intune Chocolatey Deployment - graphical interface for ChocoIntuneDeployment-Main.ps1.
.DESCRIPTION
    Look and window technique of the M365 MFA Administration tool and MSIX Sandbox Studio: shared UI\Theme.xaml,
    slate header with connection state, Start.cmd starts the console hidden. Sign in opens the Microsoft sign-in in
    the browser (IntuneWin32App module); the arrow next to it offers the sign-in with an account from Keevault
    (embedded browser, filled in from the password manager).
    Deployments, feed lookups and tenant reads run in background runspaces; their log lines show up live in the
    activity panel, so the window never freezes. Deployments run one after another.
.PARAMETER HideConsole
    Set by Start.cmd: hides the console window of this process.
#>
[CmdletBinding()]
param([switch]$HideConsole)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw "This WPF tool requires Windows PowerShell 5.1: powershell.exe -ExecutionPolicy Bypass -File `"$PSCommandPath`""
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$script:AppRoot = $PSScriptRoot
$script:ToolVersion = '2.2.0'
$script:RepoUrl = 'https://github.com/dominguez-posh/IntuneChocolateyDeployment'
$script:CorePath = Join-Path $PSScriptRoot 'ChocoIntuneDeployment-Main.ps1'
. $script:CorePath
Import-Module (Join-Path $PSScriptRoot 'Modules\Keevault.psm1') -Force

# ---------------------------------------------------------------- console window (M365 MFA tool technique)
if (-not ('IntuneChoco.NativeWindow' -as [type])) {
    Add-Type -Namespace IntuneChoco -Name NativeWindow -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int command);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
'@
}

function Hide-ConsoleWindow {
    # The console is looked up again each time: Windows Terminal may take it over when it becomes visible.
    param([IntPtr]$Window = [IntPtr]::Zero)
    $native = [IntuneChoco.NativeWindow]
    if ($Window -ne [IntPtr]::Zero) { [void]$native::ShowWindow($Window, 0) }
    # GA_ROOTOWNER (3): with Windows Terminal, the console window is a hidden pseudo window owned by the terminal.
    $current = $native::GetAncestor($native::GetConsoleWindow(), 3)
    if ($current -ne [IntPtr]::Zero -and $current -ne $Window) { [void]$native::ShowWindow($current, 0) }
}

function Invoke-InteractiveSignIn {
    <#
    A sign-in dialog that belongs to the console window (Web Account Manager) stays invisible while the console is
    hidden. The console is shown centered over the tool while signing in and hidden again afterwards; then the tool
    is activated again. The IntuneWin32App module signs in through the browser, so this is only used for sign-ins
    that open a Windows dialog.
    #>
    param([Parameter(Mandatory)][scriptblock]$Action)
    $native = [IntuneChoco.NativeWindow]
    $active = $native::GetForegroundWindow()
    $console = $native::GetAncestor($native::GetConsoleWindow(), 3)
    $state = if ($console -eq [IntPtr]::Zero) { 'None' }
             elseif ($native::IsIconic($console)) { 'Minimized' }
             elseif (-not $native::IsWindowVisible($console)) { 'Hidden' }
             else { 'Visible' }
    if ($state -in 'Minimized', 'Hidden') {
        [void]$native::ShowWindow($console, 9)   # SW_RESTORE
        $toolRect = New-Object IntuneChoco.NativeWindow+RECT
        $consoleRect = New-Object IntuneChoco.NativeWindow+RECT
        if ($active -ne [IntPtr]::Zero -and $native::GetWindowRect($active, [ref]$toolRect) -and $native::GetWindowRect($console, [ref]$consoleRect)) {
            $x = [int](($toolRect.Left + $toolRect.Right - ($consoleRect.Right - $consoleRect.Left)) / 2)
            $y = [int](($toolRect.Top + $toolRect.Bottom - ($consoleRect.Bottom - $consoleRect.Top)) / 2)
            [void]$native::SetWindowPos($console, [IntPtr]::Zero, $x, $y, 0, 0, 0x0001 -bor 0x0004)   # SWP_NOSIZE | SWP_NOZORDER
        }
    }
    if ($state -ne 'None') { [void]$native::SetForegroundWindow($console) }
    try { & $Action }
    finally {
        switch ($state) {
            'Minimized' { [void]$native::ShowWindow($console, 6) }   # SW_MINIMIZE
            'Hidden'    { Hide-ConsoleWindow -Window $console }
        }
        if ($active -ne [IntPtr]::Zero) { [void]$native::SetForegroundWindow($active) }
    }
}

if ($HideConsole) { Hide-ConsoleWindow }

# ---------------------------------------------------------------- window
if (-not [System.Windows.Application]::Current) { [void](New-Object System.Windows.Application) }
[System.Windows.Application]::Current.ShutdownMode = 'OnExplicitShutdown'
[xml]$themeXml = Get-Content (Join-Path $PSScriptRoot 'UI\Theme.xaml') -Raw -Encoding UTF8
[System.Windows.Application]::Current.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($themeXml)))
[xml]$xaml = Get-Content (Join-Path $PSScriptRoot 'UI\MainWindow.xaml') -Raw -Encoding UTF8
$window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))

$ui = @{}
foreach ($node in $xaml.SelectNodes("//*[@*[local-name()='Name']]")) {
    $name = $node.Attributes | Where-Object LocalName -eq 'Name' | Select-Object -ExpandProperty Value
    $ui[$name] = $window.FindName($name)
}
$window.Title = "Intune Choco Deployment $script:ToolVersion"

$script:BrushConverter = New-Object System.Windows.Media.BrushConverter
function Get-Brush([string]$Key) { [System.Windows.Application]::Current.Resources[$Key] }
function ConvertTo-Brush([string]$Hex) { $script:BrushConverter.ConvertFrom($Hex) }

# ---------------------------------------------------------------- rows for the lists
# One generic row object for every list of the window (cards, tenant table, jobs, import and device tables). The
# templates in MainWindow.xaml bind to its indexer ({Binding [Title]}); values are text, so flags are 'True'/'False'
# and visibilities 'Visible'/'Collapsed'. Data holds the object behind the row.
if (-not ('IntuneChoco.Row' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Collections.Generic;
using System.ComponentModel;
namespace IntuneChoco {
    public class Row : INotifyPropertyChanged {
        private Dictionary<string, object> values = new Dictionary<string, object>();
        private object items;
        public event PropertyChangedEventHandler PropertyChanged;
        public object Data { get; set; }
        public object Items { get { return items; } set { items = value; Raise("Items"); } }
        public object this[string key] {
            get { object v; return values.TryGetValue(key, out v) ? v : null; }
            set { values[key] = value; Raise("Item[]"); }
        }
        private void Raise(string name) { PropertyChangedEventHandler h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(name)); }
    }
}
'@ -ReferencedAssemblies System.dll
}
function Set-Row($Row, [hashtable]$Values) {
    foreach ($key in $Values.Keys) {
        if ($key -eq 'Items') { $Row.Items = $Values[$key] }
        elseif ($key -eq 'Data') { $Row.Data = $Values[$key] }
        else { $Row[$key] = $(if ($null -eq $Values[$key]) { $null } else { [string]$Values[$key] }) }
    }
    $Row
}
function New-Row([hashtable]$Values) { Set-Row (New-Object IntuneChoco.Row) $Values }
function ConvertTo-Vis([bool]$On) { if ($On) { 'Visible' } else { 'Collapsed' } }

# Tile colors (background, letter) as in the mockups; a name always gets the same pair
$script:TilePalette = @(@('#E8F0FE', '#1A56C4'), @('#FDEBDD', '#A3450C'), @('#DDF1F7', '#0B5F75'), @('#FDE6E1', '#A6301A'), @('#E5F3E2', '#2E6B1F'),
    @('#EDEDED', '#1B1B1B'), @('#FBE3E3', '#A11D1D'), @('#FFEBD6', '#9A4A00'), @('#E3EEF9', '#1F4E8C'), @('#E9EEF3', '#2F4A63'))
function Get-TileStyle([string]$Name) {
    $sum = 0; foreach ($c in $Name.ToCharArray()) { $sum += [int]$c }
    $pair = $script:TilePalette[$sum % $script:TilePalette.Count]
    @{ TileBg = $pair[0]; TileFg = $pair[1]; Mono = $(if ($Name) { $Name.Substring(0, 1).ToUpper() } else { '?' }) }
}

# Pills: kind -> background, text
$script:PillColors = @{
    ok = @('#DFF6DD', '#0E5C0E'); warn = @('#FFF4CE', '#7A4A00'); bad = @('#FDE7E9', '#A11D1D'); info = @('#E8F1FB', '#003E92'); gray = @('#F0F0F0', '#3B3B3B')
}

# ---------------------------------------------------------------- log file, toasts
$script:UiLogLines = New-Object System.Collections.ArrayList
$script:LogFolder = Join-Path $script:WorkRoot 'logs'
function Write-UiLog([string]$Text, [string]$Level = 'Info') {
    # Messages of the window itself (tasks keep their own log in the activity list). Also into a log file per day.
    $now = Get-Date
    [void]$script:UiLogLines.Add($Text)
    while ($script:UiLogLines.Count -gt 500) { $script:UiLogLines.RemoveAt(0) }
    try {
        if (-not (Test-Path $script:LogFolder)) { New-Item -Path $script:LogFolder -ItemType Directory -Force | Out-Null }
        Add-Content -Path (Join-Path $script:LogFolder ('{0:yyyy-MM-dd}.log' -f $now)) -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1,-7}  {2}' -f $now, $Level, $Text) -Encoding UTF8
    }
    catch { }
}
Set-IntuneChocoSignInLog { param($Text, $Level) Write-UiLog $Text $(if ($Level) { $Level } else { 'Info' }) }

$script:Toasts = New-Object System.Collections.ArrayList
function Show-Toast([string]$Text, [string]$Kind = 'info') {
    <# Short message in the corner: what a job did, or what went wrong. Success and info vanish after 6 s, problems after 12 s. #>
    $pill = $script:PillColors[$Kind]; if (-not $pill) { $pill = @('#FFFFFF', '#1B1B1B') }
    $glyph = @{ ok = [char]0xE73E; warn = [char]0xE7BA; bad = [char]0xEA39; info = [char]0xE946 }[$Kind]
    $border = New-Object System.Windows.Controls.Border
    $border.Background = ConvertTo-Brush $(if ($Kind -eq 'info') { '#FFFFFF' } else { $pill[0] })
    $border.BorderBrush = ConvertTo-Brush '#D1D1D1'; $border.BorderThickness = 1; $border.CornerRadius = 8; $border.Padding = '14,10'; $border.Margin = '0,8,0,0'
    $border.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect -Property @{ BlurRadius = 16; ShadowDepth = 3; Opacity = 0.18 }
    $grid = New-Object System.Windows.Controls.Grid
    foreach ($w in 'Auto', '*') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = if ($w -eq '*') { [System.Windows.GridLength]::new(1, 'Star') } else { [System.Windows.GridLength]::Auto }; [void]$grid.ColumnDefinitions.Add($c) }
    $icon = New-Object System.Windows.Controls.TextBlock
    $icon.Text = [string]$glyph; $icon.FontFamily = $window.FindResource('IconFont'); $icon.FontSize = 15; $icon.Margin = '0,1,10,0'; $icon.VerticalAlignment = 'Top'
    $icon.Foreground = ConvertTo-Brush $pill[1]
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Text; $label.TextWrapping = 'Wrap'; $label.Foreground = ConvertTo-Brush $(if ($Kind -eq 'info') { '#1B1B1B' } else { $pill[1] })
    [System.Windows.Controls.Grid]::SetColumn($label, 1)
    [void]$grid.Children.Add($icon); [void]$grid.Children.Add($label)
    $border.Child = $grid
    [void]$ui.ToastHost.Children.Add($border)
    [void]$script:Toasts.Add(@{ Element = $border; Expires = (Get-Date).AddSeconds($(if ($Kind -in 'bad', 'warn') { 12 } else { 6 })); Text = $Text; Kind = $Kind })
    while ($ui.ToastHost.Children.Count -gt 4) { [void]$script:Toasts.RemoveAt(0); $ui.ToastHost.Children.RemoveAt(0) }
}
function Update-Toasts {
    foreach ($toast in @($script:Toasts)) {
        if ($toast.Expires -lt (Get-Date)) { $ui.ToastHost.Children.Remove($toast.Element); $script:Toasts.Remove($toast) }
    }
}

function Show-Error([string]$Message) {
    Write-UiLog $Message 'Error'
    Show-Toast $Message 'bad'
    if ($env:INTUNECHOCO_SMOKE) { return }   # tests: no dialogs on the desktop
    [void][System.Windows.MessageBox]::Show($window, $Message, 'Intune Choco Deployment', 'OK', 'Error')
}

function Confirm-Action([string]$Message, [string]$Title = 'Intune Choco Deployment') {
    if ($env:INTUNECHOCO_SMOKE) { return $true }
    return ([System.Windows.MessageBox]::Show($window, $Message, $Title, 'YesNo', 'Question') -eq 'Yes')
}

$script:ClickActions = @{}
function Add-Click {
    # Click handler with error handling: an exception shows a message instead of killing the window.
    # Actions are looked up by sender (no GetNewClosure: that would hide this script's functions and variables).
    param($Control, [scriptblock]$Action)
    $script:ClickActions[$Control] = $Action
    $Control.Add_Click({
        param($src)
        try { & $script:ClickActions[$src] } catch { Show-Error $_.Exception.Message }
    })
}


# ---------------------------------------------------------------- background tasks
# Shared with the task runspaces: the sign-in and the package infos from the feed
$script:Shared = [hashtable]::Synchronized(@{
    Auth         = $null
    Meta         = [hashtable]::Synchronized(@{})
    CancelSignIn = $false
})
# Deployments and tenant changes one after another; what the user starts (sign-in, search, module installation)
# next to them; feed lookups and icon rendering on their own pool, so they never hold up a click
$script:WorkPool = [runspacefactory]::CreateRunspacePool(1, 1)
$script:WorkPool.Open()
$script:UserPool = [runspacefactory]::CreateRunspacePool(1, 3)
$script:UserPool.Open()
$script:MetaPool = [runspacefactory]::CreateRunspacePool(1, 3)
$script:MetaPool.Open()
# A sandbox test waits until you report its result (Windows Sandbox runs one at a time): it must not hold up anything else
$script:TestPool = [runspacefactory]::CreateRunspacePool(1, 1)
$script:TestPool.Open()
$script:Tasks = New-Object System.Collections.ArrayList
$script:TaskCounter = 0
$script:MetaDirty = $false
$script:MetaCachePath = Join-Path $script:WorkRoot 'feedcache.json'
$script:MetaCacheHours = 24
# Tests only: script text of a fake Graph call (see New-InsightGraphContext -Invoke); empty = the real tenant
$script:InsightFake = ''

# Runs inside a pool runspace: loads the core script, takes over the sign-in, captures every stream into the job log
$script:TaskBody = {
    param($CorePath, $Shared, $Job, $Work, $WorkArguments)
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $Job.Status = 'running'
    $Job.Started = Get-Date
    $Output = New-Object System.Collections.ArrayList
    function Add-JobLog([string]$Level, [string]$Text) {
        if ($Text) { [void]$Job.Log.Add(@{ Level = $Level; Text = $Text; Time = (Get-Date).ToString('HH:mm:ss') }) }
    }
    try {
        . $CorePath
        if ($Shared.Auth) { Set-IntuneChocoAuthState $Shared.Auth }
        $WorkScript = [scriptblock]::Create($Work)
        & $WorkScript @WorkArguments *>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { Add-JobLog 'Error' $_.Exception.Message; $Job.HadError = $true }
            elseif ($_ -is [System.Management.Automation.WarningRecord]) { Add-JobLog 'Warning' $_.Message }
            elseif ($_ -is [System.Management.Automation.InformationRecord]) { Add-JobLog 'Info' ([string]$_.MessageData) }
            elseif ($_ -is [System.Management.Automation.VerboseRecord] -or $_ -is [System.Management.Automation.DebugRecord]) { }
            else { [void]$Output.Add($_) }
        }
        # A token refreshed during a long run is handed back to everyone else
        if ($Shared.Auth -and $Global:AccessToken) { $Shared.Auth = Get-IntuneChocoAuthState }
    }
    catch {
        Add-JobLog 'Error' $_.Exception.Message
        $Job.HadError = $true
    }
    $Job.Result = @($Output)
    $Job.Finished = Get-Date
    if ($Job.HadError) { $Job.Status = 'failed' }
    elseif ($Job.Kind -eq 'deploy' -and $Output.Count -eq 0) { $Job.Status = 'skipped' }
    else { $Job.Status = 'succeeded' }
}.ToString()

$script:JobRows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.LstJobs.ItemsSource = $script:JobRows
$script:JobNouns = @{ deploy = 'Deployment'; policy = 'Update settings'; release = 'Release'; remove = 'Removal'; test = 'Sandbox test'; components = 'Components'
    chocolatey = 'Dependency apps'; appreg = 'App registration'; connect = 'Sign-in'; runtime = 'Dependency'; takeover = 'Import'; statusscript = 'Status report'; export = 'Export' }

function Start-UiTask {
    <#
    Runs $Work (text, with the core script loaded) in a background runspace. $OnDone gets ($Result, $Job) on the
    UI thread when it finishes. Tasks on the same pool queue up and run one after another. Tasks that are not Hidden
    show up in the activity list (-Display = the name shown there); a failed one can be started again with Retry.
    #>
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Work,
        [hashtable]$Arguments = @{},
        [string]$Package,
        [string]$Display,
        [scriptblock]$OnDone,
        [switch]$NeedsAuth,
        [switch]$Hidden,
        $Pool = $script:WorkPool
    )
    if ($NeedsAuth -and -not $script:Shared.Auth) { throw 'Sign in to Intune first (Sign in, top right).' }
    $spec = @{}
    foreach ($key in $PSBoundParameters.Keys) { $spec[$key] = $PSBoundParameters[$key] }
    $script:TaskCounter++
    $job = [hashtable]::Synchronized(@{
        Id       = $script:TaskCounter
        Kind     = $Kind
        Title    = $Title
        Display  = $(if ($Display) { $Display } elseif ($Package) { $Package } else { $Title })
        Package  = $Package
        Source   = $Arguments['Source']
        Status   = 'queued'
        HadError = $false
        Log      = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        Result   = $null
        Spec     = $spec
        Queued   = (Get-Date)
        Started  = $null
        Finished = $null
        LogOpen  = $false
        Row      = $null
    })
    # Work is passed as text: script blocks are bound to the runspace that created them
    $ps = [powershell]::Create()
    $ps.RunspacePool = $Pool
    [void]$ps.AddScript($script:TaskBody).AddArgument($script:CorePath).AddArgument($script:Shared).AddArgument($job).AddArgument($Work).AddArgument($Arguments)
    $task = @{ Job = $job; PS = $ps; Handle = $ps.BeginInvoke(); OnDone = $OnDone; Hidden = [bool]$Hidden }
    [void]$script:Tasks.Add($task)
    if (-not $Hidden) {
        $job.Row = New-Row (@{ Data = $job; Title = $job.Display } + (Get-TileStyle $job.Display))
        $script:JobRows.Insert(0, $job.Row)
        Update-JobRow $job
        Write-UiLog "$Title ..."
    }
    Update-Busy
    return $job
}

function Update-JobRow($Job) {
    # The row of the activity list follows the job: status pill, progress, last message, log text
    $row = $Job.Row
    if (-not $row) { return }
    $noun = $script:JobNouns[$Job.Kind]; if (-not $noun) { $noun = 'Task' }
    $entries = @($Job.Log.ToArray())
    $last = if ($entries.Count) { [string]$entries[-1].Text } else { '' }
    $status = [string]$Job.Status
    $pillName, $label = switch ($status) {
        'queued' { 'gray', 'Waiting' } 'running' { 'info', 'Running' } 'succeeded' { 'ok', 'Done' } 'skipped' { 'gray', 'Skipped' } default { 'bad', 'Failed' }
    }
    $took = if ($Job.Started -and $Job.Finished) { $span = $Job.Finished - $Job.Started; if ($span.TotalMinutes -ge 1) { '{0} min {1} s' -f [int][math]::Floor($span.TotalMinutes), $span.Seconds } else { '{0} s' -f [int]$span.TotalSeconds } } else { $null }
    $errors = @($entries | Where-Object Level -eq 'Error')
    $sub = switch ($status) {
        'queued' { "$noun $([char]0x00B7) waiting" }
        'running' { "$noun $([char]0x00B7) $(if ($last) { $last } else { 'starting' })" }
        'failed' { if ($errors.Count) { [string]$errors[-1].Text } else { "$noun failed" } }
        'skipped' { if ($last) { $last } else { "$noun skipped" } }
        default { "$noun $([char]0x00B7) $took$(if ($last) { ' ' + [char]0x00B7 + ' ' + $last })" }
    }
    $progress = switch ($status) { 'running' { [math]::Min(95, [math]::Max(8, [int]($entries.Count * 100 / 9))) } 'queued' { 0 } default { 100 } }
    $logText = (@($entries | ForEach-Object { '{0}  {1}' -f $_.Time, $_.Text }) -join "`n")
    $open = [bool]$Job.LogOpen -and $entries.Count -gt 0
    Set-Row $row @{
        Sub = $sub; SubFg = $(if ($status -eq 'failed') { '#A11D1D' } else { '#5F5F5F' }); Status = $label
        StatusBg = $script:PillColors[$pillName][0]; StatusFg = $script:PillColors[$pillName][1]
        Progress = $progress; ProgressVis = (ConvertTo-Vis ($status -in 'queued', 'running'))
        Log = $logText; LogVis = (ConvertTo-Vis $open); LogToggle = $(if ($entries.Count) { if ($open) { 'Hide log' } else { 'Show log' } } else { '' })
        RetryVis = (ConvertTo-Vis ($status -eq 'failed' -and $Job.Spec -and $Job.Kind -ne 'test'))
    }
}

function Test-TaskRunning([string]$Kind) { @($script:Tasks | Where-Object { $_.Job.Kind -eq $Kind }).Count -gt 0 }

function Complete-UiTask($Task) {
    $job = $Task.Job
    try { [void]$Task.PS.EndInvoke($Task.Handle) }
    catch { $job.Log.Add(@{ Level = 'Error'; Text = $_.Exception.Message; Time = (Get-Date).ToString('HH:mm:ss') }) | Out-Null; $job.Status = 'failed'; $job.HadError = $true }
    $Task.PS.Dispose()
    $script:Tasks.Remove($Task)
    if (-not $job.Finished) { $job.Finished = Get-Date }
    Update-JobRow $job
    # The task may have renewed the token: the UI thread uses the same sign-in
    if ($script:Shared.Auth) { Set-IntuneChocoAuthState $script:Shared.Auth }
    $errors = @($job.Log.ToArray() | Where-Object Level -eq 'Error')
    foreach ($entry in @($job.Log.ToArray())) { Write-UiLog ("[{0}] {1}" -f $job.Display, $entry.Text) $entry.Level }
    if ($job.Status -eq 'failed' -and $job.Kind -notin 'meta', 'icons') {
        Show-Toast ("{0}: {1}" -f $job.Display, $(if ($errors.Count) { $errors[-1].Text } else { 'failed' })) 'bad'
    }
    if ($Task.OnDone) {
        try { & $Task.OnDone $job.Result $job } catch { Show-Error $_.Exception.Message }
    }
    Update-Busy
}

function Update-Busy {
    $running = @($script:Tasks | Where-Object { -not $_.Hidden -and $_.Job.Status -in 'queued', 'running' })
    $ui.TxtBadgeActivity.Text = [string]$running.Count
    $ui.BadgeActivity.Visibility = ConvertTo-Vis ($running.Count -gt 0)
    $ui.BtnInstallModule.IsEnabled = -not (Test-TaskRunning 'components')
    Update-SignInButton
    Update-SelectionBar
    Update-TenantButtons
    # The readiness items show running steps ("Installing ...") instead of their button
    if ($script:CurrentPage -eq 'Start' -and ($running.Count -or $running.Count -ne $script:LastVisibleTasks)) { Update-Readiness }
    $script:LastVisibleTasks = $running.Count
}
$script:LastVisibleTasks = 0

function Update-SignInButton {
    # While the browser sign-in waits, the button cancels it; only the button that applies is enabled
    $connecting = (Test-TaskRunning 'connect') -or (Test-TaskRunning 'appreg')
    $signedIn = [bool]$script:Shared.Auth
    $ui.BtnSignIn.Content = if ($connecting) { 'Cancel sign-in' } else { 'Sign in' }
    $ui.BtnSignIn.IsEnabled = $connecting -or -not $signedIn
    $ui.BtnSignInMenu.IsEnabled = -not $connecting -and -not $signedIn
    $ui.BtnStartSignInBrowser.IsEnabled = -not $connecting -and -not $signedIn
    $ui.BtnStartSignInKeevault.IsEnabled = -not $connecting -and -not $signedIn
    $ui.PanelSignedOut.Visibility = ConvertTo-Vis (-not $signedIn)
    $ui.BtnAccount.Visibility = ConvertTo-Vis $signedIn
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:Tick = 0
$timer.Add_Tick({
    try {
        $script:Tick++
        foreach ($task in @($script:Tasks)) {
            if ($task.Handle.IsCompleted) { Complete-UiTask $task } else { Update-JobRow $task.Job }
        }
        Update-Toasts
        # App cards fill up while the feed lookups run
        if ($script:MetaRefreshPending -and $script:Tick % 4 -eq 0) {
            $script:MetaRefreshPending = $false
            if ($script:CurrentPage -eq 'Apps') { Update-AppList }
            if (-not (Test-TaskRunning 'meta')) { Complete-MetaPrefetch }
        }
        if ($script:Tick % 240 -eq 0 -and $script:Shared.Auth) { Update-ConnectionStatus }
    }
    catch { Write-UiLog $_.Exception.Message 'Error' }
})

# ---------------------------------------------------------------- package infos (feed cache, 24 hours)
if (Test-Path $script:MetaCachePath) {
    try {
        $cache = Get-Content -Path $script:MetaCachePath -Raw | ConvertFrom-Json
        foreach ($property in $cache.PSObject.Properties) {
            if (([datetime]$property.Value.Fetched) -gt (Get-Date).AddHours(-$script:MetaCacheHours)) { $script:Shared.Meta[$property.Name] = $property.Value }
        }
    }
    catch { }
}

function Save-MetaCache {
    if (-not $script:MetaDirty) { return }
    try {
        $copy = @{}
        # A lookup that failed (offline, rate limit) is not remembered, only a real "not found"
        foreach ($key in @($script:Shared.Meta.Keys)) { $entry = $script:Shared.Meta[$key]; if ($entry.Found -or $entry.NotFound) { $copy[$key] = $entry } }
        New-Item -Path $script:WorkRoot -ItemType Directory -Force | Out-Null
        $copy | ConvertTo-Json -Depth 4 | Set-Content -Path $script:MetaCachePath -Encoding UTF8
        $script:MetaDirty = $false
    }
    catch { Write-UiLog "Feed cache could not be saved: $($_.Exception.Message)" 'Warning' }
}

# ---------------------------------------------------------------- icon previews
# WPF shows PNG, JPEG and ICO directly, but most Chocolatey icons are SVG: they are rendered once with headless Edge
# (the same conversion the deployment uses) into a PNG per icon URL and kept in the work folder.
$script:IconCacheDir = Join-Path $script:WorkRoot 'iconcache'
$script:IconsQueued = @{}

function Get-IconCacheFile([string]$Url) {
    $sha = [Security.Cryptography.SHA1]::Create()
    $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Url)) | ForEach-Object { $_.ToString('x2') })
    Join-Path $script:IconCacheDir "$hash.png"
}

function Get-IconPreview([string]$Url) {
    # What the grid can show for an icon URL: the URL itself, a rendered PNG, or nothing (yet)
    # Plain strings only: WPF's image converter fails on a PSObject-wrapped string (as Join-Path returns it)
    if (-not $Url -or $Url -notmatch '^https?://') { return $null }
    if ($Url -notmatch '\.svg(\?|#|$)') { return [string]$Url }
    $file = [string](Get-IconCacheFile $Url)
    if (Test-Path $file) { return $file }
    return $null
}

$script:IconWork = @'
param($Items, $CacheDir)
New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
$work = Join-Path $CacheDir 'render'
foreach ($item in $Items) {
    try {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $download = Join-Path $work 'icon.svg'
        Invoke-WebRequest -Uri $item.Url -OutFile $download -UseBasicParsing -TimeoutSec 30
        $png = ConvertTo-PngBytes -Bytes ([IO.File]::ReadAllBytes($download)) -WorkPath $work
        [IO.File]::WriteAllBytes($item.File, $png)
    }
    catch {
        # Hidden task: failures go to a log in the cache folder (the package simply shows no icon in the list)
        Add-Content -Path (Join-Path $CacheDir 'failed.log') -Value ('{0:s}  {1}  {2}' -f (Get-Date), $item.Url, $_.Exception.Message)
    }
    finally { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
}
'@

function Start-IconRender {
    # One background task renders the missing SVG icons of all known packages, one after another
    if (@($script:Tasks | Where-Object { $_.Job.Kind -eq 'icons' }).Count -gt 0) { return }
    $items = foreach ($key in @($script:Shared.Meta.Keys)) {
        $url = [string]$script:Shared.Meta[$key].IconUrl
        if ($url -notmatch '^https?://.*\.svg(\?|#|$)' -or $script:IconsQueued.ContainsKey($url)) { continue }
        $file = Get-IconCacheFile $url
        if (Test-Path $file) { continue }
        $script:IconsQueued[$url] = $true
        @{ Url = $url; File = $file }
    }
    $items = @($items)
    if ($items.Count -eq 0) { return }
    [void](Start-UiTask -Kind 'icons' -Title 'Rendering SVG icons' -Work $script:IconWork -Arguments @{ Items = $items; CacheDir = $script:IconCacheDir } -Pool $script:MetaPool -Hidden -OnDone {
        if ($script:CurrentPage -eq 'Apps') { Update-AppList }
        Update-DetailIcon
        Start-IconRender   # packages that came in meanwhile
    })
}

# Package infos of both sources live in one cache: Chocolatey under the id, winget under "winget:<id>" (all lower case)
function Get-MetaKey([string]$Id, [string]$Source = 'Chocolatey') { Get-SourceCacheKey $Source $Id }

$script:MetaWork = @'
param($Items)
foreach ($Item in $Items) {
    $Id = $Item.Id; $Source = $Item.Source
    $Key = Get-SourceCacheKey $Source $Id
    try {
        $Info = if ($Source -eq 'Winget') { Get-WingetInfo -WingetId $Id } else { Get-ChocoInfo -ChocoName $Id }
        $Shared.Meta[$Key] = [pscustomobject]@{
            Fetched = (Get-Date).ToString('o'); Found = $true; Name = $Info.Name; Title = $Info.Title; Version = $Info.Version
            Summary = $Info.Summary; Description = $Info.Description; Authors = $Info.Authors; IconUrl = $Info.IconUrl
            ProjectUrl = $Info.SoftwareSite; LicenseUrl = $Info.SoftwareLicense; Downloads = $Info.Downloads; LicenseNote = $Info.LicenseNote
            License = $Info.License; Partial = $false
        }
    }
    catch {
        # "Not found" is an answer of the source; anything else (offline, rate limit) is tried again next time
        $Shared.Meta[$Key] = [pscustomobject]@{
            Fetched = (Get-Date).ToString('o'); Found = $false; NotFound = ($_.Exception.Message -like '*was not found*'); Name = $Id; Error = $_.Exception.Message
        }
    }
}
'@

function Test-MetaMissing([string]$Id, [string]$Source = 'Chocolatey') {
    $entry = $script:Shared.Meta[(Get-MetaKey $Id $Source)]
    return (-not $entry -or $entry.Partial -or (-not $entry.Found -and -not $entry.NotFound))
}

$script:MetaInFlight = @{}
$script:MetaRefreshPending = $false
function Start-MetaPrefetch {
    # Items: @{ Source = 'Chocolatey' | 'Winget'; Id = ... }. Reads what is not cached yet, three lookups in parallel.
    param([object[]]$Items, [switch]$Force)
    $missing = @($Items | Where-Object {
        $_ -and $_.Id -and -not $script:MetaInFlight.ContainsKey((Get-MetaKey $_.Id $_.Source)) -and ($_.Source -ne 'Winget' -or $script:ModuleState.Winget) -and ($Force -or (Test-MetaMissing $_.Id $_.Source))
    })
    if ($missing.Count -eq 0) { return }
    $script:MetaDirty = $true
    foreach ($item in $missing) { $script:MetaInFlight[(Get-MetaKey $item.Id $item.Source)] = $true }
    for ($i = 0; $i -lt 3; $i++) {
        $chunk = @(for ($j = $i; $j -lt $missing.Count; $j += 3) { @{ Source = $missing[$j].Source; Id = $missing[$j].Id } })
        if ($chunk.Count -gt 0) {
            [void](Start-UiTask -Kind 'meta' -Title 'Reading package infos' -Work $script:MetaWork -Arguments @{ Items = $chunk } -Pool $script:MetaPool -Hidden -OnDone {
                param($Result, $Job)
                foreach ($item in $Job.Spec.Arguments.Items) { $script:MetaInFlight.Remove((Get-MetaKey $item.Id $item.Source)) }
                $script:MetaRefreshPending = $true
            })
        }
    }
    Write-UiLog "Reading infos for $($missing.Count) packages from the Chocolatey feed and the winget source ..."
}

function Complete-MetaPrefetch {
    # All lookups are done: show the result, remember it, and say so when a source could not be reached
    Update-CatalogRows
    Update-AppList
    Update-TenantRows
    Update-DetailIcon
    Save-MetaCache
    $failed = @($script:Shared.Meta.Values | Where-Object { -not $_.Found -and -not $_.NotFound })
    if ($failed.Count -gt 0 -and -not $script:MetaWarned) {
        $script:MetaWarned = $true
        Write-UiLog "Infos for $($failed.Count) package(s) could not be read ($($failed[0].Error)). Refresh in the Apps list tries again." 'Warning'
    }
    Start-IconRender
}
$script:MetaWarned = $false


# ---------------------------------------------------------------- module and connection state
function Get-ModuleState {
    $module = Get-Module -ListAvailable IntuneWin32App | Sort-Object Version -Descending | Select-Object -First 1
    $winget = Get-Module -ListAvailable Microsoft.WinGet.Client | Sort-Object Version -Descending | Select-Object -First 1
    [pscustomobject]@{
        Version       = $(if ($module) { $module.Version.ToString() } else { $null })
        Ok            = ($null -ne $module -and $module.Version -ge $script:MinimumModuleVersion)
        Winget        = ($null -ne $winget)
        WingetVersion = $(if ($winget) { $winget.Version.ToString() } else { $null })
    }
}

function Update-ModuleState {
    $script:ModuleState = Get-ModuleState
    $m = $script:ModuleState
    $intune = if ($m.Ok) { "IntuneWin32App $($m.Version) is installed (minimum $($script:MinimumModuleVersion)). It packages the .intunewin files and talks to Microsoft Graph." }
              elseif ($m.Version) { "IntuneWin32App $($m.Version) is installed, but $($script:MinimumModuleVersion) or newer is required: older versions break packaging and dependencies." }
              else { "The IntuneWin32App module is not installed." }
    $wingetText = if ($m.Winget) { "Microsoft.WinGet.Client $($m.WingetVersion) is installed (winget package infos and search)." }
                  else { "Microsoft.WinGet.Client is not installed; it is needed for winget packages only." }
    $ui.TxtModuleInfo.Text = "$intune`n$wingetText`nBoth are installed for the current user from the PowerShell Gallery (no admin rights needed)."
}

function Test-SignedIn { [bool]$script:Shared.Auth }

function Get-AccountInfo {
    $identity = if (Test-SignedIn) { Get-IntuneChocoIdentity } else { $null }
    if (-not $identity) { return $null }
    $name = if ($identity.Name) { [string]$identity.Name } elseif ($identity.Account) { [string]$identity.Account } else { 'Intune administrator' }
    $initials = (@($name -split '[\s@.]+' | Where-Object { $_ } | Select-Object -First 2 | ForEach-Object { $_.Substring(0, 1).ToUpper() }) -join '')
    [pscustomobject]@{ Name = $name; Account = [string]$identity.Account; Initials = $initials; Tenant = $(if ($script:Settings.TenantID) { $script:Settings.TenantID } else { [string]$identity.TenantId }); ExpiresOn = $identity.ExpiresOn }
}

function Update-ConnectionStatus {
    $info = Get-AccountInfo
    if ($info) {
        $ui.TxtInitials.Text = $info.Initials
        $ui.TxtAccountName.Text = $info.Name
        $ui.TxtAccountTenant.Text = $info.Tenant
        $ui.BtnAccount.ToolTip = "$($info.Account), $($info.Tenant)"
        $script:AccountText = "$($info.Name) $($info.Account) $($info.Tenant)"
    }
    else { $script:AccountText = '' }
    Update-SignInButton
    $ui.BtnTenantRefresh.IsEnabled = (Test-SignedIn)
    Update-SelectionBar
    Update-Readiness
}
$script:AccountText = ''

# ---------------------------------------------------------------- navigation, dialogs, help
$script:Pages = @('Start', 'Apps', 'Tenant', 'Status', 'Activity', 'Settings')
$script:CurrentPage = 'Start'
function Show-Page([string]$Name) {
    Close-Dialog
    $script:CurrentPage = $Name
    foreach ($p in $script:Pages) { $ui["Page$p"].Visibility = if ($p -eq $Name) { 'Visible' } else { 'Collapsed' } }
    $navName = if ($Name -eq 'Status') { 'Tenant' } else { $Name }
    $ui["Nav$navName"].IsChecked = $true
    switch ($Name) {
        'Start'    { Update-Readiness }
        'Apps'     { Update-CatalogRows; Update-AppList; Start-CatalogPrefetch }
        'Tenant'   { if ((Test-SignedIn) -and $null -eq $script:TenantApps -and -not (Test-TaskRunning 'tenant')) { Start-TenantRefresh } else { Update-TenantRows } }
        'Settings' { Update-SettingsView }
    }
    Update-SelectionBar
}
foreach ($p in 'Start', 'Apps', 'Tenant', 'Activity', 'Settings') {
    $ui["Nav$p"].Add_Checked({
        param($src)
        $name = $src.Name -replace '^Nav', ''
        $current = if ($script:CurrentPage -eq 'Status') { 'Tenant' } else { $script:CurrentPage }
        if ($current -ne $name) { try { Show-Page $name } catch { Show-Error $_.Exception.Message } }
    })
}

function Show-Dialog([string]$Name) {
    foreach ($d in 'DlgDeploy', 'DlgSchedule', 'DlgImport', 'DlgHelp') { $ui[$d].Visibility = if ($d -eq $Name) { 'Visible' } else { 'Collapsed' } }
    $ui.DialogLayer.Visibility = 'Visible'
    $script:OpenDialog = $Name
}
function Close-Dialog {
    $ui.DialogLayer.Visibility = 'Collapsed'
    foreach ($d in 'DlgDeploy', 'DlgSchedule', 'DlgImport', 'DlgHelp') { $ui[$d].Visibility = 'Collapsed' }
    $script:OpenDialog = $null
}
$script:OpenDialog = $null
$window.Add_PreviewKeyDown({ param($s, $e) if ($e.Key -eq 'Escape' -and $script:OpenDialog) { Close-Dialog; $e.Handled = $true } })

$script:HelpTexts = @{
    Start    = @(
        @('What it does', 'Deploys Chocolatey or winget packages as Win32 apps to Microsoft Intune. Every app gets an install script that runs as SYSTEM, a detection rule and an update routine. Chocolatey and winget each get a dependency app in the tenant, created once.'),
        @('Get ready', 'All items should be green before the first deployment. A red item says why and has the button that fixes it. Set up everything runs the fixes one after another: modules, app registration (one sign-in with a Global Administrator, admin consent included), sign-in, dependency apps. The status report is optional.'),
        @('Sign in', 'Microsoft sign-in opens in your browser. The arrow next to Sign in offers the sign-in with an account from Keevault: you pick the account there, user name, password and one-time code are filled in, the passkey is confirmed in Keevault.'),
        @('Requirements', 'The IntuneWin32App module 1.5.0 or newer and an Entra ID app registration with redirect URI http://localhost. Chocolatey and winget are not needed on this computer.'))
    Apps     = @(
        @('One list', 'Chocolatey and winget packages in one list. Each card shows the version of every source and marks the source with the newer version as recommended. Type to filter, or search both repositories for apps that are not in the list.'),
        @('Sources', 'All sources shows everything, winget and Chocolatey the apps that only that source has, Both the apps that are available from both. Install with sets the source for apps without a recommendation; you can change it per app when you review.'),
        @('Deploy', 'Select apps, then Review and deploy: choose the source per app, the version, the assignment and how devices update. Deployments run one after another under Activity.'),
        @('Test in sandbox', 'The details panel tests one app in a fresh Windows Sandbox before it goes to Intune. Needs MSIX Sandbox Studio and Windows Sandbox, no sign-in.'),
        @('License notes', 'Apps whose license restricts business use carry a Check license note. They are deployed only after a confirmation; the license is still yours to clear.'))
    Tenant   = @(
        @('In tenant', 'The apps this tool created in the tenant, from both sources, with the two dependency apps. Everything is read from Intune; there is no local database.'),
        @('Update settings', 'Select an app: the panel on the right sets the version and how devices update (off, automatic per schedule, ask the user). Apply in Intune rebuilds the package and changes the app.'),
        @('Release an update', 'A pinned app whose package has a newer version shows a banner. Release moves devices to it. Apps that are only Available are updated through a new app that supersedes the old one; Required apps are changed in place.'),
        @('On devices', 'Click the counts to see the install status per device, with the cause of a failure and the log the device reports through the status script (Remediations).'))
    Activity = @(
        @('Activity', 'Every deployment, release and check that runs in the background. Show log reveals the messages, Retry starts a failed job again, Clear finished removes the done ones. Log files are written per day in the work folder.'))
    Settings = @(
        @('Tenant and app registration', 'The tenant (domain or ID) and the client ID of your app registration. Grant new permissions runs the app registration setup again, which adds missing permissions and the admin consent.'),
        @('Deployment defaults', 'What the deploy dialog starts with: assignment, preferred source, architecture, version and update mode. Schedule and conditions for new apps opens the schedule dialog.'),
        @('Package sources', 'The metadata feed is read on this computer. The package source is what choco uses on the devices (--source); the download URL is where the Chocolatey bootstrap gets its nupkg. Both empty = community repository. Chocolatey rate limits downloads from its community repository; for larger environments put an internal repository or caching proxy in front.'),
        @('Sandbox test', 'The Test buttons use the Win32 Test Lab of MSIX Sandbox Studio (WindowsSandboxMSIXInstaller) and need Windows Sandbox.'))
}
function Show-Help {
    $page = if ($script:CurrentPage -eq 'Status') { 'Tenant' } else { $script:CurrentPage }
    $ui.HelpTitle.Text = "Help: $page"
    $ui.HelpBody.Children.Clear()
    foreach ($entry in $script:HelpTexts[$page]) {
        $l = New-Object System.Windows.Controls.TextBlock; $l.Text = $entry[0]; $l.FontWeight = 'SemiBold'; $l.Margin = '0,12,0,3'
        $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $entry[1]; $t.TextWrapping = 'Wrap'; $t.Foreground = Get-Brush 'Text2'
        [void]$ui.HelpBody.Children.Add($l); [void]$ui.HelpBody.Children.Add($t)
    }
    Show-Dialog 'DlgHelp'
}
Add-Click $ui.NavHelp { Show-Help }
Add-Click $ui.BtnHelpClose { Close-Dialog }

# ---------------------------------------------------------------- start page: readiness
$script:ReadinessActions = @{}
$script:RuntimeId = $null          # winget runtime app: $null = not read yet, '' = not in the tenant
$script:StatusScript = $null       # @{ State = 'Present' | 'Missing' | 'NotAvailable'; Id; Reason }

function New-ReadinessCard {
    param([int]$Number, [string]$Title, [ValidateSet('ok', 'warn', 'bad')][string]$State, [string]$Text, [string]$ActionText, [scriptblock]$Action, [bool]$Last)
    # One row: state dot | title and text | action button
    $border = New-Object System.Windows.Controls.Border
    $border.Padding = '16,14'; $border.BorderBrush = Get-Brush 'Divider'; $border.BorderThickness = $(if ($Last) { '0' } else { '0,0,0,1' })
    $grid = New-Object System.Windows.Controls.Grid
    foreach ($w in 'Auto', '*', 'Auto') {
        $c = New-Object System.Windows.Controls.ColumnDefinition
        $c.Width = if ($w -eq '*') { [System.Windows.GridLength]::new(1, 'Star') } else { [System.Windows.GridLength]::Auto }
        [void]$grid.ColumnDefinitions.Add($c)
    }
    $dot = New-Object System.Windows.Controls.Border
    $dot.Width = 26; $dot.Height = 26; $dot.CornerRadius = 13; $dot.Margin = '0,0,14,0'; $dot.VerticalAlignment = 'Center'
    $mark = New-Object System.Windows.Controls.TextBlock
    $mark.HorizontalAlignment = 'Center'; $mark.VerticalAlignment = 'Center'; $mark.FontWeight = 'Bold'; $mark.FontSize = 13
    switch ($State) {
        'ok'   { $dot.Background = Get-Brush 'SuccessBg'; $mark.Foreground = Get-Brush 'Success'; $mark.Text = [string][char]0x2713 }
        'warn' { $dot.Background = Get-Brush 'WarningBg'; $mark.Foreground = Get-Brush 'Warning'; $mark.Text = '!' }
        default { $dot.Background = Get-Brush 'Card'; $dot.BorderBrush = ConvertTo-Brush '#8A8A8A'; $dot.BorderThickness = 1.5; $mark.Foreground = Get-Brush 'MutedText'; $mark.Text = [string]$Number }
    }
    $dot.Child = $mark
    [void]$grid.Children.Add($dot)
    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.VerticalAlignment = 'Center'
    $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $Title; $t.FontWeight = 'SemiBold'
    $s = New-Object System.Windows.Controls.TextBlock; $s.Text = $Text; $s.Style = $window.FindResource('Hint'); $s.FontSize = 13
    [void]$stack.Children.Add($t); [void]$stack.Children.Add($s)
    [System.Windows.Controls.Grid]::SetColumn($stack, 1)
    [void]$grid.Children.Add($stack)
    if ($ActionText -and $Action) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $ActionText; $b.Margin = '12,0,0,0'; $b.Padding = '14,6'; $b.VerticalAlignment = 'Center'
        $b.SetValue([System.Windows.Automation.AutomationProperties]::NameProperty, "${ActionText}: $Title")
        $script:ReadinessActions[$b] = $Action
        $b.Add_Click({ param($src) try { & $script:ReadinessActions[$src] } catch { Show-Error $_.Exception.Message } })
        [System.Windows.Controls.Grid]::SetColumn($b, 2)
        [void]$grid.Children.Add($b)
    }
    $border.Child = $grid
    $border
}

function Get-MissingScopes {
    # Insight permissions the sign-in does not carry yet (Test-InsightReadiness); empty while signed out
    if (-not (Test-SignedIn) -or -not $Global:AccessToken -or -not $Global:AccessToken.Scopes) { return @() }
    @(Test-InsightReadiness -GrantedScopes @($Global:AccessToken.Scopes) | Where-Object { -not $_.Ready } | ForEach-Object { $_.Missing } | Select-Object -Unique)
}

function Get-ReadinessItems {
    <#
    Everything the tool needs, in the order it is set up. Each item: state, the reason when it is not ok, and the fix
    (Key names the step for "Set up everything"; Wait = a task for it is running; Optional = not part of the setup).
    #>
    $m = $script:ModuleState
    $busyModules = Test-TaskRunning 'components'
    $busyAppReg = Test-TaskRunning 'appreg'
    $busyConnect = Test-TaskRunning 'connect'
    $busyDeps = Test-TaskRunning 'chocolatey'
    $moduleOk = $m.Ok -and $m.Winget
    $items = @(
        $(if ($moduleOk) { @{ Key = 'module'; Title = 'IntuneWin32App module'; State = 'ok'; Text = "Version $($m.Version) installed, with the winget client module." } }
          else { @{ Key = 'module'; Title = 'IntuneWin32App module'; State = 'bad'; Wait = $busyModules
                    Text = $(if ($busyModules) { 'Installing from the PowerShell Gallery ...' } elseif ($m.Version -and -not $m.Ok) { "Version $($m.Version) is installed, but $($script:MinimumModuleVersion) or newer is needed." } elseif (-not $m.Version) { 'Not installed. It packages the apps and talks to Intune; installed for your user, no admin rights needed.' } else { 'The winget client module is missing; winget package infos and search need it.' })
                    Fix = 'Install'; Action = { Start-ModuleInstall } } })
        $(if ($script:Settings.TenantID -and $script:Settings.ClientID) {
              $missing = @(Get-MissingScopes)
              if ($missing.Count) { @{ Key = 'appreg'; Title = 'App registration'; State = 'warn'; Wait = $busyAppReg
                    Text = $(if ($busyAppReg) { 'Waiting for the administrator sign-in in your browser ...' } else { "New permissions are needed for the status views ($($missing -join ', ')). Grant them with an administrator sign-in, then sign in again." })
                    Fix = 'Grant new permissions'; Action = { Start-AppRegistration } } }
              else { @{ Key = 'appreg'; Title = 'App registration'; State = 'ok'; Text = "$($script:Settings.TenantID), client ID $($script:Settings.ClientID)." } } }
          else { @{ Key = 'appreg'; Title = 'App registration'; State = 'bad'; Wait = $busyAppReg
                    Text = $(if ($busyAppReg) { 'Waiting for the administrator sign-in in your browser ...' } elseif (-not $script:Settings.ClientID) { "$(if ($script:Settings.TenantID) { $script:Settings.TenantID } else { 'This tenant' }) has no app registration yet. Created with admin consent." } else { 'The tenant is missing (Settings).' })
                    Fix = $(if ($script:Settings.ClientID) { 'Settings' } else { 'Create' }); Action = $(if ($script:Settings.ClientID) { { Show-Page 'Settings' } } else { { Start-AppRegistration } }) } })
        $(if (Test-SignedIn) { @{ Key = 'signin'; Title = 'Signed in to Intune'; State = 'ok'; Text = $(if ($script:AccountText) { "Signed in as $((Get-AccountInfo).Account)" } else { 'Signed in' }) } }
          else { @{ Key = 'signin'; Title = 'Signed in to Intune'; State = 'bad'; Wait = $busyConnect
                    Text = $(if ($busyConnect) { 'Waiting for the sign-in in your browser ...' } else { 'Not signed in' })
                    Fix = 'Sign in'; Action = { Connect-Intune } } })
    )
    $depsText = 'Chocolatey and winget runtime, created once per tenant, so every app finds its installer'
    $items += $(if (-not (Test-SignedIn)) { @{ Key = 'deps'; Title = 'Dependency apps in Intune'; State = 'warn'; Text = $depsText } }
                elseif ($null -eq $script:TenantApps -or $null -eq $script:RuntimeId) {
                    $reading = (Test-TaskRunning 'tenant') -or (Test-TaskRunning 'deps')
                    @{ Key = 'tenant'; Title = 'Dependency apps in Intune'; State = 'warn'; Wait = $reading
                       Text = $(if ($reading) { 'Reading the apps in the tenant ...' } else { 'The apps in the tenant could not be read yet.' }); Fix = 'Check'; Action = { Start-TenantRefresh } } }
                else {
                    $haveChoco = @($script:TenantApps | Where-Object IsChocolatey).Count -gt 0
                    $haveRuntime = [bool]$script:RuntimeId
                    if ($haveChoco -and $haveRuntime) { @{ Key = 'deps'; Title = 'Dependency apps in Intune'; State = 'ok'; Text = 'Chocolatey and the winget runtime are in the tenant.' } }
                    else { @{ Key = 'deps'; Title = 'Dependency apps in Intune'; State = 'bad'; Wait = $busyDeps
                              Text = $(if ($busyDeps) { 'Deploying the dependency apps to Intune ...' } else { "Missing: $(@($(if (-not $haveChoco) { 'Chocolatey' }), $(if (-not $haveRuntime) { 'winget runtime' }) | Where-Object { $_ }) -join ', '). $depsText." })
                              Fix = 'Create'; Action = { Start-DependencyDeploy } } } })
    $items += $(if (-not (Test-SignedIn)) { @{ Key = 'status'; Title = 'Status report (optional)'; State = 'warn'; Optional = $true; Text = 'Devices report their update log to Intune, so failures show up under In tenant. Needs Remediations (Windows Enterprise E3/E5).' } }
                elseif (-not $script:StatusScript) { @{ Key = 'status'; Title = 'Status report (optional)'; State = 'warn'; Optional = $true; Wait = (Test-TaskRunning 'statuscheck'); Text = 'Checking ...' } }
                elseif ($script:StatusScript.State -eq 'Present') { @{ Key = 'status'; Title = 'Status report (optional)'; State = 'ok'; Optional = $true; Text = 'The status script is in Intune; devices report their update log hourly.' } }
                elseif ($script:StatusScript.State -eq 'NotAvailable') { @{ Key = 'status'; Title = 'Status report (optional)'; State = 'warn'; Optional = $true; Text = "Not available in this tenant. The install status still works; the device log needs Remediations. $($script:StatusScript.Reason)" } }
                else { @{ Key = 'status'; Title = 'Status report (optional)'; State = 'warn'; Optional = $true; Wait = (Test-TaskRunning 'statusscript')
                          Text = 'Devices report their update log to Intune, so failures show up with their cause. Needs Remediations (Windows Enterprise E3/E5).'
                          Fix = 'Set up'; Action = { Start-StatusScriptSetup } } })
    $items
}

function Update-Readiness {
    if (-not $ui.ReadinessPanel) { return }
    $ui.ReadinessPanel.Children.Clear()
    $script:ReadinessActions.Clear()
    $items = @(Get-ReadinessItems)
    $n = 0
    foreach ($i in $items) {
        $n++
        $action = if ($i.State -ne 'ok' -and $i.Action -and -not $i.Wait) { $i.Action } else { $null }
        [void]$ui.ReadinessPanel.Children.Add((New-ReadinessCard $n $i.Title $i.State $i.Text $i.Fix $action ($n -eq $items.Count)))
    }
    $open = @($items | Where-Object { $_.State -ne 'ok' -and -not $_.Optional })
    $ui.TxtReadinessSummary.Text = if ($script:SetupRunning) { 'Setting up, step by step ...' }
                                   elseif ($open.Count -eq 0) { 'Everything is set up.' }
                                   else { "$($open.Count) of $(@($items | Where-Object { -not $_.Optional }).Count) not ready: $(($open | ForEach-Object { $_.Title }) -join ', ')." }
    $ui.BtnSetupAll.Visibility = ConvertTo-Vis ($open.Count -gt 0)
    $ui.TxtSetupNote.Visibility = ConvertTo-Vis ($open.Count -gt 0)
    $ui.BtnSetupAll.IsEnabled = -not $script:SetupRunning
}

# ---------------------------------------------------------------- set up everything
# Runs the fixes of the readiness items one after another; each task calls Complete-SetupStep when it is done.
$script:SetupRunning = $false
$script:SetupDone = @{}
function Start-SetupAll {
    $script:SetupRunning = $true
    $script:SetupDone = @{}
    Write-UiLog 'Setting up everything that is not ready yet ...'
    Step-Setup
}
function Stop-Setup([string]$Message, [string]$Level = 'Warning') {
    $script:SetupRunning = $false
    if ($Message) { Write-UiLog $Message $Level; Show-Toast $Message $(if ($Level -eq 'Success') { 'ok' } else { 'warn' }) }
    Update-Readiness
}
function Step-Setup {
    if (-not $script:SetupRunning) { return }
    $items = @(Get-ReadinessItems | Where-Object { -not $_.Optional })
    if (@($items | Where-Object Wait).Count) { Update-Readiness; return }   # a step is still running
    $next = $items | Where-Object { $_.State -ne 'ok' -and $_.Action } | Select-Object -First 1
    if (-not $next) {
        if (@($items | Where-Object { $_.State -ne 'ok' }).Count) { Stop-Setup 'Set up stopped: an item is left that has no automatic fix.' }
        else { Stop-Setup 'Everything is set up.' 'Success' }
        return
    }
    if ($script:SetupDone[$next.Key]) { Stop-Setup "Set up stopped at '$($next.Title)': $($next.Text)"; return }   # tried once, it did not help
    $script:SetupDone[$next.Key] = $true
    try { & $next.Action } catch { Stop-Setup "Set up stopped at '$($next.Title)': $($_.Exception.Message)"; return }
    Update-Readiness
    if (-not @(Get-ReadinessItems | Where-Object Wait).Count) { Step-Setup }   # the fix was immediate
}
function Complete-SetupStep([bool]$Ok, [string]$What) {
    if (-not $script:SetupRunning) { Update-Readiness; return }
    if (-not $Ok) { Stop-Setup "Set up stopped: $What did not work, see the messages under Activity."; return }
    Step-Setup
}
Add-Click $ui.BtnSetupAll { Start-SetupAll }

function Start-AppRegistration {
    if (Test-TaskRunning 'appreg') { return }
    if (Test-TaskRunning 'connect') { throw 'A sign-in is waiting in the browser. Finish or cancel it first.' }
    $script:Shared.CancelSignIn = $false
    $work = @'
param($TenantID, $Authority, $UrlHandler, $GraphUrl)
$Params = @{ ShouldCancel = { $Shared.CancelSignIn } }
if ($TenantID) { $Params.TenantID = $TenantID }
if ($Authority) { $Params.Authority = $Authority }
if ($GraphUrl) { $Params.GraphUrl = $GraphUrl }
if ($UrlHandler) { $Params.UrlHandler = [scriptblock]::Create($UrlHandler) }
New-IntuneChocoAppRegistration @Params
'@
    $arguments = @{ TenantID = $script:Settings.TenantID; Authority = $script:SignInTest.Authority; UrlHandler = $script:SignInTest.UrlHandler; GraphUrl = $script:SignInTest.GraphUrl }
    [void](Start-UiTask -Kind 'appreg' -Title 'Creating the app registration: sign in with an administrator account in your browser and accept the consent' -Display 'App registration' -Pool $script:UserPool -Work $work -Arguments $arguments -OnDone {
        param($Result, $Job)
        $reg = @($Result | Where-Object { $_ -and $_.ClientID }) | Select-Object -First 1
        if ($Job.Status -eq 'succeeded' -and $reg) {
            $s = Get-IntuneChocoSettings; $s.TenantID = $reg.TenantID; $s.ClientID = $reg.ClientID
            [void](Save-IntuneChocoSettings -Settings $s); $script:Settings = Get-IntuneChocoSettings
            Update-SettingsView
            Write-UiLog "App registration ready: tenant $($reg.TenantID), client ID $($reg.ClientID). Saved in the settings." 'Success'
            Show-Toast 'App registration is ready, with admin consent.' 'ok'
            Update-ConnectionStatus
            Complete-SetupStep $true
        }
        else { Update-ConnectionStatus; Complete-SetupStep $false 'creating the app registration' }
    })
    Update-SignInButton
    Update-Readiness
}

function Start-DependencyDeploy {
    # Chocolatey app and winget runtime app, once per tenant (each is created only when it is missing)
    if (Test-TaskRunning 'chocolatey') { return }
    Update-UiToken
    [void](Start-UiTask -Kind 'chocolatey' -Title 'Deploying the dependency apps (Chocolatey, winget runtime) to Intune' -Display 'Dependency apps' -NeedsAuth -Work 'get-ChocoWin32ID | Out-Null; Get-WingetRuntimeWin32ID | Out-Null' -OnDone {
        param($Result, $Job)
        if ($Job.Status -eq 'succeeded') { Write-UiLog 'Chocolatey and the winget runtime are in the tenant.' 'Success'; Show-Toast 'Dependency apps are in the tenant.' 'ok' }
        $script:TenantApps = $null; $script:RuntimeId = $null
        if ($Job.Status -eq 'succeeded') { Start-TenantRefresh } else { Update-Readiness; Complete-SetupStep $false 'deploying the dependency apps' }
    })
    Update-Readiness
}

function Start-StatusScriptSetup {
    if (Test-TaskRunning 'statusscript') { return }
    Update-UiToken
    $work = 'param($Fake) $Ctx = if ($Fake) { New-InsightGraphContext -Invoke ([scriptblock]::Create($Fake)) } else { New-InsightGraphContext }; Set-InsightStatusScript -Context $Ctx'
    [void](Start-UiTask -Kind 'statusscript' -Title 'Setting up the status script (Remediations) in Intune' -Display 'Status report' -NeedsAuth -Arguments @{ Fake = $script:InsightFake } -Work $work -OnDone {
        param($Result, $Job)
        $r = @($Result | Where-Object { $_ -and $null -ne $_.Created }) | Select-Object -First 1
        if ($r -and $r.Created) { Show-Toast "Status report: $($r.Message)." 'ok' } elseif ($r) { Show-Toast $r.Message 'warn' }
        $script:StatusScript = $null
        Start-StatusCheck
        Update-Readiness
    })
    Update-Readiness
}

function Start-StatusCheck {
    # Is the status script there, and does the tenant allow it (hidden)
    if (-not (Test-SignedIn) -or (Test-TaskRunning 'statuscheck') -or $script:StatusScript) { return }
    $work = @'
param($Fake)
$Ctx = if ($Fake) { New-InsightGraphContext -Invoke ([scriptblock]::Create($Fake)) } else { New-InsightGraphContext }
$Avail = Test-InsightRemediationsAvailable -Context $Ctx
$State = if ($Avail.Available) { try { Get-InsightStatusScriptState -Context $Ctx } catch { $null } } else { $null }
[pscustomobject]@{ Available = $Avail.Available; Reason = $Avail.Reason; Id = $(if ($State) { $State.id } else { $null }) }
'@
    [void](Start-UiTask -Kind 'statuscheck' -Title 'Checking the status script' -Hidden -Arguments @{ Fake = $script:InsightFake } -Work $work -OnDone {
        param($Result, $Job)
        $r = @($Result | Where-Object { $_ -and $null -ne $_.Available }) | Select-Object -First 1
        if ($Job.Status -ne 'succeeded' -or -not $r) { $script:StatusScript = @{ State = 'NotAvailable'; Id = $null; Reason = 'It could not be checked.' } }
        else { $script:StatusScript = @{ State = $(if (-not $r.Available) { 'NotAvailable' } elseif ($r.Id) { 'Present' } else { 'Missing' }); Id = $r.Id; Reason = $r.Reason } }
        Update-Readiness
        if ($script:CurrentPage -eq 'Status') { Update-StatusBanner }
    })
}

function Start-DependencyCheck {
    # The winget runtime app is not listed with the tool's apps: look it up on its own (hidden)
    if (-not (Test-SignedIn) -or (Test-TaskRunning 'deps')) { return }
    [void](Start-UiTask -Kind 'deps' -Title 'Checking the winget runtime app' -Hidden -NeedsAuth -Work '$id = Get-WingetRuntimeWin32ID -NoCreate; [pscustomobject]@{ Id = [string]$id }' -OnDone {
        param($Result, $Job)
        $r = @($Result | Where-Object { $_ -and $null -ne $_.Id }) | Select-Object -First 1
        $script:RuntimeId = if ($Job.Status -eq 'succeeded' -and $r) { [string]$r.Id } else { $null }
        Update-TenantRows
        Update-Readiness
        Complete-SetupStep ($Job.Status -eq 'succeeded') 'reading the tenant'
    })
}


# ---------------------------------------------------------------- apps: one list for both sources
$script:Catalog = @(Get-IntuneChocoCatalog)
$script:Preferred = if ($script:Settings.Source -eq 'Winget') { 'Winget' } else { 'Chocolatey' }
$script:Selected = [ordered]@{}      # app key -> source row (Get-IntuneChocoSourceApps)
$script:SourceChoice = @{}           # app key -> 'Chocolatey' | 'Winget' chosen in the deploy dialog
$script:CustomIcons = @{}            # app key -> PNG/JPEG base64
$script:SourceRows = @()             # the curated catalog
$script:SearchRows = @()             # hits of the last repository search
$script:SearchTerm = ''
$script:SourceFilter = 'All'
$script:Category = 'All'
$script:DetailRow = $null
$script:CardRows = @{}
$script:CardKeys = ''
$script:TenantApps = $null
$script:TenantPackages = @{}         # meta key of the apps already in the tenant
$script:RecentDeploys = @{}          # meta key -> time it was created by this window
$script:CardCollection = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.CardList.ItemsSource = $script:CardCollection

function Get-AppKey($Row) {
    if ($Row.CatalogId) { return ([string]$Row.CatalogId).ToLower() }
    if ($Row.ChocoId) { return ('choco:' + $Row.ChocoId).ToLower() }
    return ('winget:' + $Row.WingetId).ToLower()
}
function Get-AppId($Row, [string]$Source) { if ($Source -eq 'Winget') { $Row.WingetId } else { $Row.ChocoId } }
function Get-AppSource($Row, [string]$Prefer = $script:Preferred) {
    if ($script:SourceChoice.ContainsKey((Get-AppKey $Row)) -and $script:SourceChoice[(Get-AppKey $Row)] -in $Row.Sources) { return $script:SourceChoice[(Get-AppKey $Row)] }
    Get-IntuneChocoDefaultSource -Row $Row -Preferred $Prefer
}
function Get-AppMeta($Row, [string]$Source) {
    $id = Get-AppId $Row $Source
    if ($id) { $script:Shared.Meta[(Get-MetaKey $id $Source)] }
}
function Get-SourceLabel([string]$Source) { if ($Source -eq 'Winget') { 'winget' } else { 'Chocolatey' } }

function Update-CatalogRows { $script:SourceRows = @(Get-IntuneChocoSourceApps -Cache $script:Shared.Meta -NoFetch) }

function New-TagRow([string]$Text, [string]$Kind) {
    switch ($Kind) {
        'rec'    { New-Row @{ Text = $Text; Bg = '#005FB8'; Line = '#005FB8'; Fg = '#FFFFFF' } }
        'recsrc' { New-Row @{ Text = $Text; Bg = '#E8F1FB'; Line = '#005FB8'; Fg = '#003E92' } }
        default  { New-Row @{ Text = $Text; Bg = '#FFFFFF'; Line = '#D1D1D1'; Fg = '#3B3B3B' } }
    }
}

function Set-CardRow($Card, $Src) {
    $key = Get-AppKey $Src
    $tags = New-Object System.Collections.ArrayList
    foreach ($source in 'Winget', 'Chocolatey') {
        if ($Src.Sources -notcontains $source) { continue }
        $version = if ($source -eq 'Winget') { $Src.WingetVersion } else { $Src.ChocoVersion }
        $label = if ($source -eq 'Winget') { 'winget' } else { 'Choco' }
        $rec = $Src.RecommendedMarked -and $Src.Recommended -eq $source
        [void]$tags.Add((New-TagRow ("$label $version").Trim() $(if ($rec) { 'recsrc' } else { 'plain' })))
        if ($rec) { [void]$tags.Add((New-TagRow 'Recommended' 'rec')) }
    }
    $inTenant = (@($Src.Sources | Where-Object { $id = Get-AppId $Src $_; $id -and $script:TenantPackages.ContainsKey((Get-MetaKey $id $_)) }).Count -gt 0)
    $note = @($Src.Sources | ForEach-Object { $id = Get-AppId $Src $_; $meta = Get-AppMeta $Src $_; if ($meta -and $meta.LicenseNote) { $meta.LicenseNote } else { Get-ChocoLicenseNote $id } } | Where-Object { $_ }) | Select-Object -First 1
    $badge, $kind = if ($inTenant) { 'In tenant', 'ok' } elseif ($note) { 'Check license', 'warn' } else { '', 'ok' }
    $iconUrl = $null
    foreach ($source in 'Chocolatey', 'Winget') {
        $meta = Get-AppMeta $Src $source
        if (-not $iconUrl -and $meta -and $meta.Found -and $meta.IconUrl) { $p = Get-IconPreview ([string]$meta.IconUrl); if ($p) { $iconUrl = [string]$p } }
    }
    $custom = $script:CustomIcons[$key]
    Set-Row $Card (@{
        Data = $Src; Title = $Src.Name; Items = $tags.ToArray(); Selected = [bool]$script:Selected.Contains($key)
        Badge = $badge; BadgeVis = (ConvertTo-Vis ([bool]$badge)); BadgeBg = $script:PillColors[$kind][0]; BadgeFg = $script:PillColors[$kind][1]
        Icon = $iconUrl; MonoVis = (ConvertTo-Vis (-not $iconUrl)); License = $note; InTenant = $inTenant
    } + (Get-TileStyle $Src.Name))
}

function Update-AppList {
    $rows = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($r in @($script:SourceRows) + @($script:SearchRows)) { $k = Get-AppKey $r; if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; [void]$rows.Add($r) } }
    $rows = @(Select-IntuneChocoSourceApps -Apps @($rows) -Filter $script:SourceFilter)
    $text = $ui.TxtFilter.Text.Trim()
    $searching = $script:SearchTerm -and $script:SearchTerm -eq $text
    $rows = @($rows | Where-Object {
        if (-not $text) { return $true }
        if ($searching -and $script:SearchKeys.ContainsKey((Get-AppKey $_))) { return $true }
        $_.Name -like "*$text*" -or $_.ChocoId -like "*$text*" -or $_.WingetId -like "*$text*"
    })
    Update-Chips $rows
    if ($script:Category -ne 'All') { $rows = @($rows | Where-Object { $_.Category -eq $script:Category }) }
    $cards = foreach ($r in $rows) {
        $k = Get-AppKey $r
        if (-not $script:CardRows.ContainsKey($k)) { $script:CardRows[$k] = New-Object IntuneChoco.Row }
        Set-CardRow $script:CardRows[$k] $r
    }
    $cards = @($cards)
    $keys = ($rows | ForEach-Object { Get-AppKey $_ }) -join '|'
    if ($keys -ne $script:CardKeys) {
        $script:CardKeys = $keys
        $script:CardCollection.Clear()
        foreach ($c in $cards) { $script:CardCollection.Add($c) }
    }
    $loading = @($script:Shared.Meta.Count -lt 2 -and (Test-TaskRunning 'meta')).Count
    $ui.TxtAppsCount.Text = "$($cards.Count) shown" + $(if (Test-TaskRunning 'meta') { ', versions still loading' } elseif ($searching) { ", $(@($script:SearchRows).Count) from the repositories" } else { '' })
    $curated = $script:SourceRows.Count
    $ui.TxtAppsSubtitle.Text = "$curated curated apps from winget and Chocolatey in one list. Type to filter, or search both repositories."
    if ($script:DetailRow) { Show-AppDetails $script:DetailRow -Keep }
}
$script:SearchKeys = @{}

$script:Chips = @{}
function Update-Chips($Rows) {
    # Category chips with the number of apps each one has in the current view; built once, counted on every change
    $cats = @($script:Catalog | ForEach-Object { $_.Category } | Where-Object { $_ } | Sort-Object -Unique)
    if ($script:Chips.Count -eq 0) {
        foreach ($cat in @('All') + $cats) {
            $chip = New-Object System.Windows.Controls.RadioButton
            $chip.Style = $window.FindResource('ChipItem'); $chip.GroupName = 'Chips'; $chip.Tag = $cat; $chip.IsChecked = ($cat -eq $script:Category)
            $chip.SetValue([System.Windows.Automation.AutomationProperties]::NameProperty, "Category $cat")
            $chip.Add_Checked({ param($s) if ($script:Category -ne $s.Tag) { $script:Category = [string]$s.Tag; try { Update-AppList } catch { Show-Error $_.Exception.Message } } })
            $script:Chips[$cat] = $chip
            [void]$ui.PanelChips.Children.Add($chip)
        }
    }
    foreach ($cat in $script:Chips.Keys) {
        $count = if ($cat -eq 'All') { @($Rows).Count } else { @($Rows | Where-Object { $_.Category -eq $cat }).Count }
        $script:Chips[$cat].Content = "$cat  $count"
    }
}

function Start-CatalogPrefetch {
    $items = foreach ($e in $script:Catalog) {
        if ($e.Id) { @{ Source = 'Chocolatey'; Id = $e.Id } }
        if ($e.WingetId) { @{ Source = 'Winget'; Id = $e.WingetId } }
    }
    Start-MetaPrefetch -Items @($items)
}
function Update-CatalogRowsAndList { Update-CatalogRows; Update-AppList }

function Find-VisualChild($Parent, [type]$Type) {
    for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Parent); $i++) {
        $child = [System.Windows.Media.VisualTreeHelper]::GetChild($Parent, $i)
        if ($child -is $Type) { return $child }
        $found = Find-VisualChild $child $Type
        if ($found) { return $found }
    }
}
function Set-CardWidth {
    # As many cards per row as fit (at least 300 px each); the cards share the width
    $panel = Find-VisualChild $ui.CardList ([System.Windows.Controls.WrapPanel])
    $width = $ui.AppsScroll.ActualWidth - 4
    if (-not $panel -or $width -lt 100) { return }
    $columns = [Math]::Max(1, [Math]::Floor($width / 300))
    $panel.ItemWidth = [Math]::Floor($width / $columns)
}
$ui.AppsScroll.Add_SizeChanged({ try { Set-CardWidth } catch { } })
$ui.CardList.Add_LayoutUpdated({ if (-not $script:CardWidthSet) { $p = Find-VisualChild $ui.CardList ([System.Windows.Controls.WrapPanel]); if ($p) { $script:CardWidthSet = $true; try { Set-CardWidth } catch { } } } })
$script:CardWidthSet = $false
$ui.TxtFilter.Add_TextChanged({
    $ui.HintFilter.Visibility = ConvertTo-Vis (-not $ui.TxtFilter.Text)
    try { Update-AppList } catch { Show-Error $_.Exception.Message }
})
$ui.TxtFilter.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { try { Start-AppSearch } catch { Show-Error $_.Exception.Message } } })
foreach ($pair in @(@('FltAll', 'All'), @('FltWinget', 'Winget'), @('FltChoco', 'Chocolatey'), @('FltBoth', 'Both'))) {
    $ui[$pair[0]].Tag = $pair[1]
    $ui[$pair[0]].Add_Checked({ param($s) $script:SourceFilter = [string]$s.Tag; try { Update-AppList } catch { Show-Error $_.Exception.Message } })
}

function Start-AppSearch {
    $term = $ui.TxtFilter.Text.Trim()
    if ($term.Length -lt 2) { throw 'Enter at least two characters.' }
    if (Test-TaskRunning 'search') { return }
    $ui.TxtAppsCount.Text = 'Searching both repositories ...'
    $work = 'param($Term) Search-IntuneChocoApps -SearchPattern $Term -Top 30 -Cache $Shared.Meta'
    [void](Start-UiTask -Kind 'search' -Title "Searching Chocolatey and winget for '$term'" -Display "Search: $term" -Pool $script:UserPool -Arguments @{ Term = $term } -Work $work -OnDone {
        param($Result, $Job)
        $script:SearchTerm = $Job.Spec.Arguments.Term
        $script:SearchRows = @($Result | Where-Object { $_ -and $_.Name })
        $script:SearchKeys = @{}
        foreach ($r in $script:SearchRows) { $script:SearchKeys[(Get-AppKey $r)] = $true }
        $script:MetaDirty = $true
        Update-AppList
        if ($Job.Status -eq 'failed') { $ui.TxtAppsCount.Text = 'Search failed, see Activity' }
        $ids = foreach ($r in $script:SearchRows) { foreach ($s in $r.Sources) { @{ Source = $s; Id = (Get-AppId $r $s) } } }
        Start-MetaPrefetch -Items @($ids)
        Start-IconRender
    } -Hidden)
}
Add-Click $ui.BtnSearchRepos { Start-AppSearch }

# ---------------------------------------------------------------- selection and details
function Set-AppSelected($Src, [bool]$On) {
    $key = Get-AppKey $Src
    if ($On) { $script:Selected[$key] = $Src } else { $script:Selected.Remove($key) }
    if ($script:CardRows.ContainsKey($key)) { $script:CardRows[$key]['Selected'] = [string][bool]$On }
    Update-SelectionBar
}
function Clear-Selection {
    foreach ($key in @($script:Selected.Keys)) { if ($script:CardRows.ContainsKey($key)) { $script:CardRows[$key]['Selected'] = 'False' } }
    $script:Selected.Clear()
    Update-SelectionBar
}
Add-Click $ui.BtnClearSelection { Clear-Selection }
Add-Click $ui.BtnSelectShown {
    foreach ($card in $script:CardCollection) { Set-AppSelected $card.Data $true }
}
$ui.CardList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
    param($s, $e)
    try {
        $b = $e.OriginalSource
        if ($b -isnot [System.Windows.Controls.Button] -or $b.DataContext -isnot [IntuneChoco.Row]) { return }
        $src = $b.DataContext.Data
        if ($b.Uid -eq 'details') { Show-AppDetails $src }
        elseif ($b.Uid -eq 'card') { Set-AppSelected $src (-not $script:Selected.Contains((Get-AppKey $src))) }
    }
    catch { Show-Error $_.Exception.Message }
})

function Update-SelectionBar {
    $count = $script:Selected.Count
    $ui.SelectionBar.Visibility = ConvertTo-Vis ($count -gt 0 -and $script:CurrentPage -eq 'Apps')
    $ui.TxtSelectionCount.Text = if ($count -eq 1) { '1 app selected' } else { "$count apps selected" }
    $wingetMissing = (@($script:Selected.Values | Where-Object { (Get-AppSource $_) -eq 'Winget' }).Count -gt 0) -and -not $script:ModuleState.Winget
    $ui.BtnReview.IsEnabled = $count -gt 0 -and (Test-SignedIn) -and $script:ModuleState.Ok -and -not $wingetMissing
    $ui.BtnReview.ToolTip = if (-not (Test-SignedIn)) { 'Sign in first' } elseif (-not $script:ModuleState.Ok) { 'Install the IntuneWin32App module first (Start)' }
                            elseif ($wingetMissing) { 'Install the Microsoft.WinGet.Client module first (Settings > Components)' } else { 'Choose source, version and updates per app, then deploy' }
    $ui.BtnDetailTest.IsEnabled = [bool]$script:DetailRow -and -not (Test-TaskRunning 'test')
}
$ui.RbPreferWinget.Add_Checked({ $script:Preferred = 'Winget'; Update-SelectionBar })
$ui.RbPreferChoco.Add_Checked({ $script:Preferred = 'Chocolatey'; Update-SelectionBar })
Add-Click $ui.BtnReview { Show-DeployDialog }

function Show-AppDetails($Src, [switch]$Keep) {
    $script:DetailRow = $Src
    $ui.PanelDetails.Visibility = 'Visible'
    $source = Get-AppSource $Src
    $meta = Get-AppMeta $Src $source
    $other = $Src.Sources | Where-Object { $_ -ne $source } | Select-Object -First 1
    $ui.TxtDetailTitle.Text = $Src.Name
    $parts = @(); if ($meta -and $meta.Found -and $meta.Authors) { $parts += $meta.Authors }; if ($meta -and $meta.Found -and $meta.License) { $parts += "license $($meta.License)" }
    $ui.TxtDetailMeta.Text = $parts -join "  $([char]0x00B7)  "
    $lines = foreach ($s in 'Winget', 'Chocolatey') {
        if ($Src.Sources -contains $s) {
            $v = if ($s -eq 'Winget') { $Src.WingetVersion } else { $Src.ChocoVersion }
            "$(Get-SourceLabel $s): $(Get-AppId $Src $s)$(if ($v) { ", version $v" })$(if ($Src.RecommendedMarked -and $Src.Recommended -eq $s) { ' (recommended)' })"
        }
    }
    $ui.TxtDetailSources.Text = @($lines) -join "`n"
    $summary = if ($meta -and $meta.Summary) { $meta.Summary } elseif ($meta -and $meta.Description) { $meta.Description } elseif ($meta -and $meta.Found) { '' } else { 'Package infos are still loading, or the source has none.' }
    $ui.TxtDetailSummary.Text = ([string]$summary -replace '\s+', ' ').Trim()
    $note = (Get-CardNote $Src)
    $ui.BoxLicense.Visibility = ConvertTo-Vis ([bool]$note)
    $ui.TxtLicenseNote.Text = $note
    $ui.BtnDetailSite.IsEnabled = [bool]($meta -and $meta.ProjectUrl)
    $ui.BtnDetailLicense.IsEnabled = [bool]($meta -and $meta.LicenseUrl)
    $ui.BtnDetailRepo.Content = if ($source -eq 'Winget') { 'winget-pkgs' } else { 'chocolatey.org' }
    $t = Get-TileStyle $Src.Name
    $ui.BoxDetailIcon.Background = ConvertTo-Brush $t.TileBg; $ui.TxtDetailMono.Text = $t.Mono; $ui.TxtDetailMono.Foreground = ConvertTo-Brush $t.TileFg
    Update-DetailIcon
    Update-SelectionBar
}
function Get-CardNote($Src) {
    $key = Get-AppKey $Src
    if ($script:CardRows.ContainsKey($key)) { return [string]$script:CardRows[$key]['License'] }
    ''
}
Add-Click $ui.BtnDetailClose { $script:DetailRow = $null; $ui.PanelDetails.Visibility = 'Collapsed'; Update-SelectionBar }

function Update-DetailIcon {
    $src = $script:DetailRow
    if (-not $src) { return }
    $key = Get-AppKey $src
    $custom = $script:CustomIcons[$key]
    $ui.ImgDetail.Source = $null
    $rawUrl = $null
    foreach ($s in 'Chocolatey', 'Winget') { $m = Get-AppMeta $src $s; if (-not $rawUrl -and $m -and $m.Found -and $m.IconUrl) { $rawUrl = [string]$m.IconUrl } }
    try {
        if ($custom) {
            $stream = New-Object IO.MemoryStream(, [Convert]::FromBase64String($custom))
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit(); $bmp.CacheOption = 'OnLoad'; $bmp.StreamSource = $stream; $bmp.EndInit(); $bmp.Freeze()
            $stream.Dispose()
            $ui.ImgDetail.Source = $bmp
        }
        elseif ($preview = Get-IconPreview $rawUrl) {
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit(); $bmp.UriSource = [Uri]$preview; $bmp.EndInit()
            $ui.ImgDetail.Source = $bmp
        }
    }
    catch { }
    $ui.TxtCustomIcon.Text = if ($custom) { "Custom icon set ($([math]::Round($custom.Length * 3 / 4 / 1024)) KB), used instead of the one from the package source." }
                             elseif ($rawUrl -match '\.svg(\?|#|$)') { 'SVG icon from the package source, converted to PNG with Edge for Intune.' }
                             elseif ($rawUrl) { 'Icon from the package source.' }
                             else { 'This package has no icon; the app is created without one unless you choose a file.' }
    $ui.BtnCustomIconRemove.Visibility = ConvertTo-Vis ([bool]$custom)
}

Add-Click $ui.BtnCustomIcon {
    if (-not $script:DetailRow) { return }
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = "Icon for $($script:DetailRow.Name)"
    $dlg.Filter = 'Images (*.png;*.jpg;*.jpeg;*.svg;*.ico)|*.png;*.jpg;*.jpeg;*.svg;*.ico|All files (*.*)|*.*'
    if (-not $dlg.ShowDialog($window)) { return }
    Set-CustomIcon -Key (Get-AppKey $script:DetailRow) -Path $dlg.FileName
}
function Set-CustomIcon([string]$Key, [string]$Path) {
    $window.Cursor = 'Wait'
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -gt 5MB) { throw 'The icon file is larger than 5 MB.' }
        $workPath = Join-Path $script:WorkRoot "icons\$($Key -replace '[^A-Za-z0-9._-]', '_')"
        New-Item -Path $workPath -ItemType Directory -Force | Out-Null
        $png = ConvertTo-PngBytes -Bytes $bytes -WorkPath $workPath
        $script:CustomIcons[$Key] = [Convert]::ToBase64String($png)
        Write-UiLog "Custom icon for $Key taken from $(Split-Path $Path -Leaf)."
    }
    finally { $window.Cursor = $null }
    Update-DetailIcon
}
Add-Click $ui.BtnCustomIconRemove { if ($script:DetailRow) { $script:CustomIcons.Remove((Get-AppKey $script:DetailRow)); Update-DetailIcon } }
Add-Click $ui.BtnDetailSite { $m = Get-AppMeta $script:DetailRow (Get-AppSource $script:DetailRow); if ($m.ProjectUrl -match '^https?://') { Start-Process $m.ProjectUrl } }
Add-Click $ui.BtnDetailLicense { $m = Get-AppMeta $script:DetailRow (Get-AppSource $script:DetailRow); if ($m.LicenseUrl -match '^https?://') { Start-Process $m.LicenseUrl } }
Add-Click $ui.BtnDetailRepo {
    $src = $script:DetailRow; $source = Get-AppSource $src; $id = Get-AppId $src $source
    if ($source -eq 'Winget') {
        $path = @($id.Split('.') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
        Start-Process "https://github.com/microsoft/winget-pkgs/tree/master/manifests/$($id.Substring(0, 1).ToLower())/$path"
    }
    else { Start-Process "https://community.chocolatey.org/packages/$([Uri]::EscapeDataString($id))" }
}
Add-Click $ui.BtnDetailTest {
    $src = $script:DetailRow
    if (-not $src) { return }
    $source = Get-AppSource $src
    Start-PackageTest -Package (Get-AppId $src $source) -Source $source -Title $src.Name -Version 'latest' -Policy @{ UpdateMode = $script:Settings.UpdateMode; GraceHours = $script:Settings.GraceHours }
}

# ---------------------------------------------------------------- update modes (deploy dialog, settings)
$script:PolicyModes = @('Off', 'Startup', 'Custom')
$script:PolicyModeLabels = @('Off', 'Automatic, per schedule', 'Ask the user, then install')
$script:PolicyModeHelp = @{
    Off     = 'No automatic updates. A version you release here is installed by Intune right away.'
    Startup = 'Updated when the schedule allows it (default: at startup and in a time window), after a random wait.'
    Custom  = 'The user is offered the update and can install it at once. When the time is up it is installed anyway, without a restart.'
}
foreach ($place in 'Deploy', 'Default') {
    $ui["Cmb${place}Update"].ItemsSource = $script:PolicyModeLabels
    $ui["Cmb${place}GraceUnit"].ItemsSource = @('hours', 'days')
    $ui["Cmb${place}Update"].Add_SelectionChanged({ param($src) Sync-PolicyControls ($src.Name -replace '^Cmb|Update$', '') })
}
$ui.CmbTenantGraceUnit.ItemsSource = @('hours', 'days')
$ui.CmbDeployVersion.ItemsSource = @('Always the newest version', 'Pin the current version')
$ui.CmbDefaultVersion.ItemsSource = @('Always the newest version', 'Pin the current version')
$ui.CmbDeployAssign.ItemsSource = @('Required for all users', 'Available in the Company Portal', 'No assignment')
$script:AssignValues = @('Required', 'Available', 'None')

function Sync-PolicyControls([string]$Place) {
    $mode = $script:PolicyModes[[Math]::Max(0, $ui["Cmb${Place}Update"].SelectedIndex)]
    $ui["Panel${Place}Grace"].Visibility = ConvertTo-Vis ($mode -eq 'Custom')
    $ui["Txt${Place}UpdateHelp"].Text = $script:PolicyModeHelp[$mode]
}
function Set-PolicyControls([string]$Place, [string]$Mode, [int]$GraceHours) {
    $ui["Cmb${Place}Update"].SelectedIndex = [Math]::Max(0, [array]::IndexOf($script:PolicyModes, $Mode))
    $inDays = $GraceHours -gt 0 -and $GraceHours % 24 -eq 0
    $ui["Txt${Place}Grace"].Text = [string]$(if ($inDays) { $GraceHours / 24 } else { $GraceHours })
    $ui["Cmb${Place}GraceUnit"].SelectedIndex = if ($inDays) { 1 } else { 0 }
    Sync-PolicyControls $Place
}
function ConvertTo-GraceHours([string]$Text, [int]$UnitIndex, [bool]$Required) {
    $factor = if ($UnitIndex -eq 1) { 24 } else { 1 }
    $hours = if (([string]$Text).Trim() -match '^\d{1,5}$') { [int]$Text.Trim() * $factor } else { 0 }
    if ($hours -lt 1 -or $hours -gt 2160) {
        if ($Required) { throw 'The time until the update is installed anyway must be between 1 hour and 90 days.' }
        $hours = [int]$script:Settings.GraceHours
    }
    $hours
}
function Read-PolicyControls([string]$Place) {
    $mode = $script:PolicyModes[[Math]::Max(0, $ui["Cmb${Place}Update"].SelectedIndex)]
    @{ UpdateMode = $mode; GraceHours = (ConvertTo-GraceHours $ui["Txt${Place}Grace"].Text $ui["Cmb${Place}GraceUnit"].SelectedIndex ($mode -eq 'Custom')) }
}
function Format-UpdateText([string]$Mode, [int]$GraceHours) {
    switch ($Mode) {
        'Off' { 'Off' }
        'Custom' { 'Ask user, ' + $(if ($GraceHours % 24 -eq 0) { "$($GraceHours / 24) day(s)" } else { "$GraceHours hour(s)" }) }
        default { 'Automatic' }
    }
}
function Compare-PackageVersion([string]$A, [string]$B) {
    $c = Compare-SourceVersion -A $A -B $B
    if ($null -eq $c) { 0 } else { $c }
}

# ---------------------------------------------------------------- schedule text
function Format-ScheduleSummary($S) {
    # The schedule in words: when updates install, and under which conditions
    $dayNames = @{ '1' = 'Mon'; '2' = 'Tue'; '3' = 'Wed'; '4' = 'Thu'; '5' = 'Fri'; '6' = 'Sat'; '7' = 'Sun' }
    $when = @()
    if ($S.TriggerWindow) {
        $days = if ($S.WindowDays -eq '1234567') { 'daily' } elseif ($S.WindowDays -eq '12345') { 'Mon to Fri' } else { (($S.WindowDays.ToCharArray() | ForEach-Object { $dayNames[[string]$_] }) -join ', ') }
        $when += "$days $($S.WindowFrom) to $($S.WindowTo)"
    }
    if ($S.TriggerStart) { $when += 'at PC start' }
    if ($S.TriggerLogon) { $when += 'at user sign-in' }
    $whenText = if ($when.Count) { ($when -join ', or ') } else { 'Not on a schedule' }
    $whenText = $whenText.Substring(0, 1).ToUpper() + $whenText.Substring(1)
    $cond = @()
    if ($S.OnlyOnMains) { $cond += 'only on mains power' }
    if ($S.NoPresentation) { $cond += 'not during presentations' }
    if ($S.NoMetered) { $cond += 'not on a metered network' }
    if ($S.AppNotRunning) { $cond += 'when the app is not in use' }
    if ($S.IdleMinutes -gt 0) { $cond += "after $($S.IdleMinutes) min idle" }
    $condText = if ($cond.Count) { ($cond -join ', ') } else { 'No further conditions' }
    $condText = $condText.Substring(0, 1).ToUpper() + $condText.Substring(1)
    @{ When = $whenText; Conditions = $condText }
}

# ---------------------------------------------------------------- deploy dialog
$script:DeployCombos = New-Object System.Collections.ArrayList
$script:DeploySchedule = $null     # schedule values chosen for this deployment (hashtable), $null = settings default
$script:DeployVersionTexts = @{}

function Get-SourceOptionText($Src, [string]$Source) {
    $v = if ($Source -eq 'Winget') { $Src.WingetVersion } else { $Src.ChocoVersion }
    $text = "$(Get-SourceLabel $Source)$(if ($v) { ' ' + $v })"
    if ($Src.RecommendedMarked -and $Src.Recommended -eq $Source) { $text += ', recommended (newer)' }
    $text
}

function Update-DeployVersionTexts {
    $pinned = $ui.CmbDeployVersion.SelectedIndex -eq 1
    foreach ($entry in $script:DeployCombos) {
        $source = $entry.Sources[[Math]::Max(0, $entry.Combo.SelectedIndex)]
        $v = if ($source -eq 'Winget') { $entry.Src.WingetVersion } else { $entry.Src.ChocoVersion }
        $entry.VersionText.Text = if ($pinned) { "Pinned$(if ($v) { ' to ' + $v })" } else { "Always newest$(if ($v) { " ($v)" })" }
    }
    $sources = @($script:DeployCombos | ForEach-Object { $_.Sources[[Math]::Max(0, $_.Combo.SelectedIndex)] } | Select-Object -Unique)
    $ui.TxtDeployDependency.Inlines.Clear()
    $bold = New-Object System.Windows.Documents.Run 'Dependencies are added automatically. '; $bold.FontWeight = 'SemiBold'
    [void]$ui.TxtDeployDependency.Inlines.Add($bold)
    [void]$ui.TxtDeployDependency.Inlines.Add((New-Object System.Windows.Documents.Run $(
        if ($sources.Count -eq 2) { 'winget apps depend on the winget runtime app, Chocolatey apps on the Chocolatey app. A missing one is created first.' }
        elseif ($sources -contains 'Winget') { 'winget apps depend on the winget runtime app. A missing one is created first.' }
        else { 'Chocolatey apps depend on the Chocolatey app. A missing one is created first.' })))
    $notes = @($script:DeployCombos | ForEach-Object { $src = $_.Sources[[Math]::Max(0, $_.Combo.SelectedIndex)]; $n = Get-CardNote $_.Src; if ($n) { "$($_.Src.Name): license note" } })
    $assign = $script:AssignValues[[Math]::Max(0, $ui.CmbDeployAssign.SelectedIndex)]
    $ui.TxtDeployWarn.Text = (@($notes) + @($(if ($assign -eq 'Required') { 'Required installs on every device of all users.' })) | Where-Object { $_ }) -join ' '
}

function Show-DeployDialog {
    if ($script:Selected.Count -eq 0) { throw 'Select at least one app first.' }
    if (-not (Test-SignedIn)) { throw 'Sign in to Intune first (Sign in, top right).' }
    if (-not $script:ModuleState.Ok) { throw "IntuneWin32App $($script:MinimumModuleVersion) or newer is required (Start > Get ready)." }
    $ui.PanelDeployRows.Children.Clear()
    $script:DeployCombos.Clear()
    foreach ($src in $script:Selected.Values) {
        $key = Get-AppKey $src
        $tile = Get-TileStyle $src.Name
        $grid = New-Object System.Windows.Controls.Grid
        $grid.Margin = '0,0,0,0'
        foreach ($w in @(@('Star', 1), @('Pixel', 330), @('Pixel', 150))) {
            $c = New-Object System.Windows.Controls.ColumnDefinition
            $c.Width = [System.Windows.GridLength]::new($w[1], $w[0]); [void]$grid.ColumnDefinitions.Add($c)
        }
        $row = New-Object System.Windows.Controls.Border
        $row.BorderBrush = Get-Brush 'Divider'; $row.BorderThickness = '0,0,0,1'; $row.Padding = '0,10'
        $name = New-Object System.Windows.Controls.StackPanel; $name.Orientation = 'Horizontal'
        $tileBox = New-Object System.Windows.Controls.Border
        $tileBox.Width = 32; $tileBox.Height = 32; $tileBox.CornerRadius = 7; $tileBox.Background = ConvertTo-Brush $tile.TileBg; $tileBox.Margin = '0,0,12,0'
        $letter = New-Object System.Windows.Controls.TextBlock; $letter.Text = $tile.Mono; $letter.FontWeight = 'Bold'; $letter.FontSize = 13; $letter.Foreground = ConvertTo-Brush $tile.TileFg
        $letter.HorizontalAlignment = 'Center'; $letter.VerticalAlignment = 'Center'; $tileBox.Child = $letter
        $label = New-Object System.Windows.Controls.TextBlock; $label.Text = $src.Name; $label.FontWeight = 'SemiBold'; $label.VerticalAlignment = 'Center'
        [void]$name.Children.Add($tileBox); [void]$name.Children.Add($label)
        $combo = New-Object System.Windows.Controls.ComboBox
        $combo.Margin = '0,0,12,0'; $combo.VerticalAlignment = 'Center'; $combo.Width = 316
        $combo.SetValue([System.Windows.Automation.AutomationProperties]::NameProperty, "Install $($src.Name) with")
        $sources = @($src.Sources)
        $combo.ItemsSource = @($sources | ForEach-Object { Get-SourceOptionText $src $_ })
        $combo.SelectedIndex = [Math]::Max(0, [array]::IndexOf($sources, (Get-AppSource $src)))
        $ver = New-Object System.Windows.Controls.TextBlock; $ver.Foreground = Get-Brush 'Text2'; $ver.VerticalAlignment = 'Center'; $ver.TextTrimming = 'CharacterEllipsis'
        [System.Windows.Controls.Grid]::SetColumn($combo, 1); [System.Windows.Controls.Grid]::SetColumn($ver, 2)
        [void]$grid.Children.Add($name); [void]$grid.Children.Add($combo); [void]$grid.Children.Add($ver)
        $row.Child = $grid
        [void]$ui.PanelDeployRows.Children.Add($row)
        [void]$script:DeployCombos.Add(@{ Key = $key; Src = $src; Combo = $combo; Sources = $sources; VersionText = $ver })
        $combo.Add_SelectionChanged({
            foreach ($entry in $script:DeployCombos) { $script:SourceChoice[$entry.Key] = $entry.Sources[[Math]::Max(0, $entry.Combo.SelectedIndex)] }
            Update-DeployVersionTexts
        })
    }
    $n = $script:Selected.Count
    $ui.TxtDeployTitle.Text = "Deploy $n app$(if ($n -ne 1) { 's' }) to $(if ($script:Settings.TenantID) { $script:Settings.TenantID } else { 'the tenant' })"
    $ui.BtnDeployGo.Content = "Deploy $n app$(if ($n -ne 1) { 's' })"
    $assignIndex = if ($ui.RbRequired.IsChecked) { 0 } elseif ($ui.RbNone.IsChecked) { 2 } else { 1 }
    $ui.CmbDeployAssign.SelectedIndex = $assignIndex
    $ui.CmbDeployVersion.SelectedIndex = if ($script:Settings.VersionMode -eq 'Pinned') { 1 } else { 0 }
    Set-PolicyControls 'Deploy' $script:Settings.UpdateMode $script:Settings.GraceHours
    $script:DeploySchedule = $null
    Update-DeploySchedule
    Update-DeployVersionTexts
    Show-Dialog 'DlgDeploy'
}
$ui.CmbDeployVersion.Add_SelectionChanged({ if ($script:OpenDialog -eq 'DlgDeploy') { Update-DeployVersionTexts } })
$ui.CmbDeployAssign.Add_SelectionChanged({ if ($script:OpenDialog -eq 'DlgDeploy') { Update-DeployVersionTexts } })

function Update-DeploySchedule {
    $s = if ($script:DeploySchedule) { New-ChocoSchedule -Values $script:DeploySchedule -Base (Get-ChocoScheduleDefaults) } else { Get-ChocoScheduleDefaults }
    $t = Format-ScheduleSummary $s
    $ui.TxtDeploySchedule.Text = "$($t.When). $($t.Conditions)."
}
Add-Click $ui.BtnDeploySchedule {
    $s = if ($script:DeploySchedule) { New-ChocoSchedule -Values $script:DeploySchedule -Base (Get-ChocoScheduleDefaults) } else { Get-ChocoScheduleDefaults }
    Show-ScheduleDialog -Mode 'Deploy' -Schedule $s -Title 'When the new apps update on devices'
}
Add-Click $ui.BtnDeployCancel { Close-Dialog }
Add-Click $ui.BtnDeployGo { Start-Deploy }

function Start-Deploy {
    $assignment = $script:AssignValues[[Math]::Max(0, $ui.CmbDeployAssign.SelectedIndex)]
    $policy = Read-PolicyControls 'Deploy'
    $version = if ($ui.CmbDeployVersion.SelectedIndex -eq 1) { 'current' } else { 'latest' }
    $items = foreach ($entry in $script:DeployCombos) {
        $source = $entry.Sources[[Math]::Max(0, $entry.Combo.SelectedIndex)]
        [pscustomobject]@{ Key = $entry.Key; Src = $entry.Src; Source = $source; Id = (Get-AppId $entry.Src $source); Title = $entry.Src.Name; LicenseNote = (Get-CardNote $entry.Src) }
    }
    $items = @($items)
    $present = @($items | Where-Object { $script:TenantPackages.ContainsKey((Get-MetaKey $_.Id $_.Source)) })
    $todo = @($items | Where-Object { -not $script:TenantPackages.ContainsKey((Get-MetaKey $_.Id $_.Source)) })
    if ($todo.Count -eq 0) { throw "The selected app(s) are already in the tenant ($(($present | ForEach-Object { $_.Title }) -join ', ')). Remove them under 'In tenant' first to deploy them again." }
    if ($present.Count -gt 0) { Write-UiLog "Already in the tenant, left out: $(($present | ForEach-Object { $_.Title }) -join ', ')." 'Warning' }
    $licensed = @($todo | Where-Object LicenseNote)
    if ($licensed.Count -gt 0) {
        $text = ($licensed | ForEach-Object { "- $($_.Title): $($_.LicenseNote)" }) -join "`n"
        if (-not (Confirm-Action "These packages carry a license note:`n`n$text`n`nDeploy them anyway?" 'License notes')) { return }
    }
    if ($assignment -eq 'Required' -and -not (Confirm-Action "Required installs the $($todo.Count) app(s) automatically on every device of all users. Continue?" 'Required assignment')) { return }
    if (@($todo | Where-Object { $_.Source -eq 'Winget' }).Count -and -not $script:ModuleState.Winget) { throw 'winget packages need the Microsoft.WinGet.Client module: install it under Settings > Components.' }
    $schedule = if ($script:DeploySchedule) { (New-ChocoSchedule -Values $script:DeploySchedule -Base (Get-ChocoScheduleDefaults)) } else { $null }
    Update-UiToken
    $work = @'
param($Id, $Source, $Assignment, $Architecture, $IconBase64, $UpdateMode, $GraceHours, $Version, $Schedule)
$Params = @{ Assignment = $Assignment; Architecture = $Architecture; NoIconPrompt = $true; UpdateMode = $UpdateMode; GraceHours = $GraceHours; Version = $Version }
if ($IconBase64) { $Params.IconBase64 = $IconBase64 }
if ($Schedule) { $Params.Schedule = $Schedule }
if ($Source -eq 'Winget') { New-IntuneWin32WingetApplication -WingetId $Id @Params }
else { New-IntuneWin32ChocoApplication -ChocoName $Id @Params }
'@
    foreach ($item in $todo) {
        $icon = $script:CustomIcons[$item.Key]
        $label = Get-SourceLabel $item.Source
        [void](Start-UiTask -Kind 'deploy' -Title "Deploying $($item.Title) from $label ($assignment)" -Display $item.Title -Package $item.Id -NeedsAuth -Work $work -OnDone {
            param($Result, $Job)
            switch ($Job.Status) {
                'succeeded' {
                    Write-UiLog "[$($Job.Package)] created in Intune." 'Success'
                    $key = Get-MetaKey $Job.Package $Job.Source
                    $script:TenantPackages[$key] = $true
                    $script:RecentDeploys[$key] = Get-Date
                    $appId = @($Result | Where-Object { $_ -is [string] }) | Select-Object -First 1
                    $Job.Row['Open'] = [string]$appId
                    Show-Toast "$($Job.Display) was created in Intune." 'ok'
                }
                'skipped' { Show-Toast "$($Job.Display) was skipped: it is already in the tenant." 'warn' }
            }
            $script:TenantApps = $null
            if (-not @($script:Tasks | Where-Object { $_.Job.Kind -eq 'deploy' }).Count) { Start-TenantRefresh }
            Update-AppList
        } -Arguments @{ Id = $item.Id; Source = $item.Source; Assignment = $assignment; Architecture = $script:Settings.Architecture; IconBase64 = $icon; UpdateMode = $policy.UpdateMode; GraceHours = $policy.GraceHours; Version = $version; Schedule = $schedule })
    }
    Write-UiLog "$($todo.Count) deployment(s) queued, assignment $assignment, updates: $(Format-UpdateText $policy.UpdateMode $policy.GraceHours)." 'Info'
    Clear-Selection
    Close-Dialog
    Show-Page 'Activity'
}


# ---------------------------------------------------------------- schedule dialog
$script:SchCtx = @{ Mode = 'App'; App = $null }
$script:SchIntervalValues = @(1, 4, 24)
$script:SchDeadlineValues = @('Install', 'AskClose', 'Close', 'Wait')
$script:SchRestartValues = @('Never', 'Ask', 'OutsideWindow')
$script:SchRetryValues = @('Next', 'None', 'Every')
$ui.SchInterval.ItemsSource = @('Every hour', 'Every 4 hours', 'Once a day')
$ui.SchIdleMin.ItemsSource = @('1', '5', '10', '15', '30', '60')
$ui.SchDeadlineApp.ItemsSource = @('Install anyway', 'Ask, close after the time below', 'Close without asking', 'Wait until it is closed')
$ui.SchRestart.ItemsSource = @('Never, wait for the user', 'Ask the user', 'Outside the time window')
$ui.SchRetry.ItemsSource = @('Retry at the next chance', 'Do not retry', 'Retry several times')
$ui.SchGraceUnit.ItemsSource = @('hours', 'days')
$script:SchDays = 1..7 | ForEach-Object { $ui["SchD$_"] }

function Set-ScheduleControls($S, [int]$GraceHours, [int]$DelayMin, [int]$DelayMax) {
    $ui.SchStart.IsChecked = [bool]$S.TriggerStart; $ui.SchWindow.IsChecked = [bool]$S.TriggerWindow
    $ui.SchFrom.Text = $S.WindowFrom; $ui.SchTo.Text = $S.WindowTo
    for ($d = 1; $d -le 7; $d++) { $ui["SchD$d"].IsChecked = ([string]$S.WindowDays).Contains([string]$d) }
    $ui.SchIdle.IsChecked = $S.IdleMinutes -gt 0
    $idleIndex = [array]::IndexOf(@('1', '5', '10', '15', '30', '60'), [string]$S.IdleMinutes); $ui.SchIdleMin.SelectedIndex = if ($idleIndex -ge 0) { $idleIndex } else { 2 }
    $ui.SchLogon.IsChecked = [bool]$S.TriggerLogon
    $ui.SchMains.IsChecked = [bool]$S.OnlyOnMains; $ui.SchPresentation.IsChecked = [bool]$S.NoPresentation
    $ui.SchMetered.IsChecked = [bool]$S.NoMetered; $ui.SchNotRunning.IsChecked = [bool]$S.AppNotRunning
    $ui.SchInterval.SelectedIndex = [Math]::Max(0, [array]::IndexOf($script:SchIntervalValues, [int]$S.CheckIntervalHours))
    $ui.SchDeadlineApp.SelectedIndex = [Math]::Max(0, [array]::IndexOf($script:SchDeadlineValues, [string]$S.DeadlineAppMode))
    $ui.SchRestart.SelectedIndex = [Math]::Max(0, [array]::IndexOf($script:SchRestartValues, [string]$S.RestartMode))
    $ui.SchRetry.SelectedIndex = [Math]::Max(0, [array]::IndexOf($script:SchRetryValues, [string]$S.RetryMode))
    $ui.SchCloseAfter.Text = [string]$S.CloseAfterMinutes; $ui.SchRetryCount.Text = [string]$S.RetryCount; $ui.SchRetryHours.Text = [string]$S.RetryHours
    $ui.SchProcesses.Text = [string]$S.ProcessNames
    $inDays = $GraceHours -gt 0 -and $GraceHours % 24 -eq 0
    $ui.SchGrace.Text = [string]$(if ($inDays) { $GraceHours / 24 } else { $GraceHours }); $ui.SchGraceUnit.SelectedIndex = if ($inDays) { 1 } else { 0 }
    $ui.SchDelayMin.Text = [string]$DelayMin; $ui.SchDelayMax.Text = [string]$DelayMax
}

function Read-ScheduleControls {
    $days = -join (1..7 | Where-Object { $ui["SchD$_"].IsChecked } | ForEach-Object { [string]$_ })
    $values = [ordered]@{
        TriggerStart = [bool]$ui.SchStart.IsChecked; TriggerWindow = [bool]$ui.SchWindow.IsChecked
        WindowFrom = $ui.SchFrom.Text.Trim(); WindowTo = $ui.SchTo.Text.Trim(); WindowDays = $days
        IdleMinutes = $(if ($ui.SchIdle.IsChecked) { [int]$ui.SchIdleMin.SelectedItem } else { 0 })
        TriggerLogon = [bool]$ui.SchLogon.IsChecked
        OnlyOnMains = [bool]$ui.SchMains.IsChecked; NoPresentation = [bool]$ui.SchPresentation.IsChecked; NoMetered = [bool]$ui.SchMetered.IsChecked; AppNotRunning = [bool]$ui.SchNotRunning.IsChecked
        CheckIntervalHours = $script:SchIntervalValues[[Math]::Max(0, $ui.SchInterval.SelectedIndex)]
        DeadlineAppMode = $script:SchDeadlineValues[[Math]::Max(0, $ui.SchDeadlineApp.SelectedIndex)]
        CloseAfterMinutes = $ui.SchCloseAfter.Text.Trim()
        RestartMode = $script:SchRestartValues[[Math]::Max(0, $ui.SchRestart.SelectedIndex)]
        RetryMode = $script:SchRetryValues[[Math]::Max(0, $ui.SchRetry.SelectedIndex)]
        RetryCount = $ui.SchRetryCount.Text.Trim(); RetryHours = $ui.SchRetryHours.Text.Trim()
        ProcessNames = $ui.SchProcesses.Text.Trim()
    }
    if (-not $values.TriggerWindow) { $values.WindowDays = $(if ($days) { $days } else { '1234567' }) }
    $schedule = New-ChocoSchedule -Values $values   # validates, throws a readable message
    if ($schedule.IdleMinutes -eq 0 -and $ui.SchIdle.IsChecked) { throw 'Choose the idle time in minutes.' }
    $delayMin = 0; $delayMax = 0
    if (-not ([int]::TryParse($ui.SchDelayMin.Text.Trim(), [ref]$delayMin) -and [int]::TryParse($ui.SchDelayMax.Text.Trim(), [ref]$delayMax)) -or $delayMin -lt 0 -or $delayMax -lt $delayMin) { throw 'The random wait needs two whole minutes, the second not smaller than the first.' }
    @{ Values = $values; Schedule = $schedule; GraceHours = (ConvertTo-GraceHours $ui.SchGrace.Text $ui.SchGraceUnit.SelectedIndex $false); DelayMin = $delayMin; DelayMax = $delayMax }
}

function Update-ScheduleSummary {
    try {
        $r = Read-ScheduleControls
        $t = Format-ScheduleSummary $r.Schedule
        $ui.TxtScheduleSummary.Text = "Summary: $($t.When). $($t.Conditions)."
    }
    catch { $ui.TxtScheduleSummary.Text = $_.Exception.Message }
}

function Update-ScheduleApplyButton {
    $default = $script:SchCtx.Mode -eq 'Default' -or ($script:SchCtx.Mode -eq 'App' -and $ui.RbSchDefault.IsChecked)
    $ui.BtnScheduleApply.Content = switch ($true) { ($script:SchCtx.Mode -eq 'Deploy') { 'Use for these apps' } $default { 'Save as default' } default { 'Apply in Intune' } }
    $edit = $default
    foreach ($n in 'SchDelayMin', 'SchDelayMax') { $ui[$n].IsEnabled = $edit }
    $ui.SchDelayMin.ToolTip = if ($edit) { $null } else { 'The random wait is set in Settings > Package sources.' }
}

function Show-ScheduleDialog {
    param([ValidateSet('App', 'Default', 'Deploy')][string]$Mode, $Schedule, [string]$Title, $App, [int]$GraceHours = $script:Settings.GraceHours)
    $script:SchCtx = @{ Mode = $Mode; App = $App }
    $ui.TxtScheduleTitle.Text = $Title
    $ui.SegSchedule.Visibility = ConvertTo-Vis ($Mode -eq 'App')
    $ui.RbSchThis.IsChecked = $true
    $dMin = if ($App -and $App.DelayMin) { $App.DelayMin } else { $script:Settings.UpdateDelayMinMinutes }
    $dMax = if ($App -and $App.DelayMax) { $App.DelayMax } else { $script:Settings.UpdateDelayMaxMinutes }
    Set-ScheduleControls $Schedule $GraceHours $script:Settings.UpdateDelayMinMinutes $script:Settings.UpdateDelayMaxMinutes
    $ui.TxtSchNotRunning.Text = if ($App) { "$($App.DisplayName) is not in use" } else { 'The app is not in use' }
    Update-ScheduleApplyButton
    Update-ScheduleSummary
    Show-Dialog 'DlgSchedule'
}
foreach ($n in 'SchStart', 'SchWindow', 'SchIdle', 'SchLogon', 'SchMains', 'SchPresentation', 'SchMetered', 'SchNotRunning', 'SchD1', 'SchD2', 'SchD3', 'SchD4', 'SchD5', 'SchD6', 'SchD7') {
    $ui[$n].Add_Click({ if ($script:OpenDialog -eq 'DlgSchedule') { Update-ScheduleSummary } })
}
foreach ($n in 'SchFrom', 'SchTo') { $ui[$n].Add_TextChanged({ if ($script:OpenDialog -eq 'DlgSchedule') { Update-ScheduleSummary } }) }
$ui.RbSchThis.Add_Checked({ if ($script:OpenDialog -eq 'DlgSchedule') { Update-ScheduleApplyButton } })
$ui.RbSchDefault.Add_Checked({ if ($script:OpenDialog -eq 'DlgSchedule') { Update-ScheduleApplyButton } })

function Save-DefaultSchedule($R) {
    $s = Get-IntuneChocoSettings
    $s.UpdateSchedule = ($R.Values | ConvertTo-Json -Compress)
    $s.UpdateDelayMinMinutes = $R.DelayMin; $s.UpdateDelayMaxMinutes = $R.DelayMax; $s.GraceHours = $R.GraceHours
    [void](Save-IntuneChocoSettings -Settings $s)
    $script:Settings = Get-IntuneChocoSettings
    Write-UiLog 'Schedule for new apps saved in the settings.' 'Success'
    Show-Toast 'Schedule for new apps saved.' 'ok'
    Update-SettingsView
}
Add-Click $ui.BtnScheduleCancel { if ($script:SchCtx.Mode -eq 'Deploy') { Show-Dialog 'DlgDeploy' } else { Close-Dialog } }
Add-Click $ui.BtnScheduleApply {
    $r = Read-ScheduleControls
    switch ($script:SchCtx.Mode) {
        'Deploy' { $script:DeploySchedule = $r.Values; Update-DeploySchedule; Show-Dialog 'DlgDeploy' }
        'Default' { Save-DefaultSchedule $r; Close-Dialog }
        default {
            if ($ui.RbSchDefault.IsChecked) { Save-DefaultSchedule $r; Close-Dialog }
            else {
                $app = $script:SchCtx.App
                $policy = Read-TenantPolicy
                $version = Get-TenantVersion
                $script:TenantSchedule = $r.Values
                Close-Dialog
                Start-AppApply -App $app -Version $version -Policy @{ UpdateMode = $policy.UpdateMode; GraceHours = $(if ($policy.UpdateMode -eq 'Custom') { $policy.GraceHours } else { $r.GraceHours }) } -Schedule $r.Values
            }
        }
    }
}

# ---------------------------------------------------------------- tenant
function Update-UiToken {
    # Renews the sign-in on the UI thread before it is handed to a task (silent, at most one short web request)
    try {
        Update-IntuneChocoToken 3>&1 6>&1 | ForEach-Object { Write-UiLog ([string]$_) $(if ($_ -is [System.Management.Automation.WarningRecord]) { 'Warning' } else { 'Info' }) }
        $script:Shared.Auth = Get-IntuneChocoAuthState
    }
    catch { Write-UiLog $_.Exception.Message 'Warning' }
}

$script:TenantRowList = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.LstTenant.ItemsSource = $script:TenantRowList
$script:DeviceCounts = @{}
$script:TenantPolicyApp = ''
$script:TenantSchedule = $null

function Start-TenantRefresh {
    if (-not (Test-SignedIn)) { throw 'Sign in to Intune first.' }
    if (Test-TaskRunning 'tenant') { return }
    $ui.TxtTenantCount.Text = 'Reading the apps in the tenant ...'
    Update-UiToken
    $work = @'
Get-IntuneChocoTenantApps | ForEach-Object {
    $Intents = ''
    try { $Intents = (@(Get-IntuneChocoAppIntents -AppId $_.Id) -join ',') } catch { }
    [pscustomobject]@{
        Id = [string]$_.Id; DisplayName = [string]$_.DisplayName; Package = [string]$_.Package; Source = [string]$_.Source; IsChocolatey = [bool]$_.IsChocolatey; Created = [string]$_.Created
        Version = [string]$_.Version; UpdateMode = [string]$_.UpdateMode; GraceHours = [int]$_.GraceHours; HasPolicy = [bool]$_.HasPolicy; Intents = $Intents; Schedule = $_.Schedule
    }
}
'@
    [void](Start-UiTask -Kind 'tenant' -Title 'Reading the apps this tool created in the tenant' -Display 'Tenant apps' -Hidden -NeedsAuth -Work $work -OnDone {
        param($Result, $Job)
        if ($Job.Status -eq 'failed') { $ui.TxtTenantCount.Text = 'Could not read the tenant, see Activity'; Complete-SetupStep $false 'reading the tenant'; return }
        $script:TenantApps = @($Result | Where-Object { $_ -and $_.Id } | ForEach-Object {
            $_ | Add-Member -NotePropertyName LatestVersion -NotePropertyValue '' -Force -PassThru | Add-Member -NotePropertyName UpdateAvailable -NotePropertyValue $false -Force -PassThru
        } | Sort-Object { -not $_.IsChocolatey }, DisplayName)
        # Catalog and search mark what is already there, including apps created in the last minutes that Graph does not list yet
        $script:TenantPackages = @{}
        foreach ($app in $script:TenantApps) { if ($app.Package -and -not $app.IsChocolatey) { $script:TenantPackages[(Get-MetaKey $app.Package $app.Source)] = $true } }
        foreach ($key in @($script:RecentDeploys.Keys)) {
            if ($script:RecentDeploys[$key] -gt (Get-Date).AddMinutes(-5)) { $script:TenantPackages[$key] = $true } else { $script:RecentDeploys.Remove($key) }
        }
        $items = foreach ($app in $script:TenantApps) { if ($app.Package -and -not $app.IsChocolatey) { @{ Source = $app.Source; Id = $app.Package } } }
        Start-MetaPrefetch -Items @($items)
        Update-TenantRows -Force
        Update-AppList
        Start-DependencyCheck
        Start-RuntimeCheck
        Start-StatusCheck
        Start-CountsTask
        Update-Readiness
    })
    Update-Readiness
}
Add-Click $ui.BtnTenantRefresh { $script:TenantApps = $script:TenantApps; Start-TenantRefresh }

function Start-CountsTask {
    $ids = @($script:TenantApps | Where-Object { -not $_.IsChocolatey -and $_.Package } | ForEach-Object { $_.Id })
    if ($ids.Count -eq 0 -or (Test-TaskRunning 'counts')) { return }
    $work = @'
param($Ids, $Fake)
$Ctx = if ($Fake) { New-InsightGraphContext -Invoke ([scriptblock]::Create($Fake)) } else { New-InsightGraphContext }
foreach ($Id in $Ids) {
    try { $S = Get-InsightAppInstallStatus -Context $Ctx -AppId $Id; [pscustomobject]@{ Id = $Id; Installed = $S.Installed; Failed = $S.Failed; Pending = $S.Pending; Stale = $S.NotReported7Days } }
    catch { [pscustomobject]@{ Id = $Id; Error = $_.Exception.Message } }
}
'@
    [void](Start-UiTask -Kind 'counts' -Title 'Reading the install counts' -Hidden -NeedsAuth -Arguments @{ Ids = $ids; Fake = $script:InsightFake } -Work $work -OnDone {
        param($Result, $Job)
        foreach ($r in @($Result | Where-Object { $_ -and $_.Id })) { $script:DeviceCounts[$r.Id] = $r }
        Update-TenantRows
    })
}

function Get-IntentText($App) {
    if ($App.IsChocolatey -or $App.IsDependency) { return 'Automatic' }
    $i = @([string]$App.Intents -split ',' | Where-Object { $_ })
    if ($i -contains 'required') { 'Required' } elseif ($i -contains 'available') { 'Available' } else { 'None' }
}

function Update-TenantRows {
    param([switch]$Force)
    if ($null -eq $script:TenantApps) {
        $script:TenantRowList.Clear()
        $ui.TxtTenantEmpty.Visibility = 'Visible'
        $ui.TxtTenantEmpty.Text = if (Test-SignedIn) { 'Reading the apps in the tenant ...' } else { 'Sign in to see the apps this tool created in your tenant.' }
        $ui.TxtTenantCount.Text = if (Test-SignedIn) { 'Reading the apps in the tenant ...' } else { 'Sign in to see the apps this tool created in your tenant.' }
        $ui.BannerRelease.Visibility = 'Collapsed'; $ui.BannerRuntime.Visibility = 'Collapsed'
        Update-TenantBadge
        Update-TenantButtons
        return
    }
    foreach ($app in $script:TenantApps) {
        if (-not $app.Package -or $app.IsChocolatey) { continue }
        $meta = $script:Shared.Meta[(Get-MetaKey $app.Package $app.Source)]
        $latest = if ($meta -and $meta.Found) { [string]$meta.Version } else { '' }
        $app.LatestVersion = $latest
        $app.UpdateAvailable = [bool]($app.Version -and $latest -and (Compare-PackageVersion $latest $app.Version) -gt 0)
    }
    $selected = if ($ui.LstTenant.SelectedItem) { $ui.LstTenant.SelectedItem.Data.Id } else { $null }
    $list = New-Object System.Collections.ArrayList
    foreach ($app in $script:TenantApps) { [void]$list.Add($app) }
    if ($script:RuntimeId) {
        [void]$list.Add([pscustomobject]@{ Id = $script:RuntimeId; DisplayName = 'winget runtime'; Package = ''; Source = 'Winget'; IsChocolatey = $false; IsDependency = $true; Version = ''; UpdateMode = ''; GraceHours = 0; Intents = ''; Schedule = $null; LatestVersion = ''; UpdateAvailable = $false })
    }
    $deps = @($list | Where-Object { $_.IsChocolatey -or $_.IsDependency })
    $ordered = @($deps) + @($list | Where-Object { -not ($_.IsChocolatey -or $_.IsDependency) })
    $rows = foreach ($app in $ordered) {
        $count = $script:DeviceCounts[$app.Id]
        $isDep = $app.IsChocolatey -or $app.IsDependency
        $title = if ($app.IsChocolatey) { 'Chocolatey' } else { $app.DisplayName }
        $sub = if ($app.IsChocolatey) { 'Dependency of the Chocolatey apps' } elseif ($app.IsDependency) { 'Dependency of the winget apps (App Installer for SYSTEM)' } else { "$($app.Package) $([char]0x00B7) $(Get-SourceLabel $app.Source)" }
        $ok = if ($count -and -not $count.Error) { "$($count.Installed) installed" } elseif ($isDep) { '' } else { '-' }
        $bad = if ($count -and -not $count.Error) { @($(if ($count.Failed) { "$($count.Failed) failed" }), $(if ($count.Pending) { "$($count.Pending) pending" })) | Where-Object { $_ } | Select-Object -First 1 } else { '' }
        $updates = if ($isDep) { 'Updated daily' } elseif ($app.UpdateMode -eq 'Custom') { "Ask user, $(if ($app.GraceHours % 24 -eq 0) { "$($app.GraceHours / 24) days" } else { "$($app.GraceHours) h" })" } elseif ($app.UpdateMode -eq 'Off') { 'Off' } else { if ($app.Schedule.TriggerStart -and -not $app.Schedule.TriggerWindow) { 'At startup' } else { 'Automatic' } }
        New-Row (@{
            Data = $app; Title = $title; Sub = $sub
            Version = $(if ($isDep) { 'latest' } elseif ($app.Version) { $app.Version } else { 'Always newest' })
            Newer = $(if ($app.UpdateAvailable) { "$($app.LatestVersion) available" } else { '' }); NewerVis = (ConvertTo-Vis $app.UpdateAvailable)
            Updates = $updates; Assigned = (Get-IntentText $app); Ok = $ok; Bad = $bad; BadVis = (ConvertTo-Vis ([bool]$bad)); Icon = $null; MonoVis = 'Visible'
        } + (Get-TileStyle $title))
    }
    $rows = @($rows)
    $keys = ($ordered | ForEach-Object { $_.Id }) -join '|'
    $same = $keys -eq $script:TenantKeys
    if ($same -and -not $Force) {
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $old = $script:TenantRowList[$i]
            foreach ($k in 'Newer', 'NewerVis', 'Ok', 'Bad', 'BadVis', 'Updates', 'Version', 'Assigned') { $old[$k] = $rows[$i][$k] }
            $old.Data = $rows[$i].Data
        }
    }
    else {
        $script:TenantKeys = $keys
        $script:TenantRowList.Clear()
        foreach ($r in $rows) { $script:TenantRowList.Add($r) }
        if ($selected) { $ui.LstTenant.SelectedItem = @($script:TenantRowList | Where-Object { $_.Data.Id -eq $selected })[0] }
    }
    $ui.TxtTenantEmpty.Visibility = ConvertTo-Vis ($rows.Count -eq 0)
    $ui.TxtTenantEmpty.Text = 'This tool has not created any app in the tenant yet. Pick apps under Apps.'
    $apps = @($ordered | Where-Object { -not ($_.IsChocolatey -or $_.IsDependency) }).Count
    $tenant = if ($script:Settings.TenantID) { $script:Settings.TenantID } else { 'the tenant' }
    $ui.TxtTenantCount.Text = "$apps app$(if ($apps -ne 1) { 's' }) and $($deps.Count) dependency app$(if ($deps.Count -ne 1) { 's' }) this tool created in $tenant"
    # Banners
    $updates = @($ordered | Where-Object UpdateAvailable)
    if ($updates.Count) {
        $u = $updates[0]
        $ui.BannerRelease.Visibility = 'Visible'
        $ui.TxtBannerRelease.Inlines.Clear()
        $b = New-Object System.Windows.Documents.Run "$($u.DisplayName) $($u.LatestVersion) is available."; $b.FontWeight = 'Bold'
        [void]$ui.TxtBannerRelease.Inlines.Add($b)
        [void]$ui.TxtBannerRelease.Inlines.Add((New-Object System.Windows.Documents.Run " The app is pinned to $($u.Version). Release it when you are ready.$(if ($updates.Count -gt 1) { " $($updates.Count - 1) more app(s) have updates." })"))
        $ui.BtnBannerRelease.Content = "Release $($u.LatestVersion)"
        $ui.BtnBannerRelease.Uid = $u.Id
    }
    else { $ui.BannerRelease.Visibility = 'Collapsed' }
    $noRuntime = @($script:WingetNoRuntime)
    $ui.BannerRuntime.Visibility = ConvertTo-Vis ($noRuntime.Count -gt 0)
    $ui.TxtBannerRuntime.Text = "$($noRuntime.Count) winget app$(if ($noRuntime.Count -ne 1) { 's' }) in the tenant ha$(if ($noRuntime.Count -ne 1) { 've' } else { 's' }) no winget runtime dependency yet: $(($noRuntime | ForEach-Object { $_.DisplayName }) -join ', ')."
    Update-TenantBadge
    Update-TenantButtons
}
$script:TenantKeys = ''
$script:WingetNoRuntime = @()

function Update-TenantBadge {
    $updates = @($script:TenantApps | Where-Object UpdateAvailable).Count
    $problems = @($script:DeviceCounts.Values | Where-Object { $_.Failed } | ForEach-Object { [int]$_.Failed } | Measure-Object -Sum).Sum
    $text = if ($updates) { "$updates update$(if ($updates -ne 1) { 's' })" } elseif ($problems) { "$problems problem$(if ($problems -ne 1) { 's' })" } else { '' }
    $ui.BadgeTenant.Visibility = ConvertTo-Vis ([bool]$text)
    $ui.TxtBadgeTenant.Text = $text
    $ui.BadgeTenant.Background = if ($updates -or -not $problems) { Get-Brush 'WarningBg' } else { Get-Brush 'ErrorBg' }
    $ui.TxtBadgeTenant.Foreground = if ($updates -or -not $problems) { Get-Brush 'Warning' } else { Get-Brush 'Danger' }
}

function Start-RuntimeCheck {
    # winget apps without the runtime dependency (hidden), for the banner and the panel
    if (-not (Test-SignedIn) -or (Test-TaskRunning 'runtimecheck')) { return }
    [void](Start-UiTask -Kind 'runtimecheck' -Title 'Checking the winget runtime dependency' -Hidden -NeedsAuth -Work 'Get-IntuneWingetAppsWithoutRuntime | ForEach-Object { [pscustomobject]@{ Id = $_.Id; DisplayName = $_.DisplayName } }' -OnDone {
        param($Result, $Job)
        $script:WingetNoRuntime = @($Result | Where-Object { $_ -and $_.Id })
        Update-TenantRows
    })
}
Add-Click $ui.BtnBannerRuntime {
    $ids = @($script:WingetNoRuntime | ForEach-Object { $_.Id })
    Start-RuntimeFix $ids
}
function Start-RuntimeFix([string[]]$Ids) {
    Update-UiToken
    [void](Start-UiTask -Kind 'runtime' -Title 'Adding the winget runtime dependency to winget apps' -Display 'winget runtime dependency' -NeedsAuth -Arguments @{ Ids = $Ids } -Work 'param($Ids) Add-IntuneWingetRuntimeDependency -AppId $Ids' -OnDone {
        param($Result, $Job)
        $added = @($Result | Where-Object { $_.Added }).Count
        if ($Job.Status -eq 'succeeded') { Show-Toast "Dependency added to $added app(s)." 'ok' }
        $script:WingetNoRuntime = @()
        Start-RuntimeCheck
        Update-TenantRows
    })
}

function Get-SelectedTenantApp { if ($ui.LstTenant.SelectedItem) { $ui.LstTenant.SelectedItem.Data } }

function Get-TenantVersion { if ($ui.CmbTenantVersion.SelectedIndex -le 0) { 'latest' } else { [string]$ui.CmbTenantVersion.SelectedItem } }
function Set-TenantVersionChoices($App, [string[]]$Versions) {
    $list = @('Always the newest version') + @($Versions | Where-Object { $_ })
    if ($App.Version -and $list -notcontains $App.Version) { $list += $App.Version }
    $ui.CmbTenantVersion.ItemsSource = $list
    $ui.CmbTenantVersion.SelectedIndex = if ($App.Version) { [array]::IndexOf($list, $App.Version) } else { 0 }
}
function Read-TenantPolicy {
    $mode = if ($ui.RbTenantOff.IsChecked) { 'Off' } elseif ($ui.RbTenantCustom.IsChecked) { 'Custom' } else { 'Startup' }
    @{ UpdateMode = $mode; GraceHours = (ConvertTo-GraceHours $ui.TxtTenantGrace.Text $ui.CmbTenantGraceUnit.SelectedIndex ($mode -eq 'Custom')) }
}
function Update-TenantScheduleText($App) {
    $sched = if ($script:TenantSchedule) { New-ChocoSchedule -Values $script:TenantSchedule -Base $App.Schedule } else { $App.Schedule }
    if (-not $sched) { $sched = Get-ChocoScheduleDefaults }
    $mode = try { Read-TenantPolicy } catch { @{ UpdateMode = 'Custom' } }
    $t = Format-ScheduleSummary $sched
    $ui.TxtTenantWhen.Text = switch ($mode.UpdateMode) { 'Off' { 'Not automatic: only versions you release here' } 'Custom' { 'When the user agrees, or at the deadline' } default { $t.When } }
    $ui.TxtTenantConditions.Text = if ($mode.UpdateMode -eq 'Off') { 'Intune installs a released version right away' } else { $t.Conditions }
}

function Show-TenantPolicy($App) {
    $id = "$($App.Id)|$($App.Version)|$($App.UpdateMode)|$($App.GraceHours)"
    if ($script:TenantPolicyApp -eq $id) { return }
    $script:TenantPolicyApp = $id
    $script:TenantSchedule = $null
    $inDays = $App.GraceHours -gt 0 -and $App.GraceHours % 24 -eq 0
    $ui.TxtTenantGrace.Text = [string]$(if ($inDays) { $App.GraceHours / 24 } else { $App.GraceHours }); $ui.CmbTenantGraceUnit.SelectedIndex = if ($inDays) { 1 } else { 0 }
    switch ($App.UpdateMode) { 'Off' { $ui.RbTenantOff.IsChecked = $true } 'Custom' { $ui.RbTenantCustom.IsChecked = $true } default { $ui.RbTenantStartup.IsChecked = $true } }
    Set-TenantVersionChoices $App @()
    Update-TenantScheduleText $App
    [void](Start-UiTask -Kind 'versions' -Title 'Reading the package versions' -Package $App.Package -Pool $script:MetaPool -Hidden -Arguments @{ Package = $App.Package; Source = $App.Source } `
        -Work 'param($Package, $Source) Get-IntuneChocoPackageVersions -Package $Package -Source $Source' -OnDone {
            param($Result, $Job)
            $now = Get-SelectedTenantApp
            if ($Job.Status -ne 'succeeded' -or -not $now -or $now.Package -ne $Job.Package) { return }
            $chosen = $ui.CmbTenantVersion.SelectedItem
            Set-TenantVersionChoices $now @($Result | ForEach-Object { [string]$_ })
            if ($chosen -and @($ui.CmbTenantVersion.ItemsSource) -contains $chosen) { $ui.CmbTenantVersion.SelectedItem = $chosen }
        })
}

function Update-TenantButtons {
    $app = Get-SelectedTenantApp
    $on = [bool]$app
    $ui.TxtTenantAppEmpty.Visibility = ConvertTo-Vis (-not $on)
    $ui.ScrollTenantApp.Visibility = ConvertTo-Vis $on
    if (-not $on) { $script:TenantPolicyApp = ''; return }
    $isDep = $app.IsChocolatey -or $app.IsDependency
    $t = Get-TileStyle $(if ($app.IsChocolatey) { 'Chocolatey' } else { $app.DisplayName })
    $ui.BoxTenantIcon.Background = ConvertTo-Brush $t.TileBg; $ui.TxtTenantMono.Text = $t.Mono; $ui.TxtTenantMono.Foreground = ConvertTo-Brush $t.TileFg
    $ui.TxtTenantAppTitle.Text = if ($app.IsChocolatey) { 'Chocolatey' } else { $app.DisplayName }
    $ui.TxtTenantAppSub.Text = if ($isDep) { 'Dependency app, updated daily' } else { "$($app.Package) $([char]0x00B7) $(Get-SourceLabel $app.Source) $([char]0x00B7) $(Get-IntentText $app)" }
    $busy = Test-TaskRunning 'policy'
    $ui.BtnTenantOpen.IsEnabled = $true
    $ui.BtnTenantRemove.IsEnabled = (Test-SignedIn) -and -not (Test-TaskRunning 'remove') -and -not $app.IsDependency
    $ui.GbTenantPolicy.Visibility = ConvertTo-Vis (-not $isDep)
    $ui.BtnTenantApply.Visibility = ConvertTo-Vis (-not $isDep)
    $ui.BtnTenantTest.IsEnabled = -not $isDep -and -not (Test-TaskRunning 'test')
    $ui.BtnTenantTest.Visibility = ConvertTo-Vis (-not $isDep)
    $ui.BtnTenantRelease.Visibility = ConvertTo-Vis ($app.UpdateAvailable -and -not $isDep)
    $ui.TxtTenantAvailableNote.Visibility = ConvertTo-Vis ((-not $isDep) -and (@([string]$app.Intents -split ',') -contains 'available') -and (@([string]$app.Intents -split ',') -notcontains 'required'))
    $noRuntime = @($script:WingetNoRuntime | Where-Object { $_.Id -eq $app.Id }).Count -gt 0
    $ui.TxtDependencyNote.Visibility = ConvertTo-Vis $noRuntime
    $ui.TxtDependencyNote.Text = if ($noRuntime) { 'This winget app has no winget runtime dependency yet. Add winget runtime dependency (banner above the list) fixes it.' } else { '' }
    if ($isDep) { $script:TenantPolicyApp = ''; return }
    $ui.BtnTenantApply.IsEnabled = (Test-SignedIn) -and -not $busy
    $ui.BtnTenantRelease.IsEnabled = (Test-SignedIn) -and -not $busy
    $ui.BtnTenantRelease.Content = if ($app.UpdateAvailable) { "Release $($app.LatestVersion)" } else { 'Release update' }
    $ui.PanelTenantGrace.Visibility = ConvertTo-Vis ([bool]$ui.RbTenantCustom.IsChecked)
    Show-TenantPolicy $app
}
$ui.LstTenant.Add_SelectionChanged({ try { Update-TenantButtons } catch { Show-Error $_.Exception.Message } })
foreach ($n in 'RbTenantOff', 'RbTenantStartup', 'RbTenantCustom') {
    $ui[$n].Add_Checked({ $app = Get-SelectedTenantApp; if ($app -and $script:TenantPolicyApp) { $ui.PanelTenantGrace.Visibility = ConvertTo-Vis ([bool]$ui.RbTenantCustom.IsChecked); Update-TenantScheduleText $app } })
}
$ui.LstTenant.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
    param($s, $e)
    try {
        $b = $e.OriginalSource
        if ($b -is [System.Windows.Controls.Button] -and $b.Uid -eq 'devices' -and $b.DataContext -is [IntuneChoco.Row]) {
            $app = $b.DataContext.Data
            if (-not ($app.IsChocolatey -or $app.IsDependency)) { Show-AppStatus $app }
        }
    }
    catch { Show-Error $_.Exception.Message }
})

function Start-AppApply {
    # Rebuilds the package with the new settings and changes the app in Intune (in place or through supersedence); devices follow on their own
    param([Parameter(Mandatory)]$App, [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][hashtable]$Policy, $Schedule)
    if (-not (Test-SignedIn)) { throw 'Sign in to Intune first (Sign in, top right).' }
    Update-UiToken
    $arguments = @{ AppId = $App.Id; Version = $Version; UpdateMode = $Policy.UpdateMode; GraceHours = $Policy.GraceHours; Schedule = $Schedule }
    $work = @'
param($AppId, $Version, $UpdateMode, $GraceHours, $Schedule)
if ($Schedule) { Update-IntuneChocoApp -AppId $AppId -Version $Version -UpdateMode $UpdateMode -GraceHours $GraceHours -Schedule $Schedule }
else { Publish-IntuneChocoRelease -AppId $AppId -Version $Version -UpdateMode $UpdateMode -GraceHours $GraceHours }
'@
    [void](Start-UiTask -Kind 'policy' -Title "Update settings of $($App.DisplayName): $(Format-UpdateText $Policy.UpdateMode $Policy.GraceHours), version $Version" -Display $App.DisplayName -Package $App.Package -NeedsAuth -Arguments $arguments -Work $work -OnDone {
        param($Result, $Job)
        if ($Job.Status -eq 'succeeded') {
            $via = @($Result | Where-Object { $_.Path }) | Select-Object -First 1
            Write-UiLog "[$($Job.Package)] changed in Intune$(if ($via -and $via.Path -eq 'Supersedence') { ' (new app superseding the old one)' }). Devices pick it up at their next Intune check." 'Success'
            Show-Toast "$($Job.Display) was changed in Intune." 'ok'
        }
        $script:TenantApps = $null; $script:TenantPolicyApp = ''
        Start-TenantRefresh
    })
    Update-TenantButtons
}
Add-Click $ui.BtnTenantApply {
    $app = Get-SelectedTenantApp
    if (-not $app) { return }
    $policy = Read-TenantPolicy
    $version = Get-TenantVersion
    $text = "Change '$($app.DisplayName)' in Intune?`n`nVersion: $(if ($version -eq 'latest') { 'always the newest' } else { $version })`nUpdates: $(Format-UpdateText $policy.UpdateMode $policy.GraceHours)`n`nThe package is rebuilt and uploaded. Apps that are only Available are replaced by a new app that supersedes the old one."
    if (-not (Confirm-Action $text 'Apply in Intune')) { return }
    Start-AppApply -App $app -Version $version -Policy $policy -Schedule $script:TenantSchedule
}
function Start-ReleaseApp($App) {
    if (-not $App -or -not $App.UpdateAvailable) { return }
    if (-not (Confirm-Action "Release version $($App.LatestVersion) of '$($App.DisplayName)'?`n`nIt goes from $($App.Version) to $($App.LatestVersion). Devices install it according to the update mode of the app: $(Format-UpdateText $App.UpdateMode $App.GraceHours).`n`nApps that are only Available are updated through a new app that supersedes the old one." 'Release update')) { return }
    Start-AppApply -App $App -Version $App.LatestVersion -Policy @{ UpdateMode = $App.UpdateMode; GraceHours = $App.GraceHours }
}
Add-Click $ui.BtnTenantRelease { Start-ReleaseApp (Get-SelectedTenantApp) }
Add-Click $ui.BtnBannerRelease { $id = $ui.BtnBannerRelease.Uid; Start-ReleaseApp @($script:TenantApps | Where-Object { $_.Id -eq $id })[0] }
Add-Click $ui.BtnTenantSchedule {
    $app = Get-SelectedTenantApp
    if (-not $app) { return }
    $sched = if ($script:TenantSchedule) { New-ChocoSchedule -Values $script:TenantSchedule -Base $app.Schedule } elseif ($app.Schedule) { $app.Schedule } else { Get-ChocoScheduleDefaults }
    $grace = (Read-TenantPolicy).GraceHours
    Show-ScheduleDialog -Mode 'App' -Schedule $sched -Title "When $($app.DisplayName) updates on devices" -App $app -GraceHours $grace
}
Add-Click $ui.BtnTenantTest {
    $app = Get-SelectedTenantApp
    if (-not $app) { return }
    Start-PackageTest -Package $app.Package -Source $app.Source -Title $app.DisplayName -Version (Get-TenantVersion) -Policy (Read-TenantPolicy)
}
Add-Click $ui.BtnTenantRemove {
    $app = Get-SelectedTenantApp
    if (-not $app) { return }
    $others = @($script:TenantApps | Where-Object { -not $_.IsChocolatey -and $_.Source -eq 'Chocolatey' }).Count
    if ($app.IsChocolatey -and $others -gt 0) { throw "Chocolatey is the dependency of the $others app(s) created by this tool. Remove those first." }
    if (-not (Confirm-Action "Remove '$($app.DisplayName)' from Intune?`n`nThe app and its assignments are deleted in the tenant. Devices keep the installed software and its update task; nothing is uninstalled." 'Remove from Intune')) { return }
    Update-UiToken
    [void](Start-UiTask -Kind 'remove' -Title "Removing $($app.DisplayName) from Intune" -Display $app.DisplayName -Package $app.Package -NeedsAuth -Arguments @{ Id = $app.Id; Source = $app.Source } -Work 'param($Id, $Source) Remove-IntuneChocoApplication -Id $Id' -OnDone {
        param($Result, $Job)
        if ($Job.Status -eq 'succeeded') {
            Write-UiLog "[$($Job.Package)] removed from Intune." 'Success'
            Show-Toast "$($Job.Display) was removed from Intune." 'ok'
            if ($Job.Package) { $script:RecentDeploys.Remove((Get-MetaKey $Job.Package $Job.Source)) }
        }
        $script:TenantApps = $null
        Start-TenantRefresh
    })
    Update-TenantButtons
}
Add-Click $ui.BtnTenantOpen {
    $app = Get-SelectedTenantApp
    if ($app) { Start-Process "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$($app.Id)" }
}

# ---------------------------------------------------------------- status of one app
$script:StatusApp = $null
$script:StatusData = $null
function Show-AppStatus($App) {
    $script:StatusApp = $App
    $script:StatusData = $null
    Show-Page 'Status'
    $ui.TxtStatusTitle.Text = "$($App.DisplayName) on devices"
    $ui.TxtStatusSub.Text = 'Intune install status, plus the update log each device reports. Reading ...'
    foreach ($n in 'TxtStatOk', 'TxtStatWait', 'TxtStatFail', 'TxtStatStale') { $ui[$n].Text = '-' }
    $script:DeviceRowList.Clear()
    $ui.BoxDeviceLog.Visibility = 'Collapsed'
    $ui.TxtDevicesEmpty.Visibility = 'Visible'; $ui.TxtDevicesEmpty.Text = 'Reading the install status ...'
    Update-StatusBanner
    Start-StatusLoad
}
$script:DeviceRowList = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.LstDevices.ItemsSource = $script:DeviceRowList

function Update-StatusBanner {
    $st = $script:StatusScript
    $show = $st -and $st.State -ne 'Present'
    $ui.BoxStatusScript.Visibility = ConvertTo-Vis ([bool]$show)
    if (-not $show) { return }
    if ($st.State -eq 'Missing') { $ui.TxtStatusScript.Text = 'The status script is not set up. Without it you see the Intune install status, but not the log the device reports. It runs as a Remediations detection script on all devices, once an hour.'; $ui.BtnStatusScript.Visibility = 'Visible' }
    else { $ui.TxtStatusScript.Text = "The device log is not available in this tenant: Remediations need a Windows Enterprise E3/E5 (or A3/A5, VDA) license. The install status above still works. $($st.Reason)"; $ui.BtnStatusScript.Visibility = 'Collapsed' }
}
Add-Click $ui.BtnStatusScript { Start-StatusScriptSetup }
Add-Click $ui.BtnStatusBack { Show-Page 'Tenant' }
Add-Click $ui.BtnStatusRefresh { if ($script:StatusApp) { Show-AppStatus $script:StatusApp } }

function Start-StatusLoad {
    $app = $script:StatusApp
    if (-not $app) { return }
    Update-UiToken
    $work = @'
param($AppId, $Package, $Fake)
$Ctx = if ($Fake) { New-InsightGraphContext -Invoke ([scriptblock]::Create($Fake)) } else { New-InsightGraphContext }
$St = Get-InsightAppInstallStatus -Context $Ctx -AppId $AppId
$Script = $null; $Runs = @()
try { $Script = Get-InsightStatusScriptState -Context $Ctx } catch { }
if ($Script) {
    try { $Runs = @(Get-InsightDeviceRunStates -Context $Ctx -ScriptId $Script.id) } catch { }
    $St = Merge-InsightStatus -InstallStatus $St -Package $Package -RunStates $Runs
}
[pscustomobject]@{ Status = $St; HasScript = [bool]$Script }
'@
    [void](Start-UiTask -Kind 'status' -Title "Reading the install status of $($app.DisplayName)" -Display "Status of $($app.DisplayName)" -Hidden -NeedsAuth -Arguments @{ AppId = $app.Id; Package = $app.Package; Fake = $script:InsightFake } -Work $work -OnDone {
        param($Result, $Job)
        $r = @($Result | Where-Object { $_ -and $_.Status }) | Select-Object -First 1
        if ($Job.Status -ne 'succeeded' -or -not $r) {
            $ui.TxtDevicesEmpty.Visibility = 'Visible'
            $ui.TxtDevicesEmpty.Text = 'The install status could not be read. Check that the sign-in has the permission DeviceManagementApps.Read.All (Start > App registration).'
            $ui.TxtStatusSub.Text = 'Intune install status, plus the update log each device reports.'
            return
        }
        $script:StatusData = $r
        Show-StatusRows $r.Status
    })
}

function Show-StatusRows($St) {
    $ui.TxtStatOk.Text = [string]$St.Installed; $ui.TxtStatWait.Text = [string]$St.Pending; $ui.TxtStatFail.Text = [string]$St.Failed; $ui.TxtStatStale.Text = [string]$St.NotReported7Days
    $ui.TxtStatusSub.Text = "Intune install status, plus the update log each device reports. Updated $((Get-Date).ToString('HH:mm'))."
    $rows = foreach ($d in @($St.Devices | Sort-Object @{ Expression = { switch -Wildcard ($_.State) { 'failed' { 0 } 'uninstallFailed' { 0 } 'pendingInstall' { 1 } default { 2 } } } }, DeviceName)) {
        $last = $d.LastResult
        $label, $kind = if ($d.State -in 'failed', 'uninstallFailed') { 'Failed', 'bad' } elseif ($d.State -eq 'pendingInstall') { 'Waiting', 'warn' } elseif ($d.NotReported) { 'No report', 'gray' } elseif ($d.State -eq 'installed') { 'Installed', 'ok' } else { $d.State, 'gray' }
        $cause = if ($last -and -not $last.Ok -and $last.Cause) { [string]$last.Cause } elseif ($d.Cause) { [string]$d.Cause } elseif ($label -eq 'No report') { "No report for 7 days" } else { '' }
        $code = if ($last -and -not $last.Ok -and $null -ne $last.ExitCode) { "exit $($last.ExitCode)" } elseif ($d.ErrorCode) { [string]$d.ErrorCode } else { '' }
        $when = if ($d.LastReport) { $t = ([datetime]$d.LastReport).ToLocalTime(); if ($t.Date -eq (Get-Date).Date) { "Today $($t.ToString('HH:mm'))" } else { $t.ToString('d MMM') } } else { '' }
        New-Row @{ Data = $d; Title = $d.DeviceName; Sub = $d.User; Status = $label; StatusBg = $script:PillColors[$kind][0]; StatusFg = $script:PillColors[$kind][1]
            Version = $d.Version; Cause = $cause; Code = $code; When = $when }
    }
    $script:DeviceRowList.Clear()
    foreach ($r in @($rows)) { $script:DeviceRowList.Add($r) }
    $ui.TxtDevicesEmpty.Visibility = ConvertTo-Vis ($script:DeviceRowList.Count -eq 0)
    $ui.TxtDevicesEmpty.Text = 'No device reports this app yet.'
    if ($script:DeviceRowList.Count) { $ui.LstDevices.SelectedIndex = 0 }
}
$ui.LstDevices.Add_SelectionChanged({ try { Show-DeviceLog } catch { Show-Error $_.Exception.Message } })
function Show-DeviceLog {
    $row = $ui.LstDevices.SelectedItem
    if (-not $row) { $ui.BoxDeviceLog.Visibility = 'Collapsed'; return }
    $d = $row.Data
    $ui.BoxDeviceLog.Visibility = 'Visible'
    $ui.TxtDeviceLogTitle.Text = "Log from $($d.DeviceName) (reported by the device)"
    $l = $d.LastResult
    $lines = @()
    if ($l) {
        $when = if ($l.LastAttempt) { [string]$l.LastAttempt } else { '' }
        if ($l.Ok) { $lines += "$when  $($l.Package): version $($l.InstalledVersion), no problem reported" }
        else {
            $lines += "$when  $($l.Action) $($l.Package): installed $($l.InstalledVersion), target $($l.TargetVersion)"
            $lines += "$when  exit code $($l.ExitCode): $($l.Cause)"
        }
    }
    $ui.TxtDeviceLog.Text = if ($lines.Count) { $lines -join "`n" } elseif ($script:StatusScript -and $script:StatusScript.State -eq 'Present') { 'This device has not reported a log for this app yet. Devices report when the result changes, otherwise every 7 days.' } else { 'No device log: the status script is not set up (see above).' }
    $ui.TxtRetryHint.Text = if ($d.State -in 'failed', 'uninstallFailed') { 'The device retries by itself at the next chance (see Failed update in the schedule). To retry now, run a Sync from Intune on the device, or collect diagnostics first when the cause is not clear.' } else { '' }
}
Add-Click $ui.BtnDiagnostics {
    $row = $ui.LstDevices.SelectedItem
    if (-not $row) { return }
    $info = Get-InsightDiagnosticsInfo -ManagedDeviceId $row.Data.DeviceId -Package $script:StatusApp.Package
    $ui.TxtRetryHint.Text = $info.Hint
    Start-Process $info.Url
}

# ---------------------------------------------------------------- import dialog
$script:ImportSource = 'This'
$script:ImportRowList = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.LstImport.ItemsSource = $script:ImportRowList
$script:ImportContext = $null

$script:KindLabels = @{ ToolCreated = 'This tool'; ChocolateyWin32 = 'Win32 with Chocolatey'; WingetWin32 = 'Win32 with winget'; StoreApp = 'Store app (new)'; Other = 'Win32, own installer'; Export = 'Export file' }
$script:ActionLabels = @{ Managed = 'Already managed'; TakeOver = 'Take over'; KeepAsStoreApp = 'Keep as Store app'; SkipDuplicate = 'Skip, duplicate'; CannotManage = 'Cannot be managed'; Recreate = 'Create here' }
function Show-ImportDialog {
    if ($script:ImportSource -eq 'This' -and (Test-SignedIn) -and -not $script:ImportApps) { Start-ImportRead }
    Show-Dialog 'DlgImport'
    Update-ImportRows
}
$script:ImportApps = $null
function Update-ImportRows {
    $apps = @($script:ImportApps | Where-Object { $_ -and -not $_.Infrastructure })
    $rows = foreach ($a in $apps) {
        $pick = $a.ProposedAction -in 'TakeOver', 'Recreate'
        $kind = $script:KindLabels[[string]$a.Kind]; if (-not $kind) { $kind = [string]$a.Kind }
        $kc = switch ($a.Kind) { 'ToolCreated' { 'info' } 'ChocolateyWin32' { 'gray' } 'WingetWin32' { 'ok' } 'StoreApp' { 'ok' } default { 'gray' } }
        $settings = if ($a.Package -and $a.ProposedAction -ne 'CannotManage') { "$(if ($a.Version) { "Version $($a.Version) pinned" } else { 'Latest' }), $(Format-UpdateText $a.UpdateMode $a.GraceHours)" } else { $a.Reason }
        New-Row @{ Data = $a; Title = $a.DisplayName; Sub = $(if ($a.Kind -eq 'Export') { 'From the export file' } else { $a.Reason }); Kind = $kind; KindBg = $script:PillColors[$kc][0]; KindFg = $script:PillColors[$kc][1]
            Found = $(if ($a.Package) { "$($a.Source): $($a.Package)" } else { '' }); Settings = $settings; Action = $(if ($script:ActionLabels[[string]$a.ProposedAction]) { $script:ActionLabels[[string]$a.ProposedAction] } else { $a.ProposedAction })
            Checked = $pick; CanPick = $pick; Opacity = $(if ($pick -or $a.ProposedAction -eq 'Managed') { 1 } else { 0.6 }) }
    }
    $script:ImportRowList.Clear()
    foreach ($r in @($rows)) { $script:ImportRowList.Add($r) }
    $ui.TxtImportEmpty.Visibility = ConvertTo-Vis ($script:ImportRowList.Count -eq 0)
    $ui.TxtImportEmpty.Text = if ($script:ImportReading) { 'Reading the apps ...' } elseif ($script:ImportSource -eq 'This' -and -not (Test-SignedIn)) { 'Sign in first.' } elseif ($script:ImportSource -eq 'Other') { 'Enter the tenant and the client ID of the app registration there, then sign in and read.' } elseif ($script:ImportSource -eq 'File') { 'Choose an export file.' } else { 'No apps found.' }
    Update-ImportSummary
}
$script:ImportReading = $false
function Get-ImportChecked { @($script:ImportRowList | Where-Object { $_['Checked'] -eq 'True' } | ForEach-Object { $_.Data }) }
function Update-ImportSummary {
    $checked = @(Get-ImportChecked).Count
    $pickable = @($script:ImportRowList | Where-Object { $_['CanPick'] -eq 'True' }).Count
    $ui.TxtImportSummary.Text = "$checked of $($script:ImportRowList.Count) apps selected. " + $(if ($script:ImportSource -eq 'This') { 'Taken-over apps get the new scripts with their next update settings change; nothing changes on devices now.' } else { 'The apps are created in this tenant with their settings; assignments start as None.' })
    $ui.BtnImportGo.Content = if ($script:ImportSource -eq 'This') { "Take over $checked app$(if ($checked -ne 1) { 's' })" } else { "Create $checked app$(if ($checked -ne 1) { 's' })" }
    $ui.BtnImportGo.IsEnabled = $checked -gt 0 -and (Test-SignedIn)
    $ui.BtnImpExport.IsEnabled = @($script:ImportApps | Where-Object { $_.Managed -and -not $_.Infrastructure }).Count -gt 0
}
$ui.LstImport.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
    param($s, $e)
    $b = $e.OriginalSource
    if ($b -is [System.Windows.Controls.CheckBox] -and $b.DataContext -is [IntuneChoco.Row]) { $b.DataContext['Checked'] = [string][bool]$b.IsChecked; Update-ImportSummary }
})
function Set-ImportSource([string]$Source) {
    $script:ImportSource = $Source
    $ui.PanelImpOther.Visibility = ConvertTo-Vis ($Source -eq 'Other'); $ui.PanelImpFile.Visibility = ConvertTo-Vis ($Source -eq 'File')
    $script:ImportApps = $null
    if ($Source -eq 'This' -and (Test-SignedIn)) { Start-ImportRead }
    Update-ImportRows
}
$ui.RbImpThis.Add_Checked({ if ($script:OpenDialog -eq 'DlgImport') { Set-ImportSource 'This' } })
$ui.RbImpOther.Add_Checked({ if ($script:OpenDialog -eq 'DlgImport') { Set-ImportSource 'Other' } })
$ui.RbImpFile.Add_Checked({ if ($script:OpenDialog -eq 'DlgImport') { Set-ImportSource 'File' } })

function Start-ImportRead {
    param([string]$TenantID, [string]$ClientID)
    if (Test-TaskRunning 'importread') { return }
    Update-UiToken
    $script:ImportReading = $true
    $work = @'
param($Mode, $Grace, $Fake, $OtherTenant, $OtherClient, $Authority, $UrlHandler)
if ($OtherTenant) {
    $Params = @{ TenantID = $OtherTenant; ClientID = $OtherClient; ShouldCancel = { $Shared.CancelSignIn } }
    if ($Authority) { $Params.Authority = $Authority }
    if ($UrlHandler) { $Params.UrlHandler = [scriptblock]::Create($UrlHandler) }
    $Ctx = Get-InsightOtherTenantContext @Params
}
else { $Ctx = if ($Fake) { New-InsightGraphContext -Invoke ([scriptblock]::Create($Fake)) } else { New-InsightGraphContext } }
Get-InsightTenantApps -Context $Ctx -DefaultUpdateMode $Mode -DefaultGraceHours $Grace
'@
    $args2 = @{ Mode = $script:Settings.UpdateMode; Grace = [int]$script:Settings.GraceHours; Fake = $script:InsightFake; OtherTenant = $TenantID; OtherClient = $ClientID; Authority = $script:SignInTest.Authority; UrlHandler = $script:SignInTest.UrlHandler }
    $script:Shared.CancelSignIn = $false
    [void](Start-UiTask -Kind 'importread' -Title $(if ($TenantID) { "Reading the apps of $TenantID" } else { 'Reading the apps in the tenant for the import' }) -Display 'Import: read apps' -Pool $script:UserPool -NeedsAuth -Arguments $args2 -Work $work -Hidden -OnDone {
        param($Result, $Job)
        $script:ImportReading = $false
        $apps = @($Result | ForEach-Object { $_ } | Where-Object { $_ -and $_.PSObject.Properties["ProposedAction"] })
        if ($Job.Spec.Arguments.OtherTenant) {
            # Apps of another tenant are recreated here: everything this tool manages or can take over becomes a candidate
            foreach ($a in $apps) { if ($a.Package -and $a.Source -in 'Chocolatey', 'Winget' -and $a.ProposedAction -in 'Managed', 'TakeOver') { $a.ProposedAction = 'Recreate' } }
        }
        else { $script:ImportExisting = $apps }
        $script:ImportApps = $apps
        if ($Job.Status -eq 'failed') { Show-Toast 'The apps could not be read, see Activity.' 'bad' }
        if ($script:OpenDialog -eq 'DlgImport') { Update-ImportRows }
    })
}
$script:ImportExisting = @()
Add-Click $ui.BtnImpRead {
    if (-not $ui.TxtImpTenant.Text.Trim() -or -not $ui.TxtImpClient.Text.Trim()) { throw 'Enter the tenant and the client ID of the app registration there first.' }
    Start-ImportRead -TenantID $ui.TxtImpTenant.Text.Trim() -ClientID $ui.TxtImpClient.Text.Trim()
    Update-ImportRows
}
function Read-ImportFile([string]$Path) {
    $script:ImportApps = @(Read-InsightExportFile -Path $Path)
    Update-ImportRows
}
Add-Click $ui.BtnImpOpenFile {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Export file'; $dlg.Filter = 'Export files (*.json)|*.json|All files (*.*)|*.*'
    if ($dlg.ShowDialog($window)) { Read-ImportFile $dlg.FileName }
}
function Export-ManagedApps([string]$Path) {
    $count = Export-InsightManagedApps -Apps @($script:ImportApps) -Path $Path
    Write-UiLog "$count app(s) exported to $Path." 'Success'
    Show-Toast "$count app(s) exported." 'ok'
}
Add-Click $ui.BtnImpExport {
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Title = 'Export managed apps'; $dlg.Filter = 'Export files (*.json)|*.json'; $dlg.FileName = 'IntuneChocoDeployment-apps.json'
    if ($dlg.ShowDialog($window)) { Export-ManagedApps $dlg.FileName }
}
Add-Click $ui.BtnImportCancel { Close-Dialog }
Add-Click $ui.BtnImportGo {
    $picked = @(Get-ImportChecked)
    if ($picked.Count -eq 0) { return }
    Update-UiToken
    if ($script:ImportSource -eq 'This') {
        $work = @'
param($Apps, $Fake)
$Ctx = if ($Fake) { New-InsightGraphContext -Invoke ([scriptblock]::Create($Fake)) } else { New-InsightGraphContext }
Set-InsightAppTakeOver -Context $Ctx -Apps $Apps
'@
        [void](Start-UiTask -Kind 'takeover' -Title "Taking over $($picked.Count) app(s)" -Display 'Import: take over' -NeedsAuth -Arguments @{ Apps = $picked; Fake = $script:InsightFake } -Work $work -OnDone {
            param($Result, $Job)
            $done = @($Result | Where-Object { $_.Done }).Count
            if ($Job.Status -eq 'succeeded') { Show-Toast "$done app(s) taken over." 'ok' }
            $script:TenantApps = $null; $script:ImportApps = $null
            Start-TenantRefresh
        })
    }
    else {
        $work = 'param($Candidates, $Existing) New-InsightRecreatedApps -Candidates $Candidates -ExistingApps $Existing'
        [void](Start-UiTask -Kind 'takeover' -Title "Creating $($picked.Count) app(s) from the import" -Display 'Import: create apps' -NeedsAuth -Arguments @{ Candidates = $picked; Existing = @($script:ImportExisting) } -Work $work -OnDone {
            param($Result, $Job)
            $done = @($Result | Where-Object { $_.Done }).Count
            if ($Job.Status -eq 'succeeded') { Show-Toast "$done app(s) created from the import." 'ok' }
            $script:TenantApps = $null
            Start-TenantRefresh
        })
    }
    Close-Dialog
    Show-Page 'Activity'
}
Add-Click $ui.BtnImport { Show-ImportDialog }

# ---------------------------------------------------------------- activity
$ui.LstJobs.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
    param($s, $e)
    try {
        $b = $e.OriginalSource
        if ($b -isnot [System.Windows.Controls.Button] -or $b.DataContext -isnot [IntuneChoco.Row]) { return }
        $job = $b.DataContext.Data
        if ($b.Uid -eq 'log') { $job.LogOpen = -not $job.LogOpen; Update-JobRow $job }
        elseif ($b.Uid -eq 'retry') { Restart-Job $job }
    }
    catch { Show-Error $_.Exception.Message }
})
function Restart-Job($Job) {
    $spec = $Job.Spec
    if (-not $spec) { return }
    if ($spec.NeedsAuth) { Update-UiToken }
    $script:JobRows.Remove($Job.Row)
    [void](Start-UiTask @spec)
}
Add-Click $ui.BtnLogClear {
    foreach ($row in @($script:JobRows)) { if ($row.Data.Status -notin 'queued', 'running') { $script:JobRows.Remove($row) } }
}
Add-Click $ui.BtnLogFolder { New-Item -Path $script:LogFolder -ItemType Directory -Force | Out-Null; Start-Process explorer.exe $script:LogFolder }
$script:JobRows.Add_CollectionChanged({
    $ui.TxtJobsEmpty.Visibility = ConvertTo-Vis ($script:JobRows.Count -eq 0)
})

# ---------------------------------------------------------------- sandbox test
function Start-PackageTest {
    param([Parameter(Mandatory)][string]$Package, [Parameter(Mandatory)][string]$Source, [string]$Title, [string]$Version, [hashtable]$Policy)
    if (Test-TaskRunning 'test') { throw 'A sandbox test is already running (Windows Sandbox runs one at a time).' }
    if (-not (Find-SandboxStudio)) { throw 'MSIX Sandbox Studio (WindowsSandboxMSIXInstaller) was not found. Enter its folder under Settings > Sandbox test.' }
    if ($Source -eq 'Winget' -and -not $script:ModuleState.Winget) { throw 'winget packages need the Microsoft.WinGet.Client module: install it under Settings > Components.' }
    $name = if ($Title) { $Title } else { $Package }
    $arguments = @{ Package = $Package; Source = $Source; Version = $Version; UpdateMode = $Policy.UpdateMode; GraceHours = $Policy.GraceHours }
    $work = 'param($Package, $Source, $Version, $UpdateMode, $GraceHours) Test-IntuneChocoPackage -ChocoName $Package -Source $Source -Version $Version -UpdateMode $UpdateMode -GraceHours $GraceHours'
    [void](Start-UiTask -Kind 'test' -Title "Sandbox test of ${name}: run Install, Detect and Uninstall in the sandbox, then report the result there" -Display "Sandbox: $name" -Package $Package -Pool $script:TestPool -Arguments $arguments -Work $work -OnDone {
        param($Result, $Job)
        $outcome = @($Result | Where-Object { $_.Verdict }) | Select-Object -First 1
        if ($Job.Status -eq 'failed' -or -not $outcome) { Write-UiLog "[$($Job.Package)] the sandbox test could not run, see above." 'Error' }
        elseif ($outcome.Verdict -eq 'Passed') { Write-UiLog "[$($Job.Package)] sandbox test passed." 'Success'; Show-Toast "$($Job.Display) passed." 'ok' }
        else { Write-UiLog "[$($Job.Package)] sandbox test failed: $($outcome.Message)" 'Warning'; Show-Toast "Sandbox test failed: $($outcome.Message)" 'warn' }
        Update-SelectionBar
        Update-TenantButtons
    })
    Update-SelectionBar
    Update-TenantButtons
}

function Assert-SignInSettings {
    if (-not $script:Settings.TenantID -or -not $script:Settings.ClientID) {
        Show-Page 'Settings'
        throw 'Enter tenant and the client ID of your app registration first (Settings), then sign in.'
    }
    if (-not $script:ModuleState.Ok) {
        Show-Page 'Settings'
        throw "IntuneWin32App $($script:MinimumModuleVersion) or newer is required (Settings > Components)."
    }
}

function Connect-Intune {
    param([ValidateSet('Browser', 'Keevault')][string]$Method = 'Browser')
    Assert-SignInSettings
    $tenant = $script:Settings.TenantID
    $clientId = $script:Settings.ClientID
    if ($Method -eq 'Keevault') {
        # Keevault and the embedded sign-in window take the foreground; the tool keeps painting meanwhile but takes no clicks
        $window.IsEnabled = $false
        $window.Cursor = 'Wait'
        try {
            $pump = { $window.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::Background) }
            $token = Connect-IntuneChocoWithKeevault -TenantID $tenant -ClientID $clientId -CacheFolder (Join-Path $script:WorkRoot 'WebView2') -Owner $window -OnWait $pump -OnAccount { param($User) Resolve-AccountTenant $User }
            Set-IntuneChocoToken -TokenResponse $token -TenantID $token.SignInTenantID -ClientID $token.SignInClientID
            if ($token.SignInTenantID -ne $tenant) { Switch-Tenant $token.SignInTenantID $token.SignInClientID }
            $script:Shared.Auth = Get-IntuneChocoAuthState
            Complete-SignIn 'via Keevault'
        }
        finally { $window.IsEnabled = $true; $window.Cursor = $null; [void]$window.Activate() }
        return
    }
    if (Test-TaskRunning 'connect') { return }
    # Sign-in in the browser (PKCE, answer on a loopback port). It waits in a background runspace, at most five
    # minutes, and "Cancel sign-in" ends it: closing the browser window must not block the next sign-in.
    $script:Shared.CancelSignIn = $false
    $work = @'
param($TenantID, $ClientID, $Authority, $UrlHandler)
$Params = @{ TenantID = $TenantID; ClientID = $ClientID; ShouldCancel = { $Shared.CancelSignIn } }
if ($Authority) { $Params.Authority = $Authority }
if ($UrlHandler) { $Params.UrlHandler = [scriptblock]::Create($UrlHandler) }
Connect-IntuneChoco @Params | Out-Null
Get-IntuneChocoAuthState
'@
    $arguments = @{ TenantID = $tenant; ClientID = $clientId; Authority = $script:SignInTest.Authority; UrlHandler = $script:SignInTest.UrlHandler }
    [void](Start-UiTask -Kind 'connect' -Title "Sign in to ${tenant}: complete the Microsoft sign-in in your browser" -Display 'Sign-in' -Pool $script:UserPool -Work $work -Arguments $arguments -OnDone {
        param($Result, $Job)
        $state = @($Result | Where-Object { $_ -is [hashtable] -and $_.AccessToken })
        if ($Job.Status -ne 'succeeded' -or $state.Count -eq 0) { Update-ConnectionStatus; Complete-SetupStep $false 'the sign-in'; return }   # the reason is in the activity panel
        $script:Shared.Auth = $state[0]
        Set-IntuneChocoAuthState $script:Shared.Auth
        Complete-SignIn 'in the browser'
    })
}
function Get-AccountDomain([string]$User) { if ($User -match '@([^@\s]+)$') { $Matches[1].ToLower() } else { '' } }

function Resolve-AccountTenant([string]$User) {
    # The account chosen in Keevault decides the tenant. Its own app registration is needed there: the one of
    # another tenant is used when it is known, otherwise the tool switches and offers to create one.
    $tenant = [string]$script:Settings.TenantID
    $domain = Get-AccountDomain $User
    if (-not $domain -or $tenant -match '^[0-9a-f-]{36}$' -or $domain -eq $tenant.ToLower()) { return @{ TenantID = $tenant; ClientID = $script:Settings.ClientID } }
    $known = Get-IntuneChocoTenantClient $domain
    if ($known) {
        Write-UiLog "$User belongs to ${domain}: signing in there with its app registration ($known)."
        return @{ TenantID = $domain; ClientID = $known }
    }
    Switch-Tenant $domain ''
    throw "$User belongs to the tenant $domain, which has no app registration for this tool yet. The tool switched to ${domain}: click Create (start page) to set it up, then sign in again."
}

function Switch-Tenant([string]$TenantID, [string]$ClientID) {
    $s = Get-IntuneChocoSettings; $s.TenantID = $TenantID; $s.ClientID = $ClientID
    [void](Save-IntuneChocoSettings -Settings $s); $script:Settings = Get-IntuneChocoSettings
    $script:TenantApps = $null; $script:TenantPackages = @{}
    Update-SettingsView
    Update-ConnectionStatus
    Write-UiLog "Tenant switched to $TenantID$(if ($ClientID) { " (app registration $ClientID)" } else { ', no app registration yet' })."
}

# Tests only: another authority and URL handler for the browser sign-in (set by Tests\GuiSmokeDriver.ps1)
$script:SignInTest = @{}

function Complete-SignIn([string]$How) {
    $script:TenantApps = $null
    Update-ConnectionStatus
    $identity = Get-IntuneChocoIdentity
    Write-UiLog "Signed in $How as $($identity.Account) (tenant $($identity.TenantId))." 'Success'
    Start-TenantRefresh
}

function Disconnect-Intune {
    $script:Shared.Auth = $null
    Set-IntuneChocoAuthState @{}
    $script:TenantApps = $null; $script:TenantPackages = @{}; $script:RuntimeId = $null; $script:StatusScript = $null
    $script:DeviceCounts = @{}; $script:WingetNoRuntime = @(); $script:ImportApps = $null
    Update-TenantRows
    Update-AppList
    Update-ConnectionStatus
    Write-UiLog 'Signed out. The sign-in in your browser stays, close it there if needed.'
}

$script:SignInMenuMethods = @{}
function Show-SignInMenu($Target) {
    # Options of the split button next to Sign in
    $kv = Find-KeevaultMcp
    $menu = New-Object System.Windows.Controls.ContextMenu
    $items = @(
        @{ Glyph = [char]0xE774; Header = 'Sign in with Microsoft account'; Text = 'Opens the Microsoft sign-in in your browser, as before.'; Method = 'Browser'; Enabled = $true }
        @{ Glyph = [char]0xE72E; Header = 'Sign in with Keevault'; Method = 'Keevault'; Enabled = ($kv.Installed -and $kv.McpEnabled)
           Text = $(if (-not $kv.Installed) { 'Keevault is not installed.' }
                    elseif (-not $kv.McpEnabled) { 'Switch on AI agents (MCP) in Keevault first.' }
                    elseif (-not $kv.Running) { 'Start and unlock Keevault first. You pick the account in Keevault; user name, password and one-time code are filled in.' }
                    else { 'You pick the account in Keevault; user name, password and one-time code are filled into the embedded sign-in.' }) }
    )
    foreach ($i in $items) {
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = $i.Header; $mi.Tag = [string]$i.Glyph; $mi.ToolTip = $i.Text; $mi.IsEnabled = $i.Enabled
        # The menu shows the text below the title; no extra tooltip popup
        [System.Windows.Controls.ToolTipService]::SetIsEnabled($mi, $false)
        $script:SignInMenuMethods[$mi] = $i.Method
        $mi.Add_Click({
            param($src)
            try { Connect-Intune -Method $script:SignInMenuMethods[$src] } catch { Show-Error $_.Exception.Message }
        })
        [void]$menu.Items.Add($mi)
    }
    $menu.PlacementTarget = $Target
    $menu.Placement = 'Bottom'
    # Right edge of the menu below the right edge of the arrow (its shadow margin is 8 px)
    $menu.Add_Opened({ param($m) $m.HorizontalOffset = $m.PlacementTarget.ActualWidth - $m.ActualWidth + 8 })
    $menu.IsOpen = $true
}

function Show-AccountMenu {
    # Account pill: sign out, switch to another tenant the tool knows
    $menu = New-Object System.Windows.Controls.ContextMenu
    $script:AccountMenuActions = @{}
    $entries = New-Object System.Collections.ArrayList
    [void]$entries.Add(@{ Glyph = [char]0xE7E8; Header = 'Sign out'; Text = 'The sign-in in your browser stays, close it there if needed.'; Action = { Disconnect-Intune } })
    $known = ConvertFrom-TenantClients $script:Settings.TenantClients
    foreach ($tenant in @($known.Keys | Sort-Object | Where-Object { $_ -ne ([string]$script:Settings.TenantID).ToLower() })) {
        $t = $tenant; $c = $known[$tenant]
        [void]$entries.Add(@{ Glyph = [char]0xE8AB; Header = "Switch to $t"; Text = 'Signs out and uses the app registration of that tenant.'; Action = { Disconnect-Intune; Switch-Tenant $t $c }.GetNewClosure() })
    }
    [void]$entries.Add(@{ Glyph = [char]0xE713; Header = 'Another tenant ...'; Text = 'Enter a tenant and client ID in the settings.'; Action = { Show-Page 'Settings' } })
    foreach ($i in $entries) {
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = $i.Header; $mi.Tag = [string]$i.Glyph; $mi.ToolTip = $i.Text
        [System.Windows.Controls.ToolTipService]::SetIsEnabled($mi, $false)
        $script:AccountMenuActions[$mi] = $i.Action
        $mi.Add_Click({ param($src) try { & $script:AccountMenuActions[$src] } catch { Show-Error $_.Exception.Message } })
        [void]$menu.Items.Add($mi)
    }
    $menu.PlacementTarget = $ui.BtnAccount
    $menu.Placement = 'Bottom'
    $menu.Add_Opened({ param($m) $m.HorizontalOffset = $m.PlacementTarget.ActualWidth - $m.ActualWidth + 8 })
    $menu.IsOpen = $true
}
Add-Click $ui.BtnAccount { Show-AccountMenu }
Add-Click $ui.BtnSignIn {
    if ((Test-TaskRunning 'connect') -or (Test-TaskRunning 'appreg')) {
        $script:Shared.CancelSignIn = $true
        Write-UiLog 'Cancelling the sign-in ...'
    }
    else { Connect-Intune }
}
Add-Click $ui.BtnSignInMenu { Show-SignInMenu $ui.BtnSignInMenu }
Add-Click $ui.BtnStartSignInBrowser { Connect-Intune }
Add-Click $ui.BtnStartSignInKeevault { Connect-Intune -Method Keevault }

# ---------------------------------------------------------------- settings
function Update-SettingsView {
    $s = Get-IntuneChocoSettings
    $ui.TxtTenantId.Text = $s.TenantID
    $ui.TxtClientId.Text = $s.ClientID
    $ui.TxtMetadataFeed.Text = $s.MetadataFeed
    $ui.TxtPackageSource.Text = $s.PackageSource
    $ui.TxtChocoDownloadUrl.Text = $s.ChocolateyDownloadUrl
    $ui.TxtDelayMin.Text = [string]$s.UpdateDelayMinMinutes
    $ui.TxtDelayMax.Text = [string]$s.UpdateDelayMaxMinutes
    $ui.CmbArchitecture.SelectedItem = $s.Architecture
    $ui.CmbAssignment.SelectedItem = $s.Assignment
    $ui.CmbPreferredSource.SelectedIndex = if ($s.Source -eq 'Winget') { 0 } else { 1 }
    $ui.TxtSettingsPath.Text = $script:SettingsPath
    Set-PolicyControls 'Default' $s.UpdateMode $s.GraceHours
    $ui.CmbDefaultVersion.SelectedIndex = if ($s.VersionMode -eq 'Pinned') { 1 } else { 0 }
    $ui.TxtSandboxStudioPath.Text = $s.SandboxStudioPath
    $t = Format-ScheduleSummary (Get-ChocoScheduleDefaults)
    $ui.TxtDefaultSchedule.Text = "$($t.When). $($t.Conditions)."
    Update-SandboxStudioState
    Update-ModuleState
}
function Update-SandboxStudioState {
    $found = Find-SandboxStudio
    $ui.TxtSandboxStudioState.Text = if ($found) { "Found: $found" } else { 'Not found: enter the folder of WindowsSandboxMSIXInstaller. The Test buttons need it and Windows Sandbox.' }
}
$ui.CmbArchitecture.ItemsSource = @('x64x86', 'x64', 'x86', 'arm64', 'AllWithARM64')
$ui.CmbAssignment.ItemsSource = @('Available', 'Required', 'None')
$ui.CmbPreferredSource.ItemsSource = @('winget', 'Chocolatey')

function Save-Settings {
    $defaults = Read-PolicyControls 'Default'
    $new = [ordered]@{
        UpdateMode            = $defaults.UpdateMode
        GraceHours            = $defaults.GraceHours
        VersionMode           = $(if ($ui.CmbDefaultVersion.SelectedIndex -eq 1) { 'Pinned' } else { 'Latest' })
        SandboxStudioPath     = $ui.TxtSandboxStudioPath.Text
        TenantID              = $ui.TxtTenantId.Text
        ClientID              = $ui.TxtClientId.Text
        MetadataFeed          = $ui.TxtMetadataFeed.Text
        PackageSource         = $ui.TxtPackageSource.Text
        ChocolateyDownloadUrl = $ui.TxtChocoDownloadUrl.Text
        Architecture          = [string]$ui.CmbArchitecture.SelectedItem
        Assignment            = [string]$ui.CmbAssignment.SelectedItem
        UpdateDelayMinMinutes = $(if ($ui.TxtDelayMin.Text -match '^\d+$') { [int]$ui.TxtDelayMin.Text } else { throw 'The update delay must be a whole number of minutes.' })
        UpdateDelayMaxMinutes = $(if ($ui.TxtDelayMax.Text -match '^\d+$') { [int]$ui.TxtDelayMax.Text } else { throw 'The update delay must be a whole number of minutes.' })
        Source                = $(if ($ui.CmbPreferredSource.SelectedIndex -eq 0) { 'Winget' } else { 'Chocolatey' })
    }
    $feedChanged = $new.MetadataFeed.Trim() -ne $script:Settings.MetadataFeed
    [void](Save-IntuneChocoSettings -Settings ([pscustomobject]$new))
    $script:Settings = Get-IntuneChocoSettings
    if ($feedChanged) { $script:Shared.Meta.Clear(); $script:MetaDirty = $true }
    Write-UiLog "Settings saved to $script:SettingsPath." 'Success'
    Show-Toast 'Settings saved.' 'ok'
    Set-DeployDefaults
    Update-SandboxStudioState
    Update-ConnectionStatus
}
function Set-DeployDefaults {
    $script:Preferred = if ($script:Settings.Source -eq 'Winget') { 'Winget' } else { 'Chocolatey' }
    $ui.RbPreferWinget.IsChecked = $script:Preferred -eq 'Winget'
    $ui.RbPreferChoco.IsChecked = $script:Preferred -ne 'Winget'
    switch ($script:Settings.Assignment) { 'Required' { $ui.RbRequired.IsChecked = $true } 'None' { $ui.RbNone.IsChecked = $true } default { $ui.RbAvailable.IsChecked = $true } }
}
Add-Click $ui.BtnSaveSettings { Save-Settings }
Add-Click $ui.BtnOpenWorkFolder { New-Item -Path $script:WorkRoot -ItemType Directory -Force | Out-Null; Start-Process explorer.exe $script:WorkRoot }
Add-Click $ui.BtnSettingsGrant {
    # The tenant and client ID typed here are saved first
    if ($ui.TxtTenantId.Text.Trim() -ne [string]$script:Settings.TenantID -or $ui.TxtClientId.Text.Trim() -ne [string]$script:Settings.ClientID) { Save-Settings }
    Start-AppRegistration
}
Add-Click $ui.BtnDefaultSchedule {
    Show-ScheduleDialog -Mode 'Default' -Schedule (Get-ChocoScheduleDefaults) -Title 'When updates install by default' -GraceHours (Read-PolicyControls 'Default').GraceHours
}

function Start-ModuleInstall {
    if (Test-TaskRunning 'components') { return }
    [void](Start-UiTask -Kind 'components' -Title "Installing the IntuneWin32App ($($script:MinimumModuleVersion) or newer) and Microsoft.WinGet.Client modules from the PowerShell Gallery" -Display 'Modules' -Work 'Install-IntunechocoComponents' -Pool $script:UserPool -OnDone {
        param($Result, $Job)
        Update-ModuleState
        Update-ConnectionStatus
        if ($Job.Status -eq 'succeeded') { Write-UiLog "IntuneWin32App $($script:ModuleState.Version) and Microsoft.WinGet.Client $($script:ModuleState.WingetVersion) are ready." 'Success'; Show-Toast 'The modules are ready.' 'ok' }
        if ($script:CurrentPage -eq 'Apps') { Start-CatalogPrefetch }
        Complete-SetupStep ($Job.Status -eq 'succeeded') 'installing the modules'
    })
    Update-Readiness
}
Add-Click $ui.BtnInstallModule { Start-ModuleInstall }

# ---------------------------------------------------------------- run
$window.Add_Closing({
    param($s, $e)
    $running = @($script:Tasks | Where-Object { -not $_.Hidden -and $_.Job.Kind -in 'deploy', 'policy' })
    if ($running.Count -gt 0 -and -not $env:INTUNECHOCO_SMOKE) {
        $answer = [System.Windows.MessageBox]::Show($window, "$($running.Count) change(s) in Intune are still running. Close anyway? Apps that are half created need to be removed in Intune.", 'Intune Choco Deployment', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { $e.Cancel = $true }
    }
})
$window.Add_Closed({
    $timer.Stop()
    Save-MetaCache
    # Not waited for: a task may sit in a web request, and the process ends right after this anyway
    $script:Shared.CancelSignIn = $true
    foreach ($task in @($script:Tasks)) { try { [void]$task.PS.BeginStop($null, $null) } catch { } }
    [System.Windows.Application]::Current.Shutdown()
})

Update-ModuleState
Set-DeployDefaults
Write-UiLog "Intune Choco Deployment $script:ToolVersion started. Work folder: $script:WorkRoot"
if (-not $script:ModuleState.Ok) { Write-UiLog "The IntuneWin32App module ($($script:MinimumModuleVersion) or newer) is missing: install it on the start page." 'Warning' }
Update-CatalogRows
Update-ConnectionStatus
Show-Page 'Start'
Update-TenantRows
$timer.Start()
Start-CatalogPrefetch
if (-not (Test-TaskRunning 'meta')) { Start-IconRender }   # all infos came from the cache
# Test hook: INTUNECHOCO_SMOKE names a script that drives the window off-screen and renders every page.
if ($env:INTUNECHOCO_SMOKE) { . $env:INTUNECHOCO_SMOKE }
$window.Show()
[void]$window.Activate()
[void][System.Windows.Application]::Current.Run()
