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
$script:ToolVersion = '2.1.0'
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
$window.Title = "Intune Chocolatey Deployment $script:ToolVersion"

$script:BrushConverter = New-Object System.Windows.Media.BrushConverter
function Get-Brush([string]$Key) { [System.Windows.Application]::Current.Resources[$Key] }
function ConvertTo-Brush([string]$Hex) { $script:BrushConverter.ConvertFrom($Hex) }

# ---------------------------------------------------------------- log (items as in the MFA tool: Line, Brush, Weight)
$script:LogBrushes = @{
    Info    = Get-Brush 'Text'
    Success = Get-Brush 'Success'
    Warning = ConvertTo-Brush '#B45309'
    Error   = Get-Brush 'Danger'
}
function Add-LogLine {
    param([string]$Text, [string]$Level = 'Info')
    if (-not $script:LogBrushes.ContainsKey($Level)) { $Level = 'Info' }
    $item = [pscustomobject]@{
        Line   = $Text
        Brush  = $script:LogBrushes[$Level]
        Weight = $(if ($Level -in 'Error', 'Success') { 'SemiBold' } else { 'Normal' })
    }
    [void]$ui.LogList.Items.Add($item)
    while ($ui.LogList.Items.Count -gt 1000) { $ui.LogList.Items.RemoveAt(0) }
    $ui.LogList.ScrollIntoView($item)
}
$script:LogFolder = Join-Path $script:WorkRoot 'logs'
function Write-UiLog([string]$Text, [string]$Level = 'Info') {
    $now = Get-Date
    Add-LogLine ('{0:HH:mm:ss}  {1}' -f $now, $Text) $Level
    # Also into a log file per day, so deployments can be traced later
    try {
        if (-not (Test-Path $script:LogFolder)) { New-Item -Path $script:LogFolder -ItemType Directory -Force | Out-Null }
        Add-Content -Path (Join-Path $script:LogFolder ('{0:yyyy-MM-dd}.log' -f $now)) -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1,-7}  {2}' -f $now, $Level, $Text) -Encoding UTF8
    }
    catch { }
}
Set-IntuneChocoSignInLog { param($Text, $Level) Write-UiLog $Text $(if ($Level) { $Level } else { 'Info' }) }

function Show-Error([string]$Message) {
    Write-UiLog $Message 'Error'
    if ($env:INTUNECHOCO_SMOKE) { return }   # tests: no dialogs on the desktop
    [void][System.Windows.MessageBox]::Show($window, $Message, 'Intune Chocolatey Deployment', 'OK', 'Error')
}

function Confirm-Action([string]$Message, [string]$Title = 'Intune Chocolatey Deployment') {
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
$script:Tasks = New-Object System.Collections.ArrayList
$script:TaskCounter = 0
$script:MetaDirty = $false
$script:MetaCachePath = Join-Path $script:WorkRoot 'feedcache.json'
$script:MetaCacheHours = 24

# Runs inside a pool runspace: loads the core script, takes over the sign-in, captures every stream into the job log
$script:TaskBody = {
    param($CorePath, $Shared, $Job, $Work, $WorkArguments)
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $Job.Status = 'running'
    $Output = New-Object System.Collections.ArrayList
    function Add-JobLog([string]$Level, [string]$Text) {
        if ($Text) { [void]$Job.Log.Add(@{ Level = $Level; Text = $Text }) }
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
    if ($Job.HadError) { $Job.Status = 'failed' }
    elseif ($Job.Kind -eq 'deploy' -and $Output.Count -eq 0) { $Job.Status = 'skipped' }
    else { $Job.Status = 'succeeded' }
}.ToString()

function Start-UiTask {
    <#
    Runs $Work (text, with the core script loaded) in a background runspace. $OnDone gets ($Result, $Job) on the
    UI thread when it finishes. Tasks on the same pool queue up and run one after another.
    #>
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Work,
        [hashtable]$Arguments = @{},
        [string]$Package,
        [scriptblock]$OnDone,
        [switch]$NeedsAuth,
        [switch]$Hidden,
        $Pool = $script:WorkPool
    )
    if ($NeedsAuth -and -not $script:Shared.Auth) { throw 'Sign in to Intune first (Sign in, top right).' }
    $script:TaskCounter++
    $job = [hashtable]::Synchronized(@{
        Id       = $script:TaskCounter
        Kind     = $Kind
        Title    = $Title
        Package  = $Package
        Source   = $Arguments['Source']
        Status   = 'queued'
        HadError = $false
        Log      = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        Result   = $null
    })
    # Work is passed as text: script blocks are bound to the runspace that created them
    $ps = [powershell]::Create()
    $ps.RunspacePool = $Pool
    [void]$ps.AddScript($script:TaskBody).AddArgument($script:CorePath).AddArgument($script:Shared).AddArgument($job).AddArgument($Work).AddArgument($Arguments)
    $task = @{ Job = $job; PS = $ps; Handle = $ps.BeginInvoke(); OnDone = $OnDone; Hidden = [bool]$Hidden; LogIndex = 0 }
    [void]$script:Tasks.Add($task)
    if (-not $Hidden) { Write-UiLog "$Title ..." }
    Update-Busy
    return $job
}

function Get-TaskLogLevel([string]$Level) { if ($Level -in 'Error', 'Warning', 'Success') { $Level } else { 'Info' } }

function Update-TaskLog($Task) {
    # New log lines of a task into the activity panel, prefixed with the package when there is one
    $log = $Task.Job.Log
    while ($Task.LogIndex -lt $log.Count) {
        $entry = $log[$Task.LogIndex]
        $Task.LogIndex++
        if ($Task.Hidden) { continue }
        $prefix = if ($Task.Job.Package) { "[$($Task.Job.Package)] " } else { '' }
        Write-UiLog ($prefix + $entry.Text) (Get-TaskLogLevel $entry.Level)
    }
}

function Complete-UiTask($Task) {
    Update-TaskLog $Task
    $job = $Task.Job
    try { [void]$Task.PS.EndInvoke($Task.Handle) }
    catch { if (-not $Task.Hidden) { Write-UiLog $_.Exception.Message 'Error' }; $job.Status = 'failed'; $job.HadError = $true }
    $Task.PS.Dispose()
    $script:Tasks.Remove($Task)
    # The task may have renewed the token: the UI thread uses the same sign-in
    if ($script:Shared.Auth) { Set-IntuneChocoAuthState $script:Shared.Auth }
    if ($Task.OnDone) {
        try { & $Task.OnDone $job.Result $job } catch { Show-Error $_.Exception.Message }
    }
    Update-Busy
}

function Update-Busy {
    $visible = @($script:Tasks | Where-Object { -not $_.Hidden })
    $running = @($visible | Where-Object { $_.Job.Status -eq 'running' })
    $on = $visible.Count -gt 0
    $ui.BusyPanel.Visibility = if ($on) { 'Visible' } else { 'Collapsed' }
    if ($on) {
        $current = if ($running.Count -gt 0) { $running[0].Job.Title } else { $visible[0].Job.Title }
        $more = $visible.Count - 1
        $ui.BusyText.Text = if ($more -gt 0) { "$current ($more more queued)" } else { $current }
    }
    $ui.BtnInstallModule.IsEnabled = -not @($script:Tasks | Where-Object { $_.Job.Kind -eq 'components' }).Count
    Update-SignInButton
    Update-SelectionView
    # The readiness items show running steps ("Installing ...") instead of their button
    if ($script:CurrentPage -eq 'Start' -and ($running.Count -or $visible.Count -ne $script:LastVisibleTasks)) { Update-Readiness }
    $script:LastVisibleTasks = $visible.Count
}
$script:LastVisibleTasks = 0

function Test-TaskRunning([string]$Kind) { @($script:Tasks | Where-Object { $_.Job.Kind -eq $Kind }).Count -gt 0 }

function Update-SignInButton {
    # While the browser sign-in waits, the button cancels it; only the button that applies is enabled (as in the MFA tool)
    $connecting = (Test-TaskRunning 'connect') -or (Test-TaskRunning 'appreg')
    $signedIn = [bool]$script:Shared.Auth
    $ui.BtnSignIn.Content = if ($connecting) { 'Cancel sign-in' } else { 'Sign in' }
    $ui.BtnSignIn.Tag = [string]$(if ($connecting) { [char]0xE711 } else { [char]0xE77B })
    $ui.BtnSignIn.IsEnabled = $connecting -or -not $signedIn
    $ui.BtnSignInMenu.IsEnabled = -not $connecting -and -not $signedIn
    $ui.BtnSignOut.IsEnabled = $signedIn
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:Tick = 0
$timer.Add_Tick({
    try {
        $script:Tick++
        foreach ($task in @($script:Tasks)) {
            Update-TaskLog $task
            if ($task.Handle.IsCompleted) { Complete-UiTask $task }
        }
        # Catalog rows fill up while the feed lookups run
        if ($script:MetaRefreshPending -and $script:Tick % 4 -eq 0) {
            $script:MetaRefreshPending = $false
            if ($script:CurrentPage -eq 'Catalog') { Update-CatalogGrid }
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

function ConvertTo-MetaEntry($Info) {
    return [pscustomobject]@{
        Fetched     = (Get-Date).ToString('o')
        Found       = $true
        Name        = $Info.Name
        Title       = $Info.Title
        Version     = $Info.Version
        Summary     = $Info.Summary
        Description = $Info.Description
        Authors     = $Info.Authors
        IconUrl     = $Info.IconUrl
        ProjectUrl  = $Info.SoftwareSite
        LicenseUrl  = $Info.SoftwareLicense
        Downloads   = $Info.Downloads
        LicenseNote = $Info.LicenseNote
        License     = $Info.License
        # A winget search result has no manifest infos yet (publisher, description): those are read afterwards
        Partial     = ($Info.Source -eq 'Winget' -and -not $Info.Authors)
    }
}

# Package infos of both sources live in one cache: Chocolatey under the id, winget under "winget:<id>"
function Get-MetaKey([string]$Id, [string]$Source = $script:Source) {
    if ($Source -eq 'Winget') { "winget:$($Id.ToLower())" } else { $Id.ToLower() }
}

$script:MetaWork = @'
param($Ids, $Source)
foreach ($Id in $Ids) {
    $Key = if ($Source -eq 'Winget') { "winget:$($Id.ToLower())" } else { $Id.ToLower() }
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

function Test-MetaMissing([string]$Id, [string]$Source = $script:Source) {
    $entry = $script:Shared.Meta[(Get-MetaKey $Id $Source)]
    return (-not $entry -or $entry.Partial -or (-not $entry.Found -and -not $entry.NotFound))
}

function Complete-MetaPrefetch {
    # All lookups are done: show the result, remember it, and say so when the source could not be reached
    Update-CatalogGrid
    if ($script:SearchIds.Count) { Update-SearchRows }
    Save-MetaCache
    $failed = @($script:Shared.Meta.Values | Where-Object { -not $_.Found -and -not $_.NotFound })
    if ($failed.Count -gt 0 -and -not $script:MetaQueued) {
        Write-UiLog "Infos for $($failed.Count) package(s) could not be read ($($failed[0].Error)). 'Refresh infos' in the catalog tries again." 'Warning'
    }
    Start-IconRender
    if ($script:MetaQueued) { $next = $script:MetaQueued; $script:MetaQueued = $null; Start-MetaPrefetch -Ids $next.Ids -Source $next.Source }
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
        if ($script:CurrentPage -eq 'Catalog') { Update-CatalogGrid }
        if ($script:CurrentPage -eq 'Search' -and $ui.DgSearch.ItemsSource) { Update-SearchRows }
        Update-DetailIcon
        Start-IconRender   # packages that came in meanwhile
    })
}

function Start-MetaPrefetch {
    param([string[]]$Ids, [switch]$Force, [string]$Source = $script:Source)
    if (Test-TaskRunning 'meta') { $script:MetaQueued = @{ Ids = $Ids; Source = $Source }; return }   # picked up when the running lookup ends
    if ($Source -eq 'Winget' -and -not $script:ModuleState.Winget) { return }
    $missing = @($Ids | Where-Object { $_ -and ($Force -or (Test-MetaMissing $_ $Source)) })
    if ($missing.Count -eq 0) { return }
    $script:MetaDirty = $true
    # Three parallel lookups: neither source has a batch query, and politeness matters more than speed
    for ($i = 0; $i -lt 3; $i++) {
        $chunk = @(for ($j = $i; $j -lt $missing.Count; $j += 3) { $missing[$j] })
        if ($chunk.Count -gt 0) {
            [void](Start-UiTask -Kind 'meta' -Title 'Reading package infos' -Work $script:MetaWork -Arguments @{ Ids = $chunk; Source = $Source } -Pool $script:MetaPool -Hidden -OnDone { $script:MetaRefreshPending = $true })
        }
    }
    $from = if ($Source -eq 'Winget') { 'the winget source and the winget-pkgs manifests' } else { $script:Settings.MetadataFeed }
    Write-UiLog "Reading infos for $($missing.Count) packages from $from ..."
}
$script:MetaQueued = $null

# ---------------------------------------------------------------- connection state
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
    $ui.TxtModuleState.Text = if ($m.Ok) { "IntuneWin32App $($m.Version)" } elseif ($m.Version) { "IntuneWin32App $($m.Version) is too old" } else { 'IntuneWin32App module missing' }
    $ui.TxtModuleState.Foreground = ConvertTo-Brush $(if ($m.Ok) { '#CBD5E1' } else { '#FCA5A5' })
    $intune = if ($m.Ok) { "IntuneWin32App $($m.Version) is installed (minimum $($script:MinimumModuleVersion)). It packages the .intunewin files and talks to Microsoft Graph." }
              elseif ($m.Version) { "IntuneWin32App $($m.Version) is installed, but $($script:MinimumModuleVersion) or newer is required: older versions break packaging and dependencies." }
              else { "The IntuneWin32App module is not installed." }
    $wingetText = if ($m.Winget) { "Microsoft.WinGet.Client $($m.WingetVersion) is installed (winget package infos and search)." }
                  else { "Microsoft.WinGet.Client is not installed; it is needed for winget packages only." }
    $ui.TxtModuleInfo.Text = "$intune`n$wingetText`nBoth are installed for the current user from the PowerShell Gallery (no admin rights needed)."
}

function Test-SignedIn { [bool]$script:Shared.Auth }

function Update-ConnectionStatus {
    $identity = if (Test-SignedIn) { Get-IntuneChocoIdentity } else { $null }
    if ($identity) {
        $ui.TxtConnectionStatus.Text = "Connected as $(if ($identity.Account) { $identity.Account } else { 'Intune administrator' })"
        $ui.TxtConnectionStatus.Foreground = ConvertTo-Brush '#86EFAC'
        $tenant = if ($identity.TenantId) { $identity.TenantId } else { $Global:AccessTokenTenantID }
        $ui.TxtTenant.Text = "Tenant: $($script:Settings.TenantID) ($tenant)"
        if ($identity.ExpiresOn -and ([datetime]$identity.ExpiresOn).ToUniversalTime() -lt (Get-Date).ToUniversalTime() -and -not $Global:AccessToken.RefreshToken) {
            $ui.TxtConnectionStatus.Text = 'Sign-in expired, sign in again'
            $ui.TxtConnectionStatus.Foreground = ConvertTo-Brush '#FDE68A'
        }
    }
    else {
        $ui.TxtConnectionStatus.Text = 'Not signed in to Intune'
        $ui.TxtConnectionStatus.Foreground = ConvertTo-Brush '#FCA5A5'
        $ui.TxtTenant.Text = if ($script:Settings.TenantID) { "Tenant: $($script:Settings.TenantID)" } else { 'Tenant: -' }
    }
    Update-SignInButton
    $ui.BtnTenantRefresh.IsEnabled = (Test-SignedIn)
    Update-SelectionView
    Update-Readiness
}

# ---------------------------------------------------------------- navigation + help
$pages = @('Start', 'Catalog', 'Search', 'Tenant', 'Settings')
$script:CurrentPage = 'Start'
function Show-Page([string]$Name) {
    $script:CurrentPage = $Name
    foreach ($p in $pages) { $ui["Page$p"].Visibility = if ($p -eq $Name) { 'Visible' } else { 'Collapsed' } }
    $ui["Nav$Name"].IsChecked = $true
    $ui.SidePanel.Visibility = if ($Name -in 'Catalog', 'Search') { 'Visible' } else { 'Collapsed' }
    switch ($Name) {
        'Start'    { Update-Readiness }
        'Catalog'  { Update-CatalogGrid; Start-CatalogPrefetch }
        'Tenant'   { if ((Test-SignedIn) -and $null -eq $script:TenantApps -and -not @($script:Tasks | Where-Object { $_.Job.Kind -eq 'tenant' }).Count) { Start-TenantRefresh } }
        'Settings' { Update-SettingsView }
    }
    if ($ui.HelpPanel.Visibility -eq 'Visible') { Show-Help }
}
foreach ($p in $pages) {
    $ui["Nav$p"].Add_Checked({
        param($src)
        $name = $src.Name -replace '^Nav', ''
        if ($ui["Page$name"].Visibility -ne 'Visible') { try { Show-Page $name } catch { Show-Error $_.Exception.Message } }
    })
}

$script:HelpTexts = @{
    Start    = @(
        @('What it does', 'Deploys Chocolatey or winget packages as Win32 apps to Microsoft Intune. Every app gets an install script that runs as SYSTEM, a detection rule and a startup task that keeps the package up to date. Chocolatey apps depend on the Chocolatey app, which is created once per tenant; winget is part of Windows.'),
        @('Chocolatey or winget', 'The button in the header switches the package source. Catalog and search show the packages of that source. winget installs straight from the vendors (no rate limit, Microsoft-run repository) and needs Windows 10 1809 or newer; Chocolatey can use your own repository.'),
        @('Requirements', 'The IntuneWin32App module 1.5.0 or newer (Settings > Components) and an Entra ID app registration with redirect URI http://localhost and the delegated Graph permissions listed in the settings. Chocolatey and Inkscape are not needed on this computer.'),
        @('Sign in', 'Sign in opens the Microsoft sign-in in your browser. The arrow next to it offers the sign-in with an account from Keevault: you pick the account there, user name, password and one-time code are filled in.'),
        @('Readiness', 'All items should be green before the first deployment. A red item says why and has the button that fixes it. Set up everything runs all fixes one after another: modules, app registration (one sign-in with a Global Administrator, admin consent included), sign-in, Chocolatey app.'))
    Catalog  = @(
        @('Catalog', 'A curated list of common packages by category (catalog.json next to the scripts, edit it to add your own; "winget" holds the id of the same app in winget). Versions, publishers and icons come from the active source and are cached for 24 hours.'),
        @('Selecting', 'Click an app for its details. Ctrl+click or Shift+click selects several apps; the selection is kept while you switch categories or search. Select shown picks every row of the current view.'),
        @('Deploy', 'Choose the assignment (Available in the Company Portal, Required on every device, or None) and click Deploy selected. Deployments run one after another in the background; progress shows in the activity panel.'),
        @('License notes', 'Packages whose software license restricts business use or distribution carry a note. The tool deploys them only after a confirmation; the license is still yours to clear.'))
    Search   = @(
        @('Search', 'Searches the active source by name or package id: the Chocolatey community repository (or your metadata feed) with download counts, or the winget community repository with publisher and license from its manifests.'),
        @('Which package?', 'Chocolatey: many apps exist as "app" (meta package) and "app.install"; prefer the plain package. winget: ids are Publisher.App (e.g. 7zip.7zip); check the publisher in the details.'),
        @('Custom icon', 'If a package has no icon, or you want your own, choose a PNG, JPEG, SVG or ICO file in the details. It is used for this deployment only.'))
    Tenant   = @(
        @('In tenant', 'The Win32 apps this tool created in the tenant, recognized by their notes, from both sources. The Chocolatey app is the dependency of the Chocolatey apps and stays while one of them exists.'),
        @('Update or remove', 'Open in Intune admin center opens the selected app. An app that already exists is skipped on deployment; remove it in Intune first to deploy it again.'))
    Settings = @(
        @('Tenant and client ID', 'The tenant (domain or ID) and the application (client) ID of your app registration. Both are saved in %LOCALAPPDATA%\IntuneChocoDeployment\settings.json and also used by the command line functions.'),
        @('Deployment defaults', 'Architecture of the requirement rule (x64x86 fits most devices, AllWithARM64 adds ARM devices), the default assignment and the random wait of the startup update task.'),
        @('Package sources', 'The metadata feed is read on this computer. The package source is what choco uses on the devices (--source); the download URL is where the Chocolatey bootstrap gets its nupkg. Both empty = community repository.'),
        @('Rate limits', 'Chocolatey rate limits downloads from its community repository and does not recommend it for organizations. Put an internal repository or caching proxy in front for larger environments.'))
}
function Show-Help {
    $ui.HelpTitle.Text = "Help: $script:CurrentPage"
    $ui.HelpBody.Children.Clear()
    foreach ($entry in $script:HelpTexts[$script:CurrentPage]) {
        $l = New-Object System.Windows.Controls.TextBlock; $l.Text = $entry[0]; $l.Style = $window.FindResource('HelpLabel')
        $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $entry[1]; $t.Style = $window.FindResource('HelpText')
        [void]$ui.HelpBody.Children.Add($l); [void]$ui.HelpBody.Children.Add($t)
    }
    $ui.HelpPanel.Visibility = 'Visible'
}
Add-Click $ui.BtnHelp { if ($ui.HelpPanel.Visibility -eq 'Visible') { $ui.HelpPanel.Visibility = 'Collapsed' } else { Show-Help } }
Add-Click $ui.BtnHelpClose { $ui.HelpPanel.Visibility = 'Collapsed' }
Add-Click $ui.BtnHeaderSettings { Show-Page 'Settings' }
Add-Click $ui.BtnStartCatalog { Show-Page 'Catalog' }
Add-Click $ui.BtnStartSearch { Show-Page 'Search' }
Add-Click $ui.BtnStartTenant { Show-Page 'Tenant' }

# ---------------------------------------------------------------- start page: readiness
$script:ReadinessActions = @{}
function New-ReadinessCard {
    param([string]$Glyph, [string]$Title, [ValidateSet('ok', 'warn', 'bad')][string]$State, [string]$Text, [string]$ActionText, [scriptblock]$Action)
    # One compact row: icon | title + state text | action button | state dot
    $color = @{ ok = Get-Brush 'Success'; warn = ConvertTo-Brush '#B45309'; bad = Get-Brush 'Danger' }[$State]
    $border = New-Object System.Windows.Controls.Border
    $border.Style = $window.FindResource('TileCard')
    $border.Margin = '0,0,0,8'
    $grid = New-Object System.Windows.Controls.Grid
    foreach ($w in 'Auto', '*', 'Auto', 'Auto') {
        $c = New-Object System.Windows.Controls.ColumnDefinition
        $c.Width = if ($w -eq '*') { [System.Windows.GridLength]::new(1, 'Star') } else { [System.Windows.GridLength]::Auto }
        [void]$grid.ColumnDefinitions.Add($c)
    }
    $icon = New-Object System.Windows.Controls.TextBlock
    $icon.Text = $Glyph; $icon.Style = $window.FindResource('Glyph'); $icon.FontSize = 18; $icon.Foreground = $color; $icon.Margin = '0,0,12,0'
    [void]$grid.Children.Add($icon)
    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.VerticalAlignment = 'Center'
    $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $Title; $t.Style = $window.FindResource('CardTitle')
    $s = New-Object System.Windows.Controls.TextBlock; $s.Text = $Text; $s.Style = $window.FindResource('Hint')
    [void]$stack.Children.Add($t); [void]$stack.Children.Add($s)
    [System.Windows.Controls.Grid]::SetColumn($stack, 1)
    [void]$grid.Children.Add($stack)
    if ($ActionText -and $Action) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $ActionText; $b.Style = $window.FindResource('SmallButton'); $b.Margin = '10,0,10,0'; $b.VerticalAlignment = 'Center'
        $script:ReadinessActions[$b] = $Action
        $b.Add_Click({ param($src) try { & $script:ReadinessActions[$src] } catch { Show-Error $_.Exception.Message } })
        [System.Windows.Controls.Grid]::SetColumn($b, 2)
        [void]$grid.Children.Add($b)
    }
    $dot = New-Object System.Windows.Shapes.Ellipse
    $dot.Width = 10; $dot.Height = 10; $dot.Fill = $color; $dot.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($dot, 3)
    [void]$grid.Children.Add($dot)
    $border.Child = $grid
    $border
}

function Get-ReadinessItems {
    <#
    Everything the tool needs, in the order it is set up. Each item: state, the reason when it is not ok, and the fix
    (Key names the step for "Set up everything"; Wait = a task for it is running).
    #>
    $m = $script:ModuleState
    $winget = $script:Source -eq 'Winget'
    $busyModules = Test-TaskRunning 'components'
    $busyAppReg = Test-TaskRunning 'appreg'
    $busyConnect = Test-TaskRunning 'connect'
    $items = @(
        $(if ($m.Ok) { @{ Key = 'module'; Glyph = [char]0xE7B8; Title = 'IntuneWin32App module'; State = 'ok'; Text = "Version $($m.Version) is installed." } }
          else { @{ Key = 'module'; Glyph = [char]0xE7B8; Title = 'IntuneWin32App module'; State = 'bad'; Wait = $busyModules
                    Text = $(if ($busyModules) { 'Installing from the PowerShell Gallery ...' } elseif ($m.Version) { "Version $($m.Version) is installed, but $($script:MinimumModuleVersion) or newer is needed: older versions break packaging and dependencies." } else { 'Not installed. It packages the apps and talks to Intune; installed for your user, no admin rights needed.' })
                    Fix = 'Install'; Action = { Start-ModuleInstall } } })
        $(if ($winget) {
            if ($m.Winget) { @{ Key = 'winget'; Glyph = [char]0xE753; Title = 'winget module'; State = 'ok'; Text = "Microsoft.WinGet.Client $($m.WingetVersion) is installed." } }
            else { @{ Key = 'winget'; Glyph = [char]0xE753; Title = 'winget module'; State = 'bad'; Wait = $busyModules
                      Text = $(if ($busyModules) { 'Installing from the PowerShell Gallery ...' } else { 'Microsoft.WinGet.Client is not installed. winget is the package source, and package infos and the search need it.' })
                      Fix = 'Install'; Action = { Start-ModuleInstall } } }
          })
        $(if ($script:Settings.TenantID -and $script:Settings.ClientID) { @{ Key = 'appreg'; Glyph = [char]0xE713; Title = 'Tenant and app registration'; State = 'ok'; Text = "$($script:Settings.TenantID), client ID $($script:Settings.ClientID)." } }
          else { @{ Key = 'appreg'; Glyph = [char]0xE713; Title = 'Tenant and app registration'; State = 'bad'; Wait = $busyAppReg
                    Text = $(if ($busyAppReg) { 'Waiting for the administrator sign-in in your browser ...' } elseif (-not $script:Settings.ClientID) { 'No app registration yet: the tool signs in with its own Entra ID app. Create creates it with admin consent (needs a Global Administrator once); an existing one is entered in the settings.' } else { 'The tenant is missing (Settings).' })
                    Fix = $(if ($script:Settings.ClientID) { 'Settings' } else { 'Create' }); Action = $(if ($script:Settings.ClientID) { { Show-Page 'Settings' } } else { { Start-AppRegistration } }) } })
        $(if (Test-SignedIn) { @{ Key = 'signin'; Glyph = [char]0xE77B; Title = 'Signed in to Intune'; State = 'ok'; Text = $ui.TxtConnectionStatus.Text } }
          else { @{ Key = 'signin'; Glyph = [char]0xE77B; Title = 'Signed in to Intune'; State = 'bad'; Wait = $busyConnect
                    Text = $(if ($busyConnect) { 'Waiting for the sign-in in your browser ...' } else { 'Not signed in. Deploying and the tenant view need a sign-in with an Intune administrator account.' })
                    Fix = 'Sign in'; Action = { Connect-Intune } } })
    )
    if (-not $winget) {
        $busyChoco = Test-TaskRunning 'chocolatey'
        $items += $(if (-not (Test-SignedIn)) { @{ Key = 'choco'; Glyph = [char]0xE896; Title = 'Chocolatey app in tenant'; State = 'warn'; Text = 'Checked after the sign-in.' } }
                    elseif ($null -eq $script:TenantApps) {
                        $reading = Test-TaskRunning 'tenant'
                        @{ Key = 'tenant'; Glyph = [char]0xE896; Title = 'Chocolatey app in tenant'; State = 'warn'; Wait = $reading
                           Text = $(if ($reading) { 'Reading the apps in the tenant ...' } else { 'The apps in the tenant could not be read yet.' }); Fix = 'Check'; Action = { Start-TenantRefresh } } }
                    elseif (@($script:TenantApps | Where-Object IsChocolatey).Count) { @{ Key = 'choco'; Glyph = [char]0xE896; Title = 'Chocolatey app in tenant'; State = 'ok'; Text = "Deployed; $(@($script:TenantApps | Where-Object { -not $_.IsChocolatey }).Count) apps created by this tool." } }
                    else { @{ Key = 'choco'; Glyph = [char]0xE896; Title = 'Chocolatey app in tenant'; State = 'bad'; Wait = $busyChoco
                              Text = $(if ($busyChoco) { 'Deploying Chocolatey to Intune ...' } else { 'Not in the tenant yet. Every Chocolatey app depends on it; it is also created with the first app.' })
                              Fix = 'Deploy'; Action = { Start-ChocolateyDeploy } } })
    }
    $items
}

function Update-Readiness {
    if (-not $ui.ReadinessPanel) { return }
    $ui.ReadinessPanel.Children.Clear()
    $script:ReadinessActions.Clear()
    $items = @(Get-ReadinessItems)
    foreach ($i in $items) {
        # Only items that are not ok get a button, and it fixes that item
        $action = if ($i.State -ne 'ok' -and $i.Action -and -not $i.Wait) { $i.Action } else { $null }
        [void]$ui.ReadinessPanel.Children.Add((New-ReadinessCard $i.Glyph $i.Title $i.State $i.Text $i.Fix $action))
    }
    $open = @($items | Where-Object { $_.State -ne 'ok' })
    $ui.TxtReadinessSummary.Text = if ($script:SetupRunning) { 'Setting up, step by step ...' }
                                   elseif ($open.Count -eq 0) { 'Everything is set up.' }
                                   else { "$($open.Count) of $($items.Count) not ready: $(($open | ForEach-Object { $_.Title }) -join ', ')." }
    $ui.BtnSetupAll.Visibility = if ($open.Count -eq 0) { 'Collapsed' } else { 'Visible' }
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
    if ($Message) { Write-UiLog $Message $Level }
    Update-Readiness
}
function Step-Setup {
    if (-not $script:SetupRunning) { return }
    $items = @(Get-ReadinessItems)
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
    if (-not $Ok) { Stop-Setup "Set up stopped: $What did not work, see the messages above."; return }
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
    [void](Start-UiTask -Kind 'appreg' -Title 'Creating the app registration: sign in with an administrator account in your browser and accept the consent' -Pool $script:UserPool -Work $work -Arguments $arguments -OnDone {
        param($Result, $Job)
        $reg = @($Result | Where-Object { $_ -and $_.ClientID }) | Select-Object -First 1
        if ($Job.Status -eq 'succeeded' -and $reg) {
            $s = Get-IntuneChocoSettings; $s.TenantID = $reg.TenantID; $s.ClientID = $reg.ClientID
            [void](Save-IntuneChocoSettings -Settings $s); $script:Settings = Get-IntuneChocoSettings
            Update-SettingsView
            Write-UiLog "App registration ready: tenant $($reg.TenantID), client ID $($reg.ClientID). Saved in the settings." 'Success'
            Update-ConnectionStatus
            Complete-SetupStep $true
        }
        else { Update-ConnectionStatus; Complete-SetupStep $false 'creating the app registration' }
    })
    Update-SignInButton
    Update-Readiness
}

function Start-ChocolateyDeploy {
    if (Test-TaskRunning 'chocolatey') { return }
    Update-UiToken
    [void](Start-UiTask -Kind 'chocolatey' -Title 'Deploying the Chocolatey app to Intune' -NeedsAuth -Work 'get-ChocoWin32ID' -OnDone {
        param($Result, $Job)
        if ($Job.Status -eq 'succeeded') { Write-UiLog 'Chocolatey is in the tenant.' 'Success' }
        $script:TenantApps = $null
        if ($Job.Status -eq 'succeeded') { Start-TenantRefresh } else { Update-Readiness; Complete-SetupStep $false 'deploying Chocolatey' }
    })
    Update-Readiness
}

# ---------------------------------------------------------------- packages: catalog, search, selection, details
$script:Catalog = @(Get-IntuneChocoCatalog)
$script:Source = if ($script:Settings.Source -eq 'Winget') { 'Winget' } else { 'Chocolatey' }
$script:Selected = [ordered]@{}      # package id (lower case) -> row item
$script:CustomIcons = @{}            # package id (lower case) -> PNG/JPEG base64
$script:Rebuilding = $false
$script:DetailItem = $null
$script:MetaRefreshPending = $false
$script:TenantApps = $null
$script:TenantPackages = @{}         # package id (lower case) of the apps already in the tenant
$script:RecentDeploys = @{}          # package id (lower case) -> time it was created by this window

function New-PackageRow {
    # $IconMeta: winget packages rarely have an icon, a catalog entry lends the one of its Chocolatey package
    param([string]$Id, [string]$Name, [string]$Category, $Meta, $IconMeta, [string]$Source = $script:Source)
    $found = $Meta -and $Meta.Found
    $note = if ($Meta -and $Meta.LicenseNote) { $Meta.LicenseNote } else { Get-ChocoLicenseNote $Id }
    $key = Get-MetaKey $Id $Source
    $inTenant = $script:TenantPackages.ContainsKey($key)
    $iconSource = if ($found -and $Meta.IconUrl) { $Meta.IconUrl } elseif ($IconMeta -and $IconMeta.Found) { $IconMeta.IconUrl } else { $null }
    # One chip per row, the most important note first
    $statusText = if ($inTenant) { 'In tenant' } elseif ($note) { 'License' } elseif ($Meta -and $Meta.NotFound) { 'Not found' }
                  elseif ($Meta -and -not $Meta.Found) { 'No infos' } elseif (-not $Meta) { 'Loading' } else { '' }
    $status = switch ($statusText) { 'In tenant' { 'OK' } 'License' { 'Warning' } 'Not found' { 'Error' } default { '' } }
    [pscustomobject]@{
        Id          = $(if ($found -and $Meta.Name) { $Meta.Name } else { $Id })
        Key         = $key
        Source      = $Source
        # The name the app gets in Intune (catalog name, or the feed title without "(Install)")
        Title       = $(if ($Name) { $Name } elseif ($found -and $Meta.Title) { $Meta.Title } else { $Id }) -replace '\s*\((Install|Portable)\)\s*$', ''
        Category    = $Category
        Version     = $(if ($found) { $Meta.Version } else { '' })
        Authors     = $(if ($found) { $Meta.Authors } else { '' })
        Downloads   = $(if ($found -and $Meta.Downloads) { try { ('{0:N0}' -f [int64]$Meta.Downloads) } catch { $Meta.Downloads } } else { '' })
        IconUrl     = $(if ($iconSource) { $p = Get-IconPreview $iconSource; if ($p) { $p.ToString() } } else { $null })
        RawIconUrl  = $iconSource
        License     = $(if ($found) { $Meta.License } else { '' })
        Summary     = $(if ($found) { $Meta.Summary } else { '' })
        Description = $(if ($found) { $Meta.Description } else { '' })
        ProjectUrl  = $(if ($found) { $Meta.ProjectUrl } else { '' })
        LicenseUrl  = $(if ($found) { $Meta.LicenseUrl } else { '' })
        LicenseNote = $note
        Found       = [bool]$found
        InTenant    = $inTenant
        StatusText  = $statusText
        Status      = $status
    }
}

function Find-VisualChild($Parent, [type]$Type) {
    for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Parent); $i++) {
        $child = [System.Windows.Media.VisualTreeHelper]::GetChild($Parent, $i)
        if ($child -is $Type) { return $child }
        $found = Find-VisualChild $child $Type
        if ($found) { return $found }
    }
}

function Update-CatalogGrid {
    $category = [string]$ui.CmbCategory.SelectedItem
    $filter = $ui.TxtCatalogFilter.Text.Trim()
    $entries = @(Get-CatalogEntries)
    $rows = foreach ($entry in $entries) {
        if ($category -and $category -ne 'All categories' -and $entry.Category -ne $category) { continue }
        $id = Get-CatalogPackageId $entry
        if ($filter -and $entry.Name -notlike "*$filter*" -and $id -notlike "*$filter*") { continue }
        New-PackageRow -Id $id -Name $entry.Name -Category $entry.Category -Meta $script:Shared.Meta[(Get-MetaKey $id)] -IconMeta $script:Shared.Meta[$entry.Id.ToLower()]
    }
    Set-GridRows $ui.DgCatalog @($rows)
    $loading = @($rows | Where-Object { $_.StatusText -eq 'Loading' }).Count
    $ui.TxtCatalogCount.Text = "$(@($rows).Count) of $($entries.Count) apps" + $(if ($loading) { ", $loading still loading" } else { '' })
}

# The catalog of the active source: every entry for Chocolatey, the entries with a winget id for winget
function Get-CatalogEntries { if ($script:Source -eq 'Winget') { $script:Catalog | Where-Object WingetId } else { $script:Catalog } }
function Get-CatalogPackageId($Entry) { if ($script:Source -eq 'Winget') { $Entry.WingetId } else { $Entry.Id } }
function Start-CatalogPrefetch {
    Start-MetaPrefetch -Ids @(Get-CatalogEntries | ForEach-Object { Get-CatalogPackageId $_ })
    # winget rows show the icon of the same app's Chocolatey package
    if ($script:Source -eq 'Winget') { $script:MetaQueued = @{ Ids = @($script:Catalog | Where-Object WingetId | ForEach-Object { $_.Id } | Where-Object { Test-MetaMissing $_ 'Chocolatey' }); Source = 'Chocolatey' } }
}

function Set-GridRows($Grid, $Rows) {
    # Rebuilds the rows and restores the selection (it lives in $script:Selected, not in the grid), the sorting
    # and the scroll position: rows are rebuilt while infos and icons come in, the list must not jump meanwhile
    $scroll = Find-VisualChild $Grid ([System.Windows.Controls.ScrollViewer])
    $offset = if ($scroll) { $scroll.VerticalOffset } else { 0 }
    $sorts = @($Grid.Items.SortDescriptions)
    $directions = @{}
    foreach ($column in $Grid.Columns) { if ($null -ne $column.SortDirection) { $directions[$column] = $column.SortDirection } }
    $script:Rebuilding = $true
    try {
        $Grid.ItemsSource = $Rows
        foreach ($sort in $sorts) { $Grid.Items.SortDescriptions.Add($sort) }
        foreach ($column in $directions.Keys) { $column.SortDirection = $directions[$column] }
        foreach ($row in $Rows) { if ($script:Selected.Contains($row.Key)) { [void]$Grid.SelectedItems.Add($row); $script:Selected[$row.Key] = $row } }
    }
    finally { $script:Rebuilding = $false }
    if ($scroll -and $offset -gt 0) { $Grid.UpdateLayout(); $scroll.ScrollToVerticalOffset($offset) }
    # The details follow the rebuilt row (new infos, icon, "In tenant")
    if ($script:DetailItem) {
        $current = @($Rows | Where-Object { $_.Key -eq $script:DetailItem.Key }) | Select-Object -First 1
        if ($current) { Show-Details $current }
    }
    Update-SelectionView
}

function Register-PackageGrid($Grid) {
    $Grid.Add_SelectionChanged({
        param($s, $e)
        if ($script:Rebuilding) { return }
        try {
            foreach ($row in $e.RemovedItems) { $script:Selected.Remove($row.Key) }
            foreach ($row in $e.AddedItems) { $script:Selected[$row.Key] = $row }
            $current = if ($e.AddedItems.Count -gt 0) { $e.AddedItems[$e.AddedItems.Count - 1] } elseif ($s.SelectedItems.Count -gt 0) { $s.SelectedItems[$s.SelectedItems.Count - 1] } else { $null }
            Show-Details $current
            Update-SelectionView
        }
        catch { Show-Error $_.Exception.Message }
    })
    $Grid.Add_MouseDoubleClick({ param($s, $e) if ($s.SelectedItem) { Show-Details $s.SelectedItem } })
}
Register-PackageGrid $ui.DgCatalog
Register-PackageGrid $ui.DgSearch

function Update-SelectionView {
    $count = $script:Selected.Count
    $ui.TxtSelectionCount.Text = switch ($count) { 0 { 'No app selected' } 1 { '1 app selected' } default { "$count apps selected" } }
    $ui.SelectionList.ItemsSource = @($script:Selected.Values | ForEach-Object { "$($_.Title)  ($($_.Id))" })
    $wingetMissing = $script:Source -eq 'Winget' -and -not $script:ModuleState.Winget
    $ui.BtnDeploy.IsEnabled = $count -gt 0 -and (Test-SignedIn) -and $script:ModuleState.Ok -and -not $wingetMissing
    $ui.BtnDeploy.Content = if ($count -gt 1) { "Deploy $count apps" } else { 'Deploy selected' }
    $ui.BtnDeploy.ToolTip = if (-not (Test-SignedIn)) { 'Sign in first' } elseif (-not $script:ModuleState.Ok) { 'Install the IntuneWin32App module first (Settings)' }
                            elseif ($wingetMissing) { 'Install the Microsoft.WinGet.Client module first (Settings)' } else { 'Creates the apps in Intune one after another' }
    $how = if ($script:Source -eq 'Winget') { 'winget as SYSTEM, Windows 10 1809 or newer' } elseif ($script:Settings.PackageSource) { "choco from $($script:Settings.PackageSource)" } else { 'choco from the community repository' }
    $ui.TxtDeployDefaults.Text = "Installs with $how. Architecture $($script:Settings.Architecture), update task waits $($script:Settings.UpdateDelayMinMinutes) to $($script:Settings.UpdateDelayMaxMinutes) min after startup (Settings)."
}

function Clear-Selection {
    $script:Selected.Clear()
    $script:Rebuilding = $true
    try { $ui.DgCatalog.UnselectAll(); $ui.DgSearch.UnselectAll() } finally { $script:Rebuilding = $false }
    Update-SelectionView
}
Add-Click $ui.BtnClearSelection { Clear-Selection }
Add-Click $ui.BtnCatalogSelectShown {
    $script:Rebuilding = $true
    try { $ui.DgCatalog.SelectAll() } finally { $script:Rebuilding = $false }
    foreach ($row in $ui.DgCatalog.Items) { $script:Selected[$row.Key] = $row }
    Update-SelectionView
}
Add-Click $ui.BtnCatalogRefresh {
    Start-MetaPrefetch -Ids @(Get-CatalogEntries | ForEach-Object { Get-CatalogPackageId $_ }) -Force
}

function Show-Details($Item) {
    $script:DetailItem = $Item
    if (-not $Item) {
        $ui.TxtDetailEmpty.Visibility = 'Visible'; $ui.DetailBody.Visibility = 'Collapsed'
        return
    }
    $ui.TxtDetailEmpty.Visibility = 'Collapsed'; $ui.DetailBody.Visibility = 'Visible'
    $ui.TxtDetailTitle.Text = $Item.Title
    $meta = @($Item.Id)
    if ($Item.Version) { $meta += "version $($Item.Version)" }
    if ($Item.Authors) { $meta += $Item.Authors }
    if ($Item.Downloads) { $meta += "$($Item.Downloads) downloads" }
    if ($Item.License) { $meta += "license $($Item.License)" }
    $ui.TxtDetailMeta.Text = $meta -join "  $([char]0x00B7)  "   # kept out of the source: PS 5.1 reads BOM-less files as ANSI
    $summary = if ($Item.Summary) { $Item.Summary } elseif ($Item.Description) { $Item.Description } elseif ($Item.StatusText -eq 'Loading') { 'Package infos are still loading ...' }
               elseif (-not $Item.Found) { $(if ($Item.Source -eq 'Winget') { 'This package was not found in the winget source.' } else { 'This package was not found on the metadata feed.' }) } else { '' }
    $ui.BtnDetailChoco.Content = if ($Item.Source -eq 'Winget') { 'winget-pkgs' } else { 'chocolatey.org' }
    $ui.TxtDetailSummary.Text = ($summary -replace '\s+', ' ').Trim()
    $ui.BoxLicense.Visibility = if ($Item.LicenseNote) { 'Visible' } else { 'Collapsed' }
    $ui.TxtLicenseNote.Text = $Item.LicenseNote
    $ui.BtnDetailSite.IsEnabled = [bool]$Item.ProjectUrl
    $ui.BtnDetailLicense.IsEnabled = [bool]$Item.LicenseUrl
    Update-DetailIcon
}

function Update-DetailIcon {
    $item = $script:DetailItem
    if (-not $item) { return }
    $custom = $script:CustomIcons[$item.Key]
    $ui.ImgDetail.Source = $null
    try {
        if ($custom) {
            $bytes = [Convert]::FromBase64String($custom)
            $stream = New-Object IO.MemoryStream(, $bytes)
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit(); $bmp.CacheOption = 'OnLoad'; $bmp.StreamSource = $stream; $bmp.EndInit(); $bmp.Freeze()
            $stream.Dispose()
            $ui.ImgDetail.Source = $bmp
        }
        elseif ($preview = Get-IconPreview $item.RawIconUrl) {
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit(); $bmp.UriSource = [Uri]$preview; $bmp.EndInit()
            $ui.ImgDetail.Source = $bmp
        }
    }
    catch { }
    $ui.TxtCustomIcon.Text = if ($custom) { "Custom icon set ($([math]::Round($custom.Length * 3 / 4 / 1024)) KB PNG/JPEG), used instead of the one from chocolatey.org." }
                             elseif ($item.RawIconUrl -match '\.svg(\?|#|$)') { 'SVG icon from chocolatey.org, converted to PNG with Edge for Intune.' }
                             elseif ($item.RawIconUrl) { 'Icon from chocolatey.org.' }
                             elseif ($item.Source -eq 'Winget') { 'winget packages have no icon; the app is created without one unless you choose a file.' }
                             elseif ($item.Found) { 'This package has no icon on chocolatey.org; the app is created without one unless you choose a file.' }
                             else { '' }
    $ui.BtnCustomIconRemove.Visibility = if ($custom) { 'Visible' } else { 'Collapsed' }
}

Add-Click $ui.BtnCustomIcon {
    if (-not $script:DetailItem) { return }
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = "Icon for $($script:DetailItem.Title)"
    $dlg.Filter = 'Images (*.png;*.jpg;*.jpeg;*.svg;*.ico)|*.png;*.jpg;*.jpeg;*.svg;*.ico|All files (*.*)|*.*'
    if (-not $dlg.ShowDialog($window)) { return }
    Set-CustomIcon -Key $script:DetailItem.Key -Path $dlg.FileName
}
function Set-CustomIcon([string]$Key, [string]$Path) {
    $window.Cursor = 'Wait'
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -gt 5MB) { throw 'The icon file is larger than 5 MB.' }
        $workPath = Join-Path $script:WorkRoot "icons\$Key"
        New-Item -Path $workPath -ItemType Directory -Force | Out-Null
        $png = ConvertTo-PngBytes -Bytes $bytes -WorkPath $workPath
        $script:CustomIcons[$Key] = [Convert]::ToBase64String($png)
        Write-UiLog "Custom icon for $Key taken from $(Split-Path $Path -Leaf)."
    }
    finally { $window.Cursor = $null }
    Update-DetailIcon
}
Add-Click $ui.BtnCustomIconRemove { if ($script:DetailItem) { $script:CustomIcons.Remove($script:DetailItem.Key); Update-DetailIcon } }
Add-Click $ui.BtnDetailSite { if ($script:DetailItem.ProjectUrl -match '^https?://') { Start-Process $script:DetailItem.ProjectUrl } }
Add-Click $ui.BtnDetailLicense { if ($script:DetailItem.LicenseUrl -match '^https?://') { Start-Process $script:DetailItem.LicenseUrl } }
Add-Click $ui.BtnDetailChoco {
    $item = $script:DetailItem
    if (-not $item) { return }
    if ($item.Source -eq 'Winget') {
        $path = @($item.Id.Split('.') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
        Start-Process "https://github.com/microsoft/winget-pkgs/tree/master/manifests/$($item.Id.Substring(0, 1).ToLower())/$path"
    }
    else { Start-Process "https://community.chocolatey.org/packages/$([Uri]::EscapeDataString($item.Id))" }
}

# Catalog filters
$ui.CmbCategory.ItemsSource = @('All categories') + @($script:Catalog | ForEach-Object { $_.Category } | Sort-Object -Unique)
$ui.CmbCategory.SelectedIndex = 0
$ui.CmbCategory.Add_SelectionChanged({ try { Update-CatalogGrid } catch { Show-Error $_.Exception.Message } })
$ui.TxtCatalogFilter.Add_TextChanged({
    $ui.HintCatalogFilter.Visibility = if ($ui.TxtCatalogFilter.Text) { 'Collapsed' } else { 'Visible' }
    try { Update-CatalogGrid } catch { Show-Error $_.Exception.Message }
})
$ui.TxtSearch.Add_TextChanged({ $ui.HintSearch.Visibility = if ($ui.TxtSearch.Text) { 'Collapsed' } else { 'Visible' } })

# Search
function Start-Search {
    $term = $ui.TxtSearch.Text.Trim()
    if ($term.Length -lt 2) { throw 'Enter at least two characters.' }
    if (Test-TaskRunning 'search') { return }
    if ($script:Source -eq 'Winget' -and -not $script:ModuleState.Winget) { throw 'The winget search needs the Microsoft.WinGet.Client module: install it under Settings > Components.' }
    $ui.TxtSearchCount.Text = 'Searching ...'
    $work = if ($script:Source -eq 'Winget') { 'param($Term, $Source) Search-WingetPackage -SearchPattern $Term -Top 40' } else { 'param($Term, $Source) Search-ChocoPackage -SearchPattern $Term -Top 40' }
    $where = if ($script:Source -eq 'Winget') { 'the winget source' } else { 'the Chocolatey feed' }
    [void](Start-UiTask -Kind 'search' -Title "Searching $where for '$term'" -Pool $script:UserPool -Arguments @{ Term = $term; Source = $script:Source } -Work $work -OnDone {
        param($Result, $Job)
        $source = $Job.Source
        $script:SearchSource = $source
        $script:SearchIds = @(foreach ($info in @($Result | Where-Object { $_ -and $_.Name })) {
            # A full entry from an earlier lookup is kept; a winget hit alone has no publisher and description yet
            $key = Get-MetaKey $info.Name $source
            if (-not ($script:Shared.Meta[$key] -and $script:Shared.Meta[$key].Found -and -not $script:Shared.Meta[$key].Partial)) { $script:Shared.Meta[$key] = ConvertTo-MetaEntry $info }
            $info.Name
        })
        $script:MetaDirty = $true
        Update-SearchRows
        $ui.TxtSearchCount.Text = if ($Job.Status -eq 'failed') { 'Search failed, see the activity panel' } else { "$($script:SearchIds.Count) packages found" }
        if ($source -eq 'Winget') { Start-MetaPrefetch -Ids $script:SearchIds -Source 'Winget' }
        Start-IconRender
    })
}
$script:SearchIds = @()
$script:SearchSource = 'Chocolatey'
function Update-SearchRows {
    $rows = foreach ($id in $script:SearchIds) {
        $meta = $script:Shared.Meta[(Get-MetaKey $id $script:SearchSource)]
        New-PackageRow -Id $id -Name $meta.Title -Category '' -Meta $meta -Source $script:SearchSource
    }
    Set-GridRows $ui.DgSearch @($rows)
}
Add-Click $ui.BtnSearch { Start-Search }
$ui.TxtSearch.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { try { Start-Search } catch { Show-Error $_.Exception.Message } } })

# ---------------------------------------------------------------- deploy
function Get-Intent { if ($ui.RbRequired.IsChecked) { 'Required' } elseif ($ui.RbNone.IsChecked) { 'None' } else { 'Available' } }

function Start-Deploy {
    if ($script:Selected.Count -eq 0) { throw 'Select at least one app first.' }
    if (-not (Test-SignedIn)) { throw 'Sign in to Intune first (Sign in, top right).' }
    if (-not $script:ModuleState.Ok) { throw "IntuneWin32App $($script:MinimumModuleVersion) or newer is required (Settings > Components)." }
    $present = @($script:Selected.Values | Where-Object InTenant)
    $items = @($script:Selected.Values | Where-Object { -not $_.InTenant })
    if ($items.Count -eq 0) { throw "The selected app(s) are already in the tenant ($(($present | ForEach-Object { $_.Title }) -join ', ')). Remove them under 'In tenant' first to deploy them again." }
    if ($present.Count -gt 0) { Write-UiLog "Already in the tenant, left out: $(($present | ForEach-Object { $_.Title }) -join ', ')." 'Warning' }
    $licensed = @($items | Where-Object LicenseNote)
    if ($licensed.Count -gt 0) {
        $text = ($licensed | ForEach-Object { "- $($_.Title): $($_.LicenseNote)" }) -join "`n"
        if (-not (Confirm-Action "These packages carry a license note:`n`n$text`n`nDeploy them anyway?" 'License notes')) { return }
    }
    $intent = Get-Intent
    if ($intent -eq 'Required' -and -not (Confirm-Action "Required installs the $($items.Count) app(s) automatically on every device of all users. Continue?" 'Required assignment')) { return }
    if (@($items | Where-Object { $_.Source -eq 'Winget' }).Count -and -not $script:ModuleState.Winget) { throw 'winget packages need the Microsoft.WinGet.Client module: install it under Settings > Components.' }
    Update-UiToken
    $work = @'
param($Id, $Source, $Assignment, $Architecture, $IconBase64)
$Params = @{ Assignment = $Assignment; Architecture = $Architecture; NoIconPrompt = $true }
if ($IconBase64) { $Params.IconBase64 = $IconBase64 }
if ($Source -eq 'Winget') { New-IntuneWin32WingetApplication -WingetId $Id @Params }
else { New-IntuneWin32ChocoApplication -ChocoName $Id @Params }
'@
    foreach ($item in $items) {
        $icon = $script:CustomIcons[$item.Key]
        $label = if ($item.Source -eq 'Winget') { 'winget' } else { 'Chocolatey' }
        [void](Start-UiTask -Kind 'deploy' -Title "Deploying $($item.Title) from $label ($intent)" -Package $item.Id -NeedsAuth -Work $work -OnDone {
            param($Result, $Job)
            switch ($Job.Status) {
                'succeeded' {
                    Write-UiLog "[$($Job.Package)] created in Intune (app id $(@($Result | Where-Object { $_ -is [string] }) -join ', '))." 'Success'
                    # Graph lists a new app only after a few seconds: mark it right away, so it is not queued twice
                    $key = Get-MetaKey $Job.Package $Job.Source
                    $script:TenantPackages[$key] = $true
                    $script:RecentDeploys[$key] = Get-Date
                }
                'skipped'   { Write-UiLog "[$($Job.Package)] skipped." 'Warning' }
                default     { Write-UiLog "[$($Job.Package)] failed." 'Error' }
            }
            $script:TenantApps = $null
            if (-not @($script:Tasks | Where-Object { $_.Job.Kind -eq 'deploy' }).Count) { Start-TenantRefresh }
        } -Arguments @{ Id = $item.Id; Source = $item.Source; Assignment = $intent; Architecture = $script:Settings.Architecture; IconBase64 = $icon })
    }
    Write-UiLog "$($items.Count) deployment(s) queued, assignment $intent." 'Info'
    Clear-Selection
}
Add-Click $ui.BtnDeploy { Start-Deploy }

# ---------------------------------------------------------------- tenant
function Update-UiToken {
    # Renews the sign-in on the UI thread before it is handed to a task (silent, at most one short web request)
    try {
        Update-IntuneChocoToken 3>&1 6>&1 | ForEach-Object { Write-UiLog ([string]$_) $(if ($_ -is [System.Management.Automation.WarningRecord]) { 'Warning' } else { 'Info' }) }
        $script:Shared.Auth = Get-IntuneChocoAuthState
    }
    catch { Write-UiLog $_.Exception.Message 'Warning' }
}

function Start-TenantRefresh {
    if (-not (Test-SignedIn)) { throw 'Sign in to Intune first.' }
    if (Test-TaskRunning 'tenant') { return }
    $ui.TxtTenantCount.Text = 'Reading the apps in the tenant ...'
    Update-UiToken
    $work = @'
Get-IntuneChocoTenantApps | ForEach-Object {
    [pscustomobject]@{ Id = [string]$_.Id; DisplayName = [string]$_.DisplayName; Package = [string]$_.Package; Source = [string]$_.Source; IsChocolatey = [bool]$_.IsChocolatey; Created = [string]$_.Created }
}
'@
    [void](Start-UiTask -Kind 'tenant' -Title 'Reading the apps this tool created in the tenant' -NeedsAuth -Work $work -OnDone {
        param($Result, $Job)
        if ($Job.Status -eq 'failed') { $ui.TxtTenantCount.Text = 'Could not read the tenant, see the activity panel'; Complete-SetupStep $false 'reading the tenant'; return }
        $script:TenantApps = @($Result | Where-Object { $_ -and $_.Id } | ForEach-Object {
            $created = try { ([datetime]$_.Created).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { $_.Created }
            [pscustomobject]@{
                Id = $_.Id; DisplayName = $_.DisplayName; Package = $_.Package; Source = $_.Source; IsChocolatey = $_.IsChocolatey; CreatedText = $created
                StatusText = $(if ($_.IsChocolatey) { 'Dependency' } elseif ($_.Source -eq 'Winget') { 'winget' } else { 'Chocolatey' })
                Status = $(if ($_.IsChocolatey) { 'assigned' } elseif ($_.Source -eq 'Winget') { 'available' } else { '' })
            }
        } | Sort-Object { -not $_.IsChocolatey }, DisplayName)
        $ui.DgTenant.ItemsSource = $script:TenantApps
        $apps = @($script:TenantApps | Where-Object { -not $_.IsChocolatey }).Count
        $ui.TxtTenantCount.Text = "$apps app(s) created by this tool" + $(if (@($script:TenantApps | Where-Object IsChocolatey).Count) { ', Chocolatey deployed' } else { ', Chocolatey not deployed yet' })
        # Catalog and search mark what is already there, including apps created in the last minutes that Graph
        # does not list yet
        $script:TenantPackages = @{}
        foreach ($app in $script:TenantApps) { if ($app.Package -and -not $app.IsChocolatey) { $script:TenantPackages[(Get-MetaKey $app.Package $app.Source)] = $true } }
        foreach ($key in @($script:RecentDeploys.Keys)) {
            if ($script:RecentDeploys[$key] -gt (Get-Date).AddMinutes(-5)) { $script:TenantPackages[$key] = $true } else { $script:RecentDeploys.Remove($key) }
        }
        Update-CatalogGrid
        if ($script:SearchIds.Count) { Update-SearchRows }
        Update-TenantButtons
        Complete-SetupStep $true
    })
    Update-Readiness
}
Add-Click $ui.BtnTenantRefresh { Start-TenantRefresh }

function Update-TenantButtons {
    $on = [bool]$ui.DgTenant.SelectedItem
    $ui.BtnTenantOpen.IsEnabled = $on; $ui.BtnTenantCopy.IsEnabled = $on
    $ui.BtnTenantRemove.IsEnabled = $on -and (Test-SignedIn) -and -not (Test-TaskRunning 'remove')
}
$ui.DgTenant.Add_SelectionChanged({ Update-TenantButtons })
Add-Click $ui.BtnTenantRemove {
    $app = $ui.DgTenant.SelectedItem
    if (-not $app) { return }
    $others = @($script:TenantApps | Where-Object { -not $_.IsChocolatey -and $_.Source -eq 'Chocolatey' }).Count
    if ($app.IsChocolatey -and $others -gt 0) { throw "Chocolatey is the dependency of the $others app(s) created by this tool. Remove those first." }
    if (-not (Confirm-Action "Remove '$($app.DisplayName)' from Intune?`n`nThe app and its assignments are deleted in the tenant. Devices keep the installed software and its update task; nothing is uninstalled." 'Remove from Intune')) { return }
    Update-UiToken
    [void](Start-UiTask -Kind 'remove' -Title "Removing $($app.DisplayName) from Intune" -Package $app.Package -NeedsAuth -Arguments @{ Id = $app.Id; Source = $app.Source } -Work 'param($Id, $Source) Remove-IntuneChocoApplication -Id $Id' -OnDone {
        param($Result, $Job)
        if ($Job.Status -eq 'succeeded') {
            Write-UiLog "[$($Job.Package)] removed from Intune." 'Success'
            if ($Job.Package) { $script:RecentDeploys.Remove((Get-MetaKey $Job.Package $Job.Source)) }
        }
        $script:TenantApps = $null
        Start-TenantRefresh
    })
    Update-TenantButtons
}
Add-Click $ui.BtnTenantOpen {
    $app = $ui.DgTenant.SelectedItem
    if ($app) { Start-Process "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$($app.Id)" }
}
Add-Click $ui.BtnTenantCopy {
    $app = $ui.DgTenant.SelectedItem
    if ($app) { [System.Windows.Clipboard]::SetText([string]$app.Id); Write-UiLog "App id of $($app.DisplayName) copied." }
}

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
    $ui.TxtSettingsPath.Text = $script:SettingsPath
    Update-ModuleState
}
$ui.CmbArchitecture.ItemsSource = @('x64x86', 'x64', 'x86', 'arm64', 'AllWithARM64')
$ui.CmbAssignment.ItemsSource = @('Available', 'Required', 'None')

function Save-Settings {
    $new = [ordered]@{
        TenantID              = $ui.TxtTenantId.Text
        ClientID              = $ui.TxtClientId.Text
        MetadataFeed          = $ui.TxtMetadataFeed.Text
        PackageSource         = $ui.TxtPackageSource.Text
        ChocolateyDownloadUrl = $ui.TxtChocoDownloadUrl.Text
        Architecture          = [string]$ui.CmbArchitecture.SelectedItem
        Assignment            = [string]$ui.CmbAssignment.SelectedItem
        UpdateDelayMinMinutes = $(if ($ui.TxtDelayMin.Text -match '^\d+$') { [int]$ui.TxtDelayMin.Text } else { throw 'The update delay must be a whole number of minutes.' })
        UpdateDelayMaxMinutes = $(if ($ui.TxtDelayMax.Text -match '^\d+$') { [int]$ui.TxtDelayMax.Text } else { throw 'The update delay must be a whole number of minutes.' })
        Source                = $script:Source
    }
    $feedChanged = $new.MetadataFeed.Trim() -ne $script:Settings.MetadataFeed
    [void](Save-IntuneChocoSettings -Settings ([pscustomobject]$new))
    $script:Settings = Get-IntuneChocoSettings
    if ($feedChanged) { $script:Shared.Meta.Clear(); $script:MetaDirty = $true }
    Write-UiLog "Settings saved to $script:SettingsPath." 'Success'
    switch ($script:Settings.Assignment) { 'Required' { $ui.RbRequired.IsChecked = $true } 'None' { $ui.RbNone.IsChecked = $true } default { $ui.RbAvailable.IsChecked = $true } }
    Update-ConnectionStatus
}
Add-Click $ui.BtnSaveSettings { Save-Settings }
Add-Click $ui.BtnOpenWorkFolder { New-Item -Path $script:WorkRoot -ItemType Directory -Force | Out-Null; Start-Process explorer.exe $script:WorkRoot }

function Start-ModuleInstall {
    if (@($script:Tasks | Where-Object { $_.Job.Kind -eq 'components' }).Count) { return }
    [void](Start-UiTask -Kind 'components' -Title "Installing the IntuneWin32App ($($script:MinimumModuleVersion) or newer) and Microsoft.WinGet.Client modules from the PowerShell Gallery" -Work 'Install-IntunechocoComponents' -Pool $script:UserPool -OnDone {
        param($Result, $Job)
        Update-ModuleState
        Update-ConnectionStatus
        if ($Job.Status -eq 'succeeded') { Write-UiLog "IntuneWin32App $($script:ModuleState.Version) and Microsoft.WinGet.Client $($script:ModuleState.WingetVersion) are ready." 'Success' }
        if ($script:CurrentPage -eq 'Catalog') { Start-CatalogPrefetch }
        Complete-SetupStep ($Job.Status -eq 'succeeded') 'installing the modules'
    })
    Update-Readiness
}
Add-Click $ui.BtnInstallModule { Start-ModuleInstall }

# ---------------------------------------------------------------- package source (Chocolatey or winget)
function Set-PackageSource([ValidateSet('Chocolatey', 'Winget')][string]$Source, [switch]$NoSave) {
    $script:Source = $Source
    $winget = $Source -eq 'Winget'
    $ui.BtnSource.Content = if ($winget) { 'winget' } else { 'Chocolatey' }
    $ui.BtnSource.ToolTip = "Package source: $($ui.BtnSource.Content). Click to switch to $(if ($winget) { 'Chocolatey' } else { 'winget' })."
    $ui.HintSearch.Text = if ($winget) { 'Search the winget repository, e.g. notepad' } else { 'Search the Chocolatey repository, e.g. notepad' }
    # The selection belongs to one source; search results of the other source are cleared
    Clear-Selection
    Show-Details $null
    $script:SearchIds = @(); $ui.DgSearch.ItemsSource = $null; $ui.TxtSearchCount.Text = ''
    $ui.CmbCategory.ItemsSource = @('All categories') + @(Get-CatalogEntries | ForEach-Object { $_.Category } | Sort-Object -Unique)
    $ui.CmbCategory.SelectedIndex = 0
    Update-CatalogGrid
    Update-SelectionView
    Update-Readiness
    if ($script:CurrentPage -eq 'Catalog') { Start-CatalogPrefetch }
    if (-not $NoSave) {
        try {
            $s = Get-IntuneChocoSettings; $s.Source = $Source
            [void](Save-IntuneChocoSettings -Settings $s); $script:Settings = Get-IntuneChocoSettings
        }
        catch { Write-UiLog "The package source could not be saved: $($_.Exception.Message)" 'Warning' }
        Write-UiLog "Package source: $($ui.BtnSource.Content)."
    }
}
Add-Click $ui.BtnSource { Set-PackageSource $(if ($script:Source -eq 'Winget') { 'Chocolatey' } else { 'Winget' }) }

# ---------------------------------------------------------------- sign in / out
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
    [void](Start-UiTask -Kind 'connect' -Title "Sign in to ${tenant}: complete the Microsoft sign-in in your browser" -Pool $script:UserPool -Work $work -Arguments $arguments -OnDone {
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
    $script:TenantApps = $null
    $script:TenantPackages = @{}
    $ui.DgTenant.ItemsSource = $null
    $ui.TxtTenantCount.Text = 'Sign in to see the apps this tool created in the tenant.'
    Update-TenantButtons
    Update-CatalogGrid
    if ($script:SearchIds.Count) { Update-SearchRows }
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
Add-Click $ui.BtnSignIn {
    if ((Test-TaskRunning 'connect') -or (Test-TaskRunning 'appreg')) {
        $script:Shared.CancelSignIn = $true
        Write-UiLog 'Cancelling the sign-in ...'
    }
    else { Connect-Intune }
}
Add-Click $ui.BtnSignInMenu { Show-SignInMenu $ui.BtnSignInMenu }
Add-Click $ui.BtnSignOut { Disconnect-Intune }

# ---------------------------------------------------------------- activity panel
Add-Click $ui.BtnLogClear { $ui.LogList.Items.Clear() }
Add-Click $ui.BtnLogFolder { New-Item -Path $script:LogFolder -ItemType Directory -Force | Out-Null; Start-Process explorer.exe $script:LogFolder }
Add-Click $ui.BtnLogToggle {
    $hidden = $ui.LogList.Visibility -eq 'Visible'
    $ui.LogList.Visibility = if ($hidden) { 'Collapsed' } else { 'Visible' }
    $ui.BtnLogToggle.Content = if ($hidden) { 'Show' } else { 'Hide' }
}

# ---------------------------------------------------------------- run
$window.Add_Closing({
    param($s, $e)
    $running = @($script:Tasks | Where-Object { -not $_.Hidden -and $_.Job.Kind -eq 'deploy' })
    if ($running.Count -gt 0 -and -not $env:INTUNECHOCO_SMOKE) {
        $answer = [System.Windows.MessageBox]::Show($window, "$($running.Count) deployment(s) are still running. Close anyway? Apps that are half created need to be removed in Intune.", 'Intune Chocolatey Deployment', 'YesNo', 'Warning')
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
switch ($script:Settings.Assignment) { 'Required' { $ui.RbRequired.IsChecked = $true } 'None' { $ui.RbNone.IsChecked = $true } default { $ui.RbAvailable.IsChecked = $true } }
Write-UiLog "Intune Chocolatey Deployment $script:ToolVersion started. Work folder: $script:WorkRoot"
if (-not $script:ModuleState.Ok) { Write-UiLog "The IntuneWin32App module ($($script:MinimumModuleVersion) or newer) is missing: install it under Settings > Components." 'Warning' }
Update-ConnectionStatus
Show-Page 'Start'
Set-PackageSource $script:Source -NoSave
Start-CatalogPrefetch
if (-not (Test-TaskRunning 'meta')) { Start-IconRender }   # all infos came from the cache
$timer.Start()
# Test hook: INTUNECHOCO_SMOKE names a script that drives the window off-screen and renders every page.
if ($env:INTUNECHOCO_SMOKE) { . $env:INTUNECHOCO_SMOKE }
$window.Show()
[void]$window.Activate()
[void][System.Windows.Application]::Current.Run()
