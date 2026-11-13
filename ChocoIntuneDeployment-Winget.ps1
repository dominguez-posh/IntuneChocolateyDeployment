<#
    winget packages as Win32 apps in Intune. Loaded by ChocoIntuneDeployment-Main.ps1, uses its helpers
    (work folder, packaging, icons, Invoke-IntuneModule, assignment).

    On the admin machine: package infos and search come from the Microsoft.WinGet.Client module (the winget
    community source) and from the package manifests in github.com/microsoft/winget-pkgs.
    On the devices: install.ps1 runs winget as SYSTEM (winget.exe is not in SYSTEM's path, it is looked up in
    WindowsApps) and applies the update mode of the app (Off, Startup, Custom), like the Chocolatey apps. No
    dependency app is needed to run it, but the winget runtime app (ChocoIntuneDeployment-Sources.ps1) makes sure App Installer
    is there and registered: every winget app has it as AutoInstall dependency.

        . .\ChocoIntuneDeployment-Main.ps1
        Connect-IntuneChoco -TenantID "contoso.onmicrosoft.com" -ClientID "<app id>"
        New-IntuneWin32WingetApplication -WingetId "7zip.7zip", "VideoLAN.VLC"
#>

$script:WingetManifestRoot = "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests"
$script:WingetIdPattern = '^[A-Za-z0-9][A-Za-z0-9._+-]*$'

function Assert-WingetClient {
    # Microsoft.WinGet.Client: Microsoft's PowerShell module for winget, for Windows PowerShell 5.1 and PowerShell 7
    if (-not (Get-Module Microsoft.WinGet.Client)) {
        if (-not (Get-Module -ListAvailable Microsoft.WinGet.Client)) {
            throw "The Microsoft.WinGet.Client module is required for winget packages. Run Install-IntunechocoComponents first."
        }
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
    }
}#Makes sure the winget PowerShell module is loaded

function Get-WingetManifestValues {
    param([Parameter(Mandatory = $true)][string]$Yaml)
    # The few top-level fields the tool needs; values may be quoted or a block (|-, >-) on the next indented lines
    $Values = @{}
    $Lines = $Yaml -split "`r?`n"
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -notmatch '^([A-Za-z]+):\s*(.*)$') { continue }
        $Key = $Matches[1]; $Value = $Matches[2].Trim()
        if ($Value -match '^[|>][-+]?$') {
            $Block = for ($j = $i + 1; $j -lt $Lines.Count -and ($Lines[$j] -match '^\s+\S' -or $Lines[$j] -eq ''); $j++) { $Lines[$j].Trim() }
            $Value = (@($Block) -join " ").Trim()
        }
        elseif ($Value -match "^'((?:[^']|'')*)'") { $Value = $Matches[1].Replace("''", "'") }
        elseif ($Value -match '^"((?:[^"\\]|\\.)*)"') { $Value = $Matches[1] }
        else { $Value = ($Value -replace '\s+#.*$', '').Trim() }   # comments only outside quotes
        if (-not $Values.ContainsKey($Key)) { $Values[$Key] = $Value }
    }
    return $Values
}#Reads the scalar fields of a winget manifest

function Get-WingetManifestUrl {
    param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][string]$Version)
    # manifests/<first letter>/<Publisher>/<Name>/<Version>/, e.g. manifests/7/7zip/7zip/26.05/
    $Segments = @($Id.Split(".") | ForEach-Object { [uri]::EscapeDataString($_) })
    return "$($script:WingetManifestRoot)/$($Id.Substring(0, 1).ToLower())/$($Segments -join '/')/$([uri]::EscapeDataString($Version))"
}

function Invoke-WingetFind {
    param([string]$Id, [string]$Query)
    Assert-WingetClient
    $Params = @{ Source = "winget"; ErrorAction = "Stop" }
    if ($Id) { $Params.Id = $Id; $Params.MatchOption = "Equals" } else { $Params.Query = $Query }
    return @(Find-WinGetPackage @Params)
}

function ConvertTo-WingetInfo {
    param([Parameter(Mandatory = $true)]$Found, $Manifest)
    $Id = [string]$Found.Id
    $Title = if ($Manifest -and $Manifest.PackageName) { $Manifest.PackageName } else { [string]$Found.Name }
    $Description = if ($Manifest -and $Manifest.Description) { $Manifest.Description } elseif ($Manifest) { $Manifest.ShortDescription } else { $null }
    [pscustomobject]@{
        Name            = $Id
        Title           = $Title
        Version         = [string]$Found.Version
        Summary         = $(if ($Manifest) { $Manifest.ShortDescription } else { $null })
        Description     = $Description
        Authors         = $(if ($Manifest) { $Manifest.Publisher } else { $null })
        SoftwareSite    = $(if ($Manifest -and $Manifest.PackageUrl) { $Manifest.PackageUrl } elseif ($Manifest) { $Manifest.PublisherUrl } else { $null })
        SoftwareLicense = $(if ($Manifest) { $Manifest.LicenseUrl } else { $null })
        License         = $(if ($Manifest) { $Manifest.License } else { $null })
        IconUrl         = $null
        Downloads       = $null
        IsLatest        = $true
        LicenseNote     = Get-ChocoLicenseNote $Id
        Source          = "Winget"
    }
}

function Get-WingetInfo {
    param([Parameter(Mandatory = $true)][string]$WingetId)

    if ($WingetId -notmatch $script:WingetIdPattern) { throw "'$WingetId' is not a valid winget package id" }
    $Found = Invoke-WingetFind -Id $WingetId | Select-Object -First 1
    if (-not $Found) { throw "winget package '$WingetId' was not found in the winget source" }

    # Publisher, description and license are only in the manifest (default locale, mostly en-US)
    $Manifest = $null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $Base = Get-WingetManifestUrl -Id $Found.Id -Version $Found.Version
        $Locale = "en-US"
        try {
            $VersionManifest = Get-WingetManifestValues ((Invoke-WebRequest -Uri "$Base/$($Found.Id).yaml" -UseBasicParsing -TimeoutSec 30).Content)
            if ($VersionManifest.DefaultLocale) { $Locale = $VersionManifest.DefaultLocale }
        }
        catch { }
        $Manifest = Get-WingetManifestValues ((Invoke-WebRequest -Uri "$Base/$($Found.Id).locale.$Locale.yaml" -UseBasicParsing -TimeoutSec 30).Content)
    }
    catch { Write-Verbose "Manifest of $WingetId could not be read: $($_.Exception.Message)" }
    return ConvertTo-WingetInfo -Found $Found -Manifest $Manifest
}#Returns the infos of a winget package

function Search-WingetPackage {
    param(
        [Parameter(Mandatory = $true)][string]$SearchPattern,
        [int]$Top = 40
    )
    $Term = $SearchPattern.Trim()
    # winget returns the matches alphabetically: put exact and leading matches of id and name first
    $Ranked = Invoke-WingetFind -Query $Term | Sort-Object -Property @(
        @{ Expression = { if ($_.Id -eq $Term -or $_.Name -eq $Term) { 0 } elseif ($_.Name -like "$Term*" -or ($_.Id -split '\.')[-1] -like "$Term*") { 1 } elseif ($_.Name -like "*$Term*") { 2 } else { 3 } } },
        @{ Expression = { $_.Name } }
    )
    foreach ($Found in @($Ranked | Select-Object -First $Top)) { ConvertTo-WingetInfo -Found $Found -Manifest $null }
}#Searches the winget community source

function Get-WingetPackageVersions {
    param([Parameter(Mandatory = $true)][string]$WingetId)
    if ($WingetId -notmatch $script:WingetIdPattern) { throw "'$WingetId' is not a valid winget package id" }
    $Found = Invoke-WingetFind -Id $WingetId | Select-Object -First 1
    if (-not $Found) { throw "winget package '$WingetId' was not found in the winget source" }
    @($Found.AvailableVersions | ForEach-Object { [string]$_ })
}#All versions of a package in the winget source

function New-WingetPackageScripts {
    <#
        Writes the package content (install.ps1 plus the update helpers update.ps1 and notify.ps1) into SourcePath
        and the detection script next to it. Same update modes as the Chocolatey apps; all values of the policy are
        baked into the scripts. winget cannot go back to an older version: a pinned version only moves forward.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$WingetId,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)]$Policy,
        [string]$DisplayName = ""
    )

    # Plain ASCII on purpose: Windows PowerShell reads BOM-less files as ANSI
    $GetWinget = @'
function Get-Winget {
    # winget.exe is not in the path of SYSTEM: take the newest App Installer for this processor
    $Arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
    $Folders = @(Get-ChildItem -Path (Join-Path $env:ProgramFiles "WindowsApps") -Filter "Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe" -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "winget.exe") })
    $Preferred = @($Folders | Where-Object { $_.Name -like "*_$($Arch)__*" })
    if ($Preferred.Count -gt 0) { $Folders = $Preferred }
    $Newest = $Folders | Sort-Object { try { [version](($_.Name -split "_")[1]) } catch { [version]"0.0" } } -Descending | Select-Object -First 1
    if ($Newest) { return Join-Path $Newest.FullName "winget.exe" }
    $InPath = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($InPath) { return $InPath.Source }
    return $null
}
'@

    $InstallScript = @'
# Installs or removes a winget package and applies its update policy (runs as SYSTEM through Intune).
param(
    [string]$Id = '__ID__',
    [string]$Version = '__VERSION__',
    [string]$Mode = '__MODE__',
    [int]$GraceHours = __GRACE__,
    [string]$DisplayName = '__DISPLAYNAME__',
    [string]$Policy = '__POLICY__',
    [switch]$Uninstall
)

# The Intune Management Extension starts 32-bit PowerShell; winget lives in the 64-bit WindowsApps folder
# (all values are baked in as defaults, so only -Uninstall has to be passed on)
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $Arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    if ($Uninstall) { $Arguments += "-Uninstall" }
    & "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe" @Arguments
    exit $LASTEXITCODE
}

$Root = Join-Path $env:ProgramData "IntuneWingetDeployment"
$SafeId = $Id -replace '[^A-Za-z0-9._-]', '_'
$AppRoot = Join-Path $Root $SafeId

__COMMON__

# The update helpers run as SYSTEM: their folders must not be writable for users
try {
    Protect-Folder $Root
    Protect-Folder (Join-Path $Root "Logs")
}
catch { Write-Output "The folder $Root could not be protected: $($_.Exception.Message)"; exit 1 }
Start-Transcript -Path (Join-Path $Root "Logs\$SafeId.log") -Append | Out-Null

__GETWINGET__

# Right after the setup (Autopilot) App Installer may not be registered yet: wait up to 10 minutes
$Winget = Get-Winget
for ($Wait = 0; -not $Winget -and $Wait -lt 20; $Wait++) { Write-Output "winget not found yet, waiting"; Start-Sleep -Seconds 30; $Winget = Get-Winget }
if (-not $Winget) { Write-Output "winget.exe not found (App Installer missing)"; Stop-Transcript | Out-Null; exit 1 }
Write-Output "Using $Winget"

$Common = @("--id", $Id, "--exact", "--source", "winget", "--silent", "--accept-source-agreements", "--disable-interactivity")
# Known winget results: no newer version / already installed count as success, reboot required as 3010
$Success = @(0, -1978335189, -1978335135)
$Reboot = @(-1978334967, -1978334966, 1641, 3010)
$NoApplicableInstaller = -1978335216
$NotInstalled = -1978335212

function Invoke-Winget([string]$Verb, [string[]]$Extra) {
    # Only the exit code is returned; the output of winget goes to the transcript.
    # Machine scope only: without it a user-scope installer would install into the profile of SYSTEM
    & $Winget $Verb @Common @Extra --scope machine | Out-Host
    $Code = $LASTEXITCODE
    if ($Code -eq $NoApplicableInstaller) { Write-Host "$Id has no machine-scope installer, it cannot be installed for all users of the device" }
    Write-Host "winget $Verb exit code $Code"
    return $Code
}

$TaskPath = "\Intune-Winget-Updates\"
$TaskNames = @("Update $SafeId on startup", "Update $SafeId now", "Check $SafeId for updates", "Notify $SafeId update")
function Remove-UpdateTasks {
    foreach ($Name in $TaskNames) { Unregister-ScheduledTask -TaskName $Name -TaskPath $TaskPath -Confirm:$false -ErrorAction SilentlyContinue }
}
# The update script of older versions of this tool
Remove-Item -Path (Join-Path $Root "$SafeId.ps1") -Force -ErrorAction SilentlyContinue

if ($Uninstall) {
    if (-not (Enter-DeploymentLock)) { Write-Output "Another choco or winget installation is still running"; Stop-Transcript | Out-Null; exit 1618 }
    # Without --source: winget often cannot map the installed product to its source entry
    & $Winget uninstall --id $Id --exact --silent --accept-source-agreements --disable-interactivity | Out-Host
    $ExitCode = $LASTEXITCODE
    Exit-DeploymentLock
    Write-Output "winget uninstall exit code $ExitCode"
    # Tasks, helpers and marker only go when the software is gone; otherwise Intune reports the error and retries
    if ($ExitCode -notin 0, $NotInstalled, 1605, 1614 -and $ExitCode -notin $Reboot) { Stop-Transcript | Out-Null; exit $ExitCode }
    Remove-UpdateTasks
    try { Remove-ItemSafely $AppRoot } catch { Write-Output "$AppRoot could not be removed: $($_.Exception.Message)" }
    Stop-Transcript | Out-Null
    if ($ExitCode -in $Reboot) { exit 3010 }
    exit 0
}

# The exit code tells whether it is installed; the table output cuts long ids ("...")
& $Winget list --id $Id --exact --source winget --accept-source-agreements --disable-interactivity 2>$null | Out-Null
$Installed = $LASTEXITCODE -eq 0
$VersionArguments = @("--accept-package-agreements")
if ($Version) { $VersionArguments += @("--version", $Version) }

try { Protect-Folder $AppRoot }
catch { Write-Output "The folder $AppRoot could not be protected: $($_.Exception.Message)"; Stop-Transcript | Out-Null; exit 1 }
# Which released version is installed: winget gives no plain answer, so the scripts remember it
$VersionFile = Join-Path $AppRoot "version.txt"
$AppliedVersion = if (Test-Path $VersionFile) { (Get-Content -Path $VersionFile -Raw).Trim() } else { "" }

# A new installation always installs. When only the policy changed (released version, update mode), the device
# follows its update mode: Off installs a released version right away (latest + Off leaves the installed version
# alone), Startup at the next startup, Custom asks the user and installs at the latest when the grace period is over.
$Upgrade = $Installed -and $Mode -eq "Off" -and $Version -and $AppliedVersion -ne $Version
if (-not (Enter-DeploymentLock)) { Write-Output "Another choco or winget installation is still running after 30 minutes"; Stop-Transcript | Out-Null; exit 1618 }
$ExitCode = 0
if (-not $Installed) { $ExitCode = Invoke-Winget "install" $VersionArguments }
elseif ($Upgrade) { $ExitCode = Invoke-Winget "upgrade" $VersionArguments }
Exit-DeploymentLock
$Applied = (-not $Installed) -or $Upgrade
if ($ExitCode -notin $Success -and $ExitCode -notin $Reboot) { Stop-Transcript | Out-Null; exit $ExitCode }

# Settings for the update helpers; a new policy starts its own grace period
try {
    foreach ($File in "update.ps1", "notify.ps1") {
        Remove-Item -LiteralPath (Join-Path $AppRoot $File) -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $File) -Destination $AppRoot -Force -ErrorAction Stop
    }
    Write-ProtectedFile (Join-Path $AppRoot "config.json") (@{ Id = $Id; SafeId = $SafeId; Version = $Version; Mode = $Mode; GraceHours = $GraceHours; DisplayName = $DisplayName } | ConvertTo-Json)
    Remove-Item -Path (Join-Path $AppRoot "state.json") -Force -ErrorAction SilentlyContinue
    if ($Applied -and $Version) { Write-ProtectedFile $VersionFile $Version }
    elseif (-not $Version) { Remove-Item -Path $VersionFile -Force -ErrorAction SilentlyContinue }
}
catch { Write-Output "The update helpers could not be copied: $($_.Exception.Message)"; Stop-Transcript | Out-Null; exit 1 }

Remove-UpdateTasks
try {
    $PowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $UpdateScript = Join-Path $AppRoot "update.ps1"
    $System = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
    $UpdateAction = { param($Step) New-ScheduledTaskAction -Execute $PowerShell -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$UpdateScript`" -Mode $Step" }

    if ($Mode -in "Startup", "Custom") {
        # Each device waits a random time, so a whole office does not download at the same moment
        $Trigger = New-ScheduledTaskTrigger -AtStartup
        $Trigger.Delay = "PT{0}M" -f (Get-Random -Minimum __DELAYMIN__ -Maximum (__DELAYMAX__ + 1))
        $Triggers = @($Trigger)
        if ($Mode -eq "Startup") {
            # With Fast Startup, shutting down is no real startup: also once a day at a random time between 10 and 15
            # o'clock (a missed run follows when the device is on again)
            $Triggers += New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.AddHours(10).AddMinutes((Get-Random -Maximum 300)))
        }
        # Custom only checks at startup: the user prompt and the grace period decide when the update is installed
        $StartupStep = if ($Mode -eq "Custom") { "Check" } else { "Startup" }
        Register-ScheduledTask -TaskName $TaskNames[0] -TaskPath $TaskPath -Action (& $UpdateAction $StartupStep) -Trigger $Triggers -Principal $System -Settings $Settings -Force -ErrorAction Stop | Out-Null
    }
    if ($Mode -eq "Custom") {
        # "Update now" from the user prompt: started on demand; signed-in users may run it (not change it)
        Register-ScheduledTask -TaskName $TaskNames[1] -TaskPath $TaskPath -Action (& $UpdateAction "Now") -Principal $System -Settings $Settings -Force -ErrorAction Stop | Out-Null
        $Service = New-Object -ComObject Schedule.Service
        $Service.Connect()
        $Service.GetFolder($TaskPath.TrimEnd("\")).GetTask($TaskNames[1]).SetSecurityDescriptor("D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;AU)", 0)

        # Every 4 hours: is there an update, is the grace period over?
        $Check = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes((Get-Random -Minimum 5 -Maximum 60)) -RepetitionInterval (New-TimeSpan -Hours 4) -RepetitionDuration (New-TimeSpan -Days 3650)
        Register-ScheduledTask -TaskName $TaskNames[2] -TaskPath $TaskPath -Action (& $UpdateAction "Check") -Trigger $Check -Principal $System -Settings $Settings -Force -ErrorAction Stop | Out-Null

        # The prompt runs in the session of every signed-in user (Users group), at logon and every hour, without a console window
        $Users = New-ScheduledTaskPrincipal -GroupId "S-1-5-32-545" -RunLevel Limited
        $NotifyScript = Join-Path $AppRoot "notify.ps1"
        $NotifyAction = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" -Argument "--headless `"$PowerShell`" -NoProfile -ExecutionPolicy Bypass -File `"$NotifyScript`""
        $NotifyTriggers = @(
            (New-ScheduledTaskTrigger -AtLogOn),
            (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(10) -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 3650))
        )
        $NotifySettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $TaskNames[3] -TaskPath $TaskPath -Action $NotifyAction -Trigger $NotifyTriggers -Principal $Users -Settings $NotifySettings -Force -ErrorAction Stop | Out-Null
    }
    Write-Output "Update mode $Mode applied for $Id"
}
catch {
    # Without its tasks the app is not set up: no marker, so detection fails and Intune runs install.ps1 again
    Write-Output "Update tasks could not be registered: $($_.Exception.Message)"
    Stop-Transcript | Out-Null
    exit 1
}

# The detection rule compares this marker with the policy in Intune
Write-ProtectedFile (Join-Path $AppRoot "policy.txt") $Policy
Stop-Transcript | Out-Null
if ($ExitCode -in $Reboot) { exit 3010 }
exit 0
'@

    $UpdateScript = @'
# Update helper of one winget app (scheduled tasks, SYSTEM). Settings come from config.json next to it.
#   Startup  update to the target version (startup task)
#   Check    update available? Remember since when; after the grace period install it
#   Now      install the update at once (started from the user prompt)
param([ValidateSet("Startup", "Check", "Now")][string]$Mode = "Check")

$Config = Get-Content -Path (Join-Path $PSScriptRoot "config.json") -Raw | ConvertFrom-Json
$Id = $Config.Id
$StateFile = Join-Path $PSScriptRoot "state.json"
$VersionFile = Join-Path $PSScriptRoot "version.txt"
$LogFile = Join-Path $PSScriptRoot "update.log"
function Write-Log([string]$Text) { Add-Content -Path $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $Mode, $Text) }

__GETWINGET__

$Winget = Get-Winget
if (-not $Winget) { Write-Log "winget.exe not found"; exit 1 }
$Common = @("--id", $Id, "--exact", "--source", "winget", "--silent", "--accept-source-agreements", "--accept-package-agreements", "--disable-interactivity")
$Success = @(0, -1978335189, -1978335135)
$Reboot = @(-1978334967, -1978334966, 1641, 3010)
$NoApplicableInstaller = -1978335216

__COMMON__

function Invoke-Upgrade {
    if (-not (Enter-DeploymentLock)) { Write-Log "another choco or winget installation is still running, next try later"; return 1618 }
    try {
        $VersionArguments = @()
        if ($Config.Version) { $VersionArguments = @("--version", $Config.Version) }
        # Machine scope only: without it a user-scope installer would install into the profile of SYSTEM
        & $Winget upgrade @Common @VersionArguments --scope machine | Out-Null
        $Code = $LASTEXITCODE
    }
    finally { Exit-DeploymentLock }
    if ($Code -eq $NoApplicableInstaller) { Write-Log "$Id has no machine-scope installer" }
    Write-Log "winget upgrade $Id exit code $Code"
    if ($Code -in $Success -or $Code -in $Reboot) {
        Remove-Item -Path $StateFile -Force -ErrorAction SilentlyContinue
        if ($Config.Version) { Write-ProtectedFile $VersionFile $Config.Version }
        if ($Code -in $Reboot) { return 3010 }
        return 0
    }
    return $Code
}

switch ($Mode) {
    "Now" { exit (Invoke-Upgrade) }
    "Startup" { exit (Invoke-Upgrade) }
    "Check" {
        # A released version: installed yet? Otherwise: does winget offer an upgrade?
        if ($Config.Version) {
            $Applied = if (Test-Path $VersionFile) { (Get-Content -Path $VersionFile -Raw).Trim() } else { "" }
            $Pending = $Applied -ne $Config.Version
            $Target = $Config.Version
        }
        else {
            & $Winget list --id $Id --exact --source winget --upgrade-available --accept-source-agreements --disable-interactivity 2>$null | Out-Null
            $Pending = $LASTEXITCODE -eq 0
            $Target = "latest"
        }
        if (-not $Pending) {
            Remove-Item -Path $StateFile -Force -ErrorAction SilentlyContinue
            exit 0
        }
        $State = $null
        if (Test-Path $StateFile) { try { $State = Get-Content -Path $StateFile -Raw | ConvertFrom-Json } catch { } }
        if (-not $State -or $State.Target -ne $Target) {
            $Now = Get-Date
            $State = [pscustomobject]@{
                Package     = $Config.SafeId
                DisplayName = $Config.DisplayName
                Installed   = ""
                Target      = $Target
                FirstSeen   = $Now.ToString("o")
                Deadline    = $Now.AddHours([int]$Config.GraceHours).ToString("o")
            }
            $State | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
            Write-Log "update to $Target available, installed automatically from $($State.Deadline)"
        }
        if ((Get-Date) -ge [datetime]$State.Deadline) {
            Write-Log "grace period is over"
            exit (Invoke-Upgrade)
        }
        exit 0
    }
}
'@

    $DetectionScript = @'
$Id = '__ID__'
$Policy = '__POLICY__'
# Installed with the update policy that is set in Intune (otherwise Intune runs install.ps1 again to apply it)
$SafeId = $Id -replace '[^A-Za-z0-9._-]', '_'
$Marker = Join-Path $env:ProgramData "IntuneWingetDeployment\$SafeId\policy.txt"
if (-not (Test-Path $Marker) -or (Get-Content -Path $Marker -Raw).Trim() -ne $Policy) { exit 1 }
$Arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
$Folders = @(Get-ChildItem -Path (Join-Path $env:ProgramFiles "WindowsApps") -Filter "Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe" -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName "winget.exe") })
$Preferred = @($Folders | Where-Object { $_.Name -like "*_$($Arch)__*" })
if ($Preferred.Count -gt 0) { $Folders = $Preferred }
$Newest = $Folders | Sort-Object { try { [version](($_.Name -split "_")[1]) } catch { [version]"0.0" } } -Descending | Select-Object -First 1
# WindowsApps is readable for SYSTEM (Intune); a signed-in user finds winget through its app alias
$Winget = if ($Newest) { Join-Path $Newest.FullName "winget.exe" } else { (Get-Command winget.exe -ErrorAction SilentlyContinue).Source }
if (-not $Winget) { exit 1 }
# The exit code tells whether it is installed; the table output cuts long ids ("...")
& $Winget list --id $Id --exact --source winget --accept-source-agreements --disable-interactivity 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Output "$Id is installed (update policy $Policy)"
    exit 0
}
exit 1
'@

    if ($WingetId -notmatch $script:WingetIdPattern) { throw "'$WingetId' is not a valid winget package id" }
    if ($Policy.UpdateDelayMinMinutes -lt 0 -or $Policy.UpdateDelayMaxMinutes -lt $Policy.UpdateDelayMinMinutes) { throw "Update delay range is invalid" }
    # Values go into single-quoted strings of ASCII files
    $Quote = { param($Text) ([string]$Text -replace '[^\x20-\x7E]', '').Replace("'", "''") }
    $CommonText = Get-DeviceScriptCommon
    $InstallScript = $InstallScript.Replace("__COMMON__", $CommonText)
    $UpdateScript = $UpdateScript.Replace("__COMMON__", $CommonText)
    $InstallScript = $InstallScript.Replace("__GETWINGET__", $GetWinget).Replace("__ID__", $WingetId).Replace("__VERSION__", (& $Quote $Policy.Version))
    $InstallScript = $InstallScript.Replace("__MODE__", $Policy.UpdateMode).Replace("__GRACE__", [string][int]$Policy.GraceHours)
    $InstallScript = $InstallScript.Replace("__DISPLAYNAME__", (& $Quote $DisplayName)).Replace("__POLICY__", $Policy.Fingerprint)
    $InstallScript = $InstallScript.Replace("__DELAYMIN__", [string]$Policy.UpdateDelayMinMinutes).Replace("__DELAYMAX__", [string]$Policy.UpdateDelayMaxMinutes)
    $UpdateScript = $UpdateScript.Replace("__GETWINGET__", $GetWinget)
    $DetectionScript = $DetectionScript.Replace("__ID__", $WingetId).Replace("__POLICY__", $Policy.Fingerprint)

    Set-Content -Path (Join-Path $SourcePath "install.ps1") -Value $InstallScript -Encoding ASCII
    Set-Content -Path (Join-Path $SourcePath "update.ps1") -Value $UpdateScript -Encoding ASCII
    Set-Content -Path (Join-Path $SourcePath "notify.ps1") -Value (Get-UpdateNotifyScript -TaskPath "\Intune-Winget-Updates\") -Encoding ASCII
    $DetectionFile = Join-Path (Split-Path $SourcePath) "detection.ps1"
    Set-Content -Path $DetectionFile -Value $DetectionScript -Encoding ASCII
    return $DetectionFile

}#Writes install.ps1 (winget as SYSTEM, with update task) into the package and the detection script next to it

function Get-WingetAppName {
    param([Parameter(Mandatory = $true)]$Info)
    # The curated name from catalog.json, otherwise the package name from the manifest
    $Entry = @(Get-IntuneChocoCatalog | Where-Object { $_.WingetId -eq $Info.Name }) | Select-Object -First 1
    if ($Entry -and $Entry.Name) { return $Entry.Name }
    if ([string]::IsNullOrWhiteSpace($Info.Title)) { return $Info.Name }
    return ([string]$Info.Title).Trim()
}#Display name of the app in Intune and the Company Portal

function New-IntuneWin32WingetApplication {
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [String[]]$WingetId,
        [ValidateSet("Available", "Required", "None")]
        [string]$Assignment = $script:Settings.Assignment,
        [ValidateSet("x64", "x86", "arm64", "x64x86", "AllWithARM64")]
        [string]$Architecture = $script:Settings.Architecture,
        [int]$UpdateDelayMinMinutes = $script:Settings.UpdateDelayMinMinutes,
        [int]$UpdateDelayMaxMinutes = $script:Settings.UpdateDelayMaxMinutes,
        # Off, Startup or Custom (user prompt, installed after GraceHours at the latest)
        [ValidateSet("Off", "Startup", "Custom")]
        [string]$UpdateMode = $script:Settings.UpdateMode,
        [ValidateRange(1, 2160)]
        [int]$GraceHours = $script:Settings.GraceHours,
        # "latest" = devices follow the newest version; "current" = pin today's version; or an exact version.
        # Empty = the VersionMode setting (Latest or Pinned)
        [string]$Version,
        [string]$IconFile,
        [string]$IconBase64,
        [switch]$NoIconPrompt
    )

    begin {
        Assert-IntuneChocoPrerequisites
        Assert-IntuneChocoConnection
        Assert-WingetClient
        $RuntimeId = $null
    }

    process {
        foreach ($Id in $WingetId) {
            try {
                Update-IntuneChocoToken

                Write-Host "Getting infos from winget for $Id"
                $Infos = Get-WingetInfo -WingetId $Id
                $Id = $Infos.Name
                $AppName = Get-WingetAppName -Info $Infos

                # Already there: same name, or created by this tool for the same package (also when renamed)
                $Existing = @(Invoke-IntuneModule { Get-IntuneWin32App } | Where-Object { $_.displayName -eq $AppName -or ([string]$_.notes -like "$($script:WingetMarker)*" -and (ConvertFrom-ChocoAppNotes ([string]$_.notes)).Package -eq $Id) })
                if ($Existing.Count -gt 0) {
                    Write-Warning "$AppName is already deployed ($($Existing[0].displayName)), please update or remove first"
                    continue
                }
                if ($Infos.LicenseNote) { Write-Warning "License: $($Infos.LicenseNote)" }

                # winget packages rarely have an icon: the same app in the catalog lends its Chocolatey icon
                Write-Host "Getting Icon"
                $Icon = $IconBase64
                if (-not $Icon) {
                    $ChocoId = @(Get-IntuneChocoCatalog | Where-Object { $_.WingetId -eq $Id }) | Select-Object -First 1 -ExpandProperty Id
                    $IconUrl = $null
                    if ($ChocoId -and -not $IconFile) { try { $IconUrl = (Get-ChocoInfo -ChocoName $ChocoId).IconUrl } catch { Write-Verbose $_ } }
                    $Icon = Get-ChocoIconBase64 -ChocoName ("winget-" + ($Id -replace '[^A-Za-z0-9._-]', '_')) -IconUrl $IconUrl -IconFile $IconFile -NoIconPrompt:$NoIconPrompt -NoFeedLookup
                }

                ### Update policy: version and update mode
                $PinnedVersion = switch ($Version) {
                    { $_ -eq "latest" } { ""; break }
                    { $_ -eq "current" } { $Infos.Version; break }
                    { -not $_ } { if ($script:Settings.VersionMode -eq "Pinned") { $Infos.Version } else { "" }; break }
                    default {
                        if ($Version -notin (Get-WingetPackageVersions -WingetId $Id)) { throw "Version $Version of $Id does not exist in the winget source" }
                        $Version
                    }
                }
                $Policy = New-ChocoAppPolicy -Package $Id -Version $PinnedVersion -UpdateMode $UpdateMode -GraceHours $GraceHours `
                    -UpdateDelayMinMinutes $UpdateDelayMinMinutes -UpdateDelayMaxMinutes $UpdateDelayMaxMinutes
                Write-Host ("Version: {0}, updates: {1}" -f $(if ($PinnedVersion) { $PinnedVersion } else { "always the latest" }), (Format-ChocoUpdateMode $Policy))

                Write-Host "Creating the install and detection script"
                $WorkPath = New-IntuneChocoWorkFolder -Name ("winget-" + ($Id -replace '[^A-Za-z0-9._-]', '_'))
                $DetectionFile = New-WingetPackageScripts -WingetId $Id -SourcePath (Join-Path $WorkPath "source") -Policy $Policy -DisplayName $AppName
                $IntuneWinFile = New-IntuneChocoPackage -WorkPath $WorkPath

                $DetectionRule = Invoke-IntuneModule { New-IntuneWin32AppDetectionRuleScript -ScriptFile $DetectionFile }
                # winget needs Windows 10 1809 or newer
                $RequirementRule = Invoke-IntuneModule { New-IntuneWin32AppRequirementRule -Architecture $Architecture -MinimumSupportedWindowsRelease W10_1809 }

                # winget runtime app (App Installer, registered for SYSTEM): created once per tenant, before the app so that nothing is left half done
                if ($null -eq $RuntimeId) { Write-Host "Checking if the winget runtime is deployed in Intune"; $RuntimeId = Get-WingetRuntimeWin32ID }
                Write-Host "Creating and Uploading $AppName as win32 App to Intune"
                $Description = if ($Infos.Description) { $Infos.Description } elseif ($Infos.Summary) { $Infos.Summary } else { $AppName }
                $AppParams = @{
                    FilePath             = $IntuneWinFile.Path
                    DisplayName          = $AppName
                    Description          = $Description
                    Publisher            = $(if ($Infos.Authors) { $Infos.Authors } else { "-" })
                    AppVersion           = $(if ($PinnedVersion) { $PinnedVersion } else { "latest" })
                    Notes                = ConvertTo-ChocoAppNotes -Policy $Policy -Marker $script:WingetMarker
                    InstallExperience    = "system"
                    RestartBehavior      = "suppress"
                    DetectionRule        = $DetectionRule
                    RequirementRule      = $RequirementRule
                    InstallCommandLine   = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1"
                    UninstallCommandLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall"
                }
                if ($Infos.SoftwareSite) { $AppParams.InformationURL = $Infos.SoftwareSite }
                if ($Icon) { $AppParams.Icon = $Icon }

                $IntuneApp = Invoke-IntuneModule { Add-IntuneWin32App @AppParams }
                if ($null -eq $IntuneApp -or -not $IntuneApp.id) { throw "Intune did not return the created app" }

                Write-Host "Adding dependency for the winget runtime to the created Application"
                Invoke-IntuneModule {
                    $Dependency = New-IntuneWin32AppDependency -ID $RuntimeId -DependencyType AutoInstall
                    Add-IntuneWin32AppDependency -ID $IntuneApp.id -Dependency $Dependency
                } | Out-Null

                Set-IntuneChocoAssignment -Id $IntuneApp.id -Assignment $Assignment
                Write-Host "Deployment of $AppName was successful"
                $IntuneApp.id
            }
            catch {
                Write-Error "Deployment of $Id failed: $($_.Exception.Message)"
            }
        }
    }
}#Deploys winget packages as Win32 apps
