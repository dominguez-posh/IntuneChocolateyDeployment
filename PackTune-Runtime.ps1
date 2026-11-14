<#
    PackTune Runtime: the ONE dependency app of every app this tool deploys (Chocolatey and winget, AutoInstall).

    Its install script bootstraps Chocolatey (retry for the rate limit, download URL setting) and makes winget usable
    as SYSTEM (App Installer with its dependencies, Microsoft signature and root pinned), and registers one daily
    SYSTEM task that updates both. Detection: choco.exe and winget work, and the marker of the script revision is
    there; there is no time limit. Uninstall removes only the task and the marker of this tool, never Chocolatey or
    App Installer.

    Older tenants have two dependency apps instead: "Chocolatey" (marker FiredWithPowershell) and "winget runtime"
    (marker WingetRuntimeApp). They are recognized as old dependencies; Switch-PackTuneAppsToRuntime moves the
    apps of the tool over, Get-PackTuneUnusedDependencyApps lists the old ones nothing depends on any more (nothing
    is deleted automatically). Loaded by PackTune-Main.ps1.
#>

$script:RuntimeName = "PackTune Runtime"
$script:RuntimeMarker = "PackTuneRuntimeApp"
$script:OldWingetRuntimeName = "winget runtime"
$script:OldWingetRuntimeMarker = "WingetRuntimeApp"
# Raised when the install, update or detection script of the runtime app changes (part of its detection)
$script:RuntimeRevision = 3

#region scripts

function Get-PackTuneRuntimeScripts {
    # Install, update and detection script of the runtime app (plain ASCII, Windows PowerShell 5.1, runs as SYSTEM)
    $GetWinget = @'
function Get-Winget {
    # winget.exe is not in the path of SYSTEM: take the newest App Installer for this processor. Only from the
    # WindowsApps folder (TrustedInstaller); never from PATH, where a user could have put another winget.exe.
    $Arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
    $Apps = Join-Path $(if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }) "WindowsApps"
    $Folders = @(Get-ChildItem -Path $Apps -Filter "Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe" -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "winget.exe") })
    $Preferred = @($Folders | Where-Object { $_.Name -like "*_$($Arch)__*" })
    if ($Preferred.Count -gt 0) { $Folders = $Preferred }
    $Newest = $Folders | Sort-Object { try { [version](($_.Name -split "_")[1]) } catch { [version]"0.0" } } -Descending | Select-Object -First 1
    if ($Newest) { return Join-Path $Newest.FullName "winget.exe" }
    return $null
}
'@

    $Install = @'
# PackTune Runtime: makes Chocolatey and winget usable for SYSTEM and keeps both up to date with one daily task
# (runs as SYSTEM through Intune).
param([switch]$Uninstall)

# The Intune Management Extension starts 32-bit PowerShell; the App Installer lives in the 64-bit WindowsApps folder
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $Arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    if ($Uninstall) { $Arguments += "-Uninstall" }
    & "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe" @Arguments
    exit $LASTEXITCODE
}

$Revision = '__REVISION__'
$LogId = "_packtune-runtime"
$LogTag = if ($Uninstall) { "uninstall" } else { "install" }

__COMMON__

# %ProgramFiles%\PackTune\Runtime (see $ToolRoot); the folder of the earlier name is removed below
$RuntimeRoot = Join-Path $ToolRoot "Runtime"
$TaskPath = "\PackTune\Runtime\"
$OldTaskPath = "\Intune-Winget-Updates\"   # before the rename
$TaskName = "Update PackTune Runtime"
# The task of the earlier "winget runtime" app does the same job: replaced by this one
$OldTaskName = "Update winget runtime"

# The folders hold what runs as SYSTEM: users must not be able to write there
try {
    Protect-Folder $ToolRoot
    Protect-Folder $RuntimeRoot
    Protect-Folder (Join-Path $RuntimeRoot "Logs")
}
catch { Write-Output "The folder $RuntimeRoot could not be protected: $($_.Exception.Message)"; exit 1 }
Start-Transcript -Path (Join-Path $RuntimeRoot "Logs\runtime.log") -Append | Out-Null

__GETWINGET__

if ($Uninstall) {
    # Chocolatey and App Installer belong to the device: only the task and the marker of this tool go (detection fails again)
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath $OldTaskPath -Confirm:$false -ErrorAction SilentlyContinue
    Remove-OldTaskFolder $OldTaskPath
    Remove-OldToolFolder "Runtime"
    Remove-Item -LiteralPath (Join-Path $RuntimeRoot "ready.txt") -Force -ErrorAction SilentlyContinue
    Write-DeviceLog "uninstalled: task and marker removed, Chocolatey and App Installer stay"
    Write-Output "Chocolatey and winget stay installed"
    Stop-Transcript | Out-Null
    exit 0
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072

### Part 1: Chocolatey. The community repository allows only a few downloads per minute and IP: retry with a random
### wait, the device lock is held per attempt only (not while waiting)
$Choco = Join-Path $env:ProgramData "chocolatey\bin\choco.exe"
$DownloadUrl = '__DOWNLOADURL__'
if (-not (Test-Path -LiteralPath $Choco)) {
    if ($DownloadUrl) { $env:chocolateyDownloadUrl = $DownloadUrl }
    for ($Attempt = 1; $Attempt -le 4 -and -not (Test-Path -LiteralPath $Choco); $Attempt++) {
        if (-not (Enter-DeploymentLock)) { Write-Output "Another choco or winget installation is still running"; Stop-Transcript | Out-Null; exit 1618 }
        try {
            Set-ExecutionPolicy Bypass -Scope Process -Force
            Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        }
        catch { Write-Output "Chocolatey attempt $Attempt failed: $($_.Exception.Message)" }
        finally { Exit-DeploymentLock }
        if (-not (Test-Path -LiteralPath $Choco) -and $Attempt -lt 4) { Start-Sleep -Seconds (Get-Random -Minimum 60 -Maximum 300) }
    }
}
if (-not (Test-Path -LiteralPath $Choco)) { Write-Output "Chocolatey installation failed"; Write-DeviceLog "Chocolatey installation failed"; Stop-Transcript | Out-Null; exit 1 }
& $Choco --version | Out-Host
if ($LASTEXITCODE -ne 0) { Write-Output "choco.exe does not run (exit code $LASTEXITCODE)"; Write-DeviceLog "choco.exe does not run"; Stop-Transcript | Out-Null; exit 1 }

### Part 2: winget (App Installer) for SYSTEM
if (-not (Enter-DeploymentLock)) { Write-Output "Another choco or winget installation is still running"; Stop-Transcript | Out-Null; exit 1618 }
try {
    $Arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
    $Release = "https://github.com/microsoft/winget-cli/releases/latest/download"

    # Only packages signed by Microsoft are provisioned: the download is pinned to Microsoft's signature, not only to TLS
    $MicrosoftPublisher = "CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US"
    # Microsoft Root Certificate Authority 2011
    $MicrosoftRoots = @("8F43288AD272F3103B6FB1428485EA3014C0BCFE")
    function Assert-MicrosoftSigned([string]$Path) {
        $Signature = Get-AuthenticodeSignature -LiteralPath $Path
        $Signer = if ($Signature.SignerCertificate) { [string]$Signature.SignerCertificate.Subject } else { "" }
        if ([string]$Signature.Status -ne "Valid" -or $Signer -ne $MicrosoftPublisher) {
            throw "$(Split-Path -Path $Path -Leaf) is not validly signed by Microsoft (status $($Signature.Status), signer '$Signer'); nothing is installed"
        }
        # The chain must end in Microsoft's own root, not in a CA the enterprise trusts (TLS inspection could issue a
        # certificate with the Microsoft subject). Bundle and dependency packages all chain to this root (checked).
        $Chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        [void]$Chain.Build($Signature.SignerCertificate)
        $ChainRoot = if ($Chain.ChainElements.Count -gt 0) { [string]$Chain.ChainElements[$Chain.ChainElements.Count - 1].Certificate.Thumbprint } else { "" }
        if ($ChainRoot -notin $MicrosoftRoots) {
            throw "$(Split-Path -Path $Path -Leaf) does not chain to the Microsoft root (root '$ChainRoot'); nothing is installed"
        }
    }

    function Install-AppInstaller {
        # Provisions App Installer for all users with its dependencies, after checking their Microsoft signatures
        $Work = Join-Path $RuntimeRoot "download"
        if (Test-Path -LiteralPath $Work) { Remove-ItemSafely $Work }
        Protect-Folder $Work
        $Bundle = Join-Path $Work "AppInstaller.msixbundle"
        $Zip = Join-Path $Work "dependencies.zip"
        Invoke-WebRequest -Uri "$Release/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle" -OutFile $Bundle -UseBasicParsing
        Invoke-WebRequest -Uri "$Release/DesktopAppInstaller_Dependencies.zip" -OutFile $Zip -UseBasicParsing
        Expand-Archive -LiteralPath $Zip -DestinationPath (Join-Path $Work "dependencies") -Force
        $Dependencies = @(Get-ChildItem -Path (Join-Path $Work "dependencies\$Arch") -Filter "*.appx" -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        foreach ($File in @($Bundle) + $Dependencies) { Assert-MicrosoftSigned $File }
        Write-Output "Installing App Installer with $($Dependencies.Count) dependencies"
        if ($Dependencies.Count -gt 0) { Add-AppxProvisionedPackage -Online -PackagePath $Bundle -DependencyPackagePath $Dependencies -SkipLicense | Out-Null }
        else { Add-AppxProvisionedPackage -Online -PackagePath $Bundle -SkipLicense | Out-Null }
        Remove-ItemSafely $Work
    }

    $Winget = Get-Winget
    if (-not $Winget) {
        Write-Output "App Installer not found, installing it"
        try { Install-AppInstaller } catch { Write-Output "App Installer could not be provisioned: $($_.Exception.Message)" }
        # Registered for the system context as well (no error when it already is)
        try { Add-AppxPackage -RegisterByFamilyName -MainPackage "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe" -ErrorAction Stop } catch { Write-Output "Registration: $($_.Exception.Message)" }
        for ($Wait = 0; -not $Winget -and $Wait -lt 12; $Wait++) { Start-Sleep -Seconds 10; $Winget = Get-Winget }
    }
    if (-not $Winget) { Write-Output "winget.exe not found (App Installer is missing)"; Write-DeviceLog "winget.exe not found"; Stop-Transcript | Out-Null; exit 1 }
    Write-Output "Using $Winget"

    # winget must start for SYSTEM; if not, dependencies are missing
    & $Winget --version | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Output "winget does not start (exit code $LASTEXITCODE), installing App Installer and its dependencies again"
        try { Install-AppInstaller } catch { Write-Output "App Installer could not be provisioned: $($_.Exception.Message)" }
        $Winget = Get-Winget
        & $Winget --version | Out-Host
        if ($LASTEXITCODE -ne 0) { Write-Output "winget still does not start"; Write-DeviceLog "winget does not start"; Stop-Transcript | Out-Null; exit 1 }
    }
}
finally { Exit-DeploymentLock }

### One daily task updates Chocolatey and App Installer (SYSTEM); detection does not depend on it
try {
    Remove-Item -LiteralPath (Join-Path $RuntimeRoot "update.ps1") -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "update.ps1") -Destination $RuntimeRoot -Force -ErrorAction Stop
    foreach ($Name in $OldTaskName, $TaskName) { Unregister-ScheduledTask -TaskName $Name -TaskPath $OldTaskPath -Confirm:$false -ErrorAction SilentlyContinue }
    Remove-OldTaskFolder $OldTaskPath
    $PowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $Action = New-ScheduledTaskAction -Execute $PowerShell -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $RuntimeRoot 'update.ps1')`""
    $Triggers = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.AddHours(10).AddMinutes((Get-Random -Maximum 300)))))
    $System = New-ScheduledTaskPrincipal -UserId "S-1-5-18" -LogonType ServiceAccount -RunLevel Highest
    $Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $Action -Trigger $Triggers -Principal $System -Settings $Settings -Force -ErrorAction Stop | Out-Null
}
catch {
    Write-Output "The update task could not be registered: $($_.Exception.Message)"
    Write-DeviceLog "update task could not be registered: $($_.Exception.Message)"
    Stop-Transcript | Out-Null
    exit 1
}
# The folder of the earlier name (%ProgramFiles%\IntuneChocoDeployment\Runtime) is not needed any more
Remove-OldToolFolder "Runtime"
Remove-OldToolFolder "Winget\Runtime"
# The marker of this script version for the detection rule
Write-ProtectedFile (Join-Path $RuntimeRoot "ready.txt") $Revision
Write-DeviceLog "PackTune Runtime ready: choco $Choco, winget $Winget"
Stop-Transcript | Out-Null
exit 0
'@

    $Detection = @'
# choco.exe and winget work as SYSTEM and this script version has been installed (updates are a scheduled task)
$Revision = '__REVISION__'
$Marker = Join-Path $(if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }) "PackTune\Runtime\ready.txt"
__GETWINGET__
if (-not (Test-Path -LiteralPath $Marker) -or (Get-Content -LiteralPath $Marker -Raw).Trim() -ne $Revision) { exit 1 }
$Choco = Join-Path $env:ProgramData "chocolatey\bin\choco.exe"
if (-not (Test-Path -LiteralPath $Choco)) { exit 1 }
& $Choco --version 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { exit 1 }
$Winget = Get-Winget
if (-not $Winget) { exit 1 }
& $Winget --version 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { exit 1 }
Write-Output "PackTune Runtime is ready: $Choco, $Winget"
exit 0
'@

    $UpdateScript = @'
# Daily update of Chocolatey and App Installer (scheduled task, SYSTEM), at most every 20 hours, inside the device
# wide lock. Log: Intune Management Extension log folder (PackTune-_packtune-runtime.log).
$RuntimeRoot = $PSScriptRoot
$LogId = "_packtune-runtime"
$LogTag = "update"
$PackageSource = '__PACKAGESOURCE__'

__COMMON__

__GETWINGET__

try { if (Test-ForeignItem $RuntimeRoot) { Write-DeviceLog "folder is not protected, nothing done"; exit 1 } } catch { exit 1 }
$Stamp = Join-Path $RuntimeRoot "checked.txt"
if (Test-Path -LiteralPath $Stamp) {
    try {
        $Last = [datetime]::Parse((Get-Content -LiteralPath $Stamp -Raw).Trim(), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        if (([datetime]::UtcNow - $Last.ToUniversalTime()).TotalHours -lt 20) { Write-DeviceLog "checked less than 20 hours ago"; exit 0 }
    }
    catch { }
}
if (-not (Enter-DeploymentLock)) { Write-DeviceLog "another installation is still running, next run tries again"; exit 1618 }
$Failed = $false
try {
    $Choco = Join-Path $env:ProgramData "chocolatey\bin\choco.exe"
    if (Test-Path -LiteralPath $Choco) {
        $Arguments = @("upgrade", "chocolatey", "-y", "--no-progress", "--limit-output")
        if ($PackageSource) { $Arguments += @("--source", $PackageSource) }
        & $Choco @Arguments | Out-Null
        Write-DeviceLog "Chocolatey upgrade exit code $LASTEXITCODE"
        if ($LASTEXITCODE -notin 0, 1641, 3010) { $Failed = $true }
    }
    else { Write-DeviceLog "choco.exe not found"; $Failed = $true }

    $Winget = Get-Winget
    if ($Winget) {
        & $Winget upgrade --id Microsoft.AppInstaller --exact --source winget --silent --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Null
        # No newer version is not an error
        Write-DeviceLog "App Installer upgrade exit code $LASTEXITCODE"
        if ($LASTEXITCODE -notin 0, -1978335189, -1978335135) { $Failed = $true }
    }
    else { Write-DeviceLog "winget.exe not found"; $Failed = $true }
    # The next run tries again after a failure
    if (-not $Failed) { Write-ProtectedFile $Stamp ([datetime]::UtcNow.ToString("o")) }
}
finally { Exit-DeploymentLock }
exit 0
'@

    $Revision = [string]$script:RuntimeRevision
    $Common = Get-DeviceScriptCommon
    $Quote = { param($Text) ([string]$Text -replace '[^\x20-\x7E]', '').Replace("'", "''") }
    return [pscustomobject]@{
        Install   = $Install.Replace("__COMMON__", $Common).Replace("__GETWINGET__", $GetWinget).Replace("__REVISION__", $Revision).Replace("__DOWNLOADURL__", (& $Quote $script:Settings.ChocolateyDownloadUrl))
        Detection = $Detection.Replace("__GETWINGET__", $GetWinget).Replace("__REVISION__", $Revision)
        Update    = $UpdateScript.Replace("__COMMON__", $Common).Replace("__GETWINGET__", $GetWinget).Replace("__PACKAGESOURCE__", (& $Quote $script:Settings.PackageSource))
    }
}#Scripts of the PackTune Runtime app

#endregion

#region the app in the tenant

function Install-PackTuneRuntime {
    # Creates the "PackTune Runtime" Win32 app in the tenant (once; see Get-PackTuneRuntimeWin32ID)
    Assert-PackTunePrerequisites
    Assert-PackTuneConnection
    Write-Host "Starting to deploy the $($script:RuntimeName) as win32 app to Intune"

    $WorkPath = New-PackTuneWorkFolder -Name "_packtune-runtime"
    $SourcePath = Join-Path $WorkPath "source"
    $Scripts = Get-PackTuneRuntimeScripts
    Set-Content -Path (Join-Path $SourcePath "install.ps1") -Value $Scripts.Install -Encoding ASCII
    Set-Content -Path (Join-Path $SourcePath "update.ps1") -Value $Scripts.Update -Encoding ASCII
    $DetectionFile = Join-Path $WorkPath "detection.ps1"
    Set-Content -Path $DetectionFile -Value $Scripts.Detection -Encoding ASCII

    $Package = New-PackTunePackage -WorkPath $WorkPath
    $DetectionRule = Invoke-IntuneModule { New-IntuneWin32AppDetectionRuleScript -ScriptFile $DetectionFile }
    $RequirementRule = Invoke-IntuneModule { New-IntuneWin32AppRequirementRule -Architecture "AllWithARM64" -MinimumSupportedWindowsRelease W10_1809 }

    $App = Invoke-IntuneModule {
        Add-IntuneWin32App -FilePath $Package.Path -DisplayName $script:RuntimeName -RequirementRule $RequirementRule -Notes $script:RuntimeMarker `
            -Description "Makes Chocolatey and winget usable on the device and keeps both up to date. Dependency of every app deployed with PackTune." `
            -Publisher "PackTune" -RestartBehavior suppress -InstallExperience system `
            -InstallCommandLine "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1" `
            -UninstallCommandLine "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall" -DetectionRule $DetectionRule
    }
    if ($null -eq $App -or -not $App.id) { throw "The $($script:RuntimeName) could not be created in Intune" }
    Invoke-IntuneModule { Add-IntuneWin32AppAssignmentAllUsers -ID $App.id -Intent available -Notification hideAll } | Out-Null
    Write-Host "$($script:RuntimeName) successfully deployed"
    return $App.id
}#Deploys the PackTune Runtime app to the tenant

function Get-PackTuneRuntimeWin32ID {
    # The runtime app of the tenant, created once when it does not exist
    param([switch]$NoCreate)
    $App = @(Invoke-IntuneModule { Get-IntuneWin32App -DisplayName $script:RuntimeName } | Where-Object { $_.displayName -eq $script:RuntimeName -and [string]$_.notes -like "*$($script:RuntimeMarker)*" }) | Select-Object -First 1
    if ($App) { return $App.id }
    if ($NoCreate) { return $null }
    Write-Host "$($script:RuntimeName) is not in Intune, it will be deployed now"
    return Install-PackTuneRuntime
}#Returns the Intune ID of the PackTune Runtime app

# Names the interface and older code know: both dependency apps are now the one runtime
function get-ChocoWin32ID { Get-PackTuneRuntimeWin32ID }
function install-chocolatey { Install-PackTuneRuntime }
function Get-WingetRuntimeWin32ID { param([switch]$NoCreate) Get-PackTuneRuntimeWin32ID -NoCreate:$NoCreate }

function Set-PackTuneRuntimeDependency {
    # Gives one app the runtime as its AutoInstall dependency. The module replaces the whole dependency list on
    # every add, so the list is rebuilt: what the app has, without the old dependency apps, plus the runtime.
    param([Parameter(Mandatory = $true)][string]$AppId, [Parameter(Mandatory = $true)][string]$RuntimeId, [string[]]$OldIds = @())
    $Existing = @(Invoke-IntuneModule { Get-IntuneWin32AppDependency -ID $AppId } | Where-Object { $_ })
    $Keep = @($Existing | Where-Object { [string]$_.targetId -ne $RuntimeId -and [string]$_.targetId -notin $OldIds })
    Invoke-IntuneModule {
        $Copies = @(foreach ($Dependency in $Keep) {
                New-IntuneWin32AppDependency -ID $Dependency.targetId -DependencyType $(if ([string]$Dependency.dependencyType -eq "detect") { "Detect" } else { "AutoInstall" })
            })
        $Copies += New-IntuneWin32AppDependency -ID $RuntimeId -DependencyType AutoInstall
        Add-IntuneWin32AppDependency -ID $AppId -Dependency $Copies
    } | Out-Null
}

#endregion

#region old dependency apps, migration, state

function Get-PackTuneOldDependencyApps {
    # The two dependency apps of earlier versions: the Chocolatey app and the winget runtime app
    Assert-PackTunePrerequisites
    Assert-PackTuneConnection
    Update-PackTuneToken
    foreach ($App in @(Invoke-IntuneModule { Get-IntuneWin32App })) {
        $Notes = [string]$App.notes
        if ($Notes -like "*$($script:ChocoAppMarker)*" -and $App.displayName -eq "Chocolatey") { [pscustomobject]@{ Id = $App.id; DisplayName = $App.displayName; Kind = "Chocolatey" } }
        elseif ($Notes -like "*$($script:OldWingetRuntimeMarker)*" -and $App.displayName -eq $script:OldWingetRuntimeName) { [pscustomobject]@{ Id = $App.id; DisplayName = $App.displayName; Kind = "WingetRuntime" } }
    }
}#Old Chocolatey app and old winget runtime app

function Get-PackTuneAppsWithRuntimeState {
    # Per app of the tool: does it depend on the runtime, and on which old dependency apps
    param([string]$RuntimeId, [string[]]$OldIds = @())
    foreach ($App in @(Get-PackTuneTenantApps | Where-Object { -not $_.IsChocolatey })) {
        $Targets = @(Invoke-IntuneModule { Get-IntuneWin32AppDependency -ID $App.Id } | Where-Object { $_ } | ForEach-Object { [string]$_.targetId })
        [pscustomobject]@{
            Id = $App.Id; DisplayName = $App.DisplayName; Source = $App.Source
            HasRuntime = [bool]($RuntimeId -and $Targets -contains $RuntimeId)
            OldDependencies = @($Targets | Where-Object { $_ -in $OldIds })
        }
    }
}

function Get-PackTuneRuntimeState {
    <#
        What the interface shows under readiness: State is "Missing" (no PackTune Runtime in the tenant), "Migrate"
        (runtime there, but apps still depend on the old dependency apps or have no runtime dependency), "Ready".
        UnusedOld = old dependency apps nothing depends on (can be removed, see Remove-PackTuneUnusedDependencyApps).
    #>
    $RuntimeId = Get-PackTuneRuntimeWin32ID -NoCreate
    $Old = @(Get-PackTuneOldDependencyApps)
    $Apps = @(Get-PackTuneAppsWithRuntimeState -RuntimeId $RuntimeId -OldIds @($Old.Id))
    $OnOld = @($Apps | Where-Object { $_.OldDependencies.Count -gt 0 })
    $Without = @($Apps | Where-Object { -not $_.HasRuntime })
    $Unused = @(Get-PackTuneUnusedDependencyApps -OldApps $Old)
    $State = if (-not $RuntimeId) { "Missing" } elseif ($OnOld.Count -gt 0 -or $Without.Count -gt 0) { "Migrate" } else { "Ready" }
    [pscustomobject]@{
        State = $State; RuntimePresent = [bool]$RuntimeId; RuntimeId = $RuntimeId
        OldDependencyApps = $Old; AppsOnOldDependencies = $OnOld; AppsWithoutRuntime = $Without; UnusedOld = $Unused
    }
}#Runtime present / old dependencies in use, for the readiness list

function Switch-PackTuneAppsToRuntime {
    <#
        Moves the apps of the tool (both sources) to the PackTune Runtime: it becomes their dependency, the old
        dependency apps (Chocolatey, winget runtime) are taken away. Creates the runtime when it is missing. Without
        -AppId all apps of the tool; one row per app that changed. The old apps stay (Get-PackTuneUnusedDependencyApps).
    #>
    param([string[]]$AppId)
    Assert-PackTunePrerequisites
    Assert-PackTuneConnection
    Update-PackTuneToken
    $RuntimeId = Get-PackTuneRuntimeWin32ID
    $OldIds = @(Get-PackTuneOldDependencyApps | ForEach-Object { $_.Id })
    $Apps = @(Get-PackTuneAppsWithRuntimeState -RuntimeId $RuntimeId -OldIds $OldIds)
    if ($AppId) { $Apps = @($Apps | Where-Object { $_.Id -in $AppId }) }
    foreach ($App in $Apps) {
        if ($App.HasRuntime -and $App.OldDependencies.Count -eq 0) { continue }
        Set-PackTuneRuntimeDependency -AppId $App.Id -RuntimeId $RuntimeId -OldIds $OldIds
        [pscustomobject]@{ Id = $App.Id; DisplayName = $App.DisplayName; Source = $App.Source; Added = (-not $App.HasRuntime); OldRemoved = $App.OldDependencies.Count }
    }
}#Switches the apps of the tool to the one runtime dependency

function Get-PackTuneUnusedDependencyApps {
    # Old dependency apps that no app in the tenant depends on any more (so they can be removed). Nothing is deleted.
    param($OldApps)
    if ($null -eq $OldApps) { $OldApps = @(Get-PackTuneOldDependencyApps) }
    $OldApps = @($OldApps | Where-Object { $_ })
    if ($OldApps.Count -eq 0) { return @() }
    $Used = @{}
    foreach ($App in @(Invoke-IntuneModule { Get-IntuneWin32App })) {
        foreach ($Dependency in @(Invoke-IntuneModule { Get-IntuneWin32AppDependency -ID $App.id } | Where-Object { $_ })) { $Used[[string]$Dependency.targetId] = $true }
    }
    @($OldApps | Where-Object { -not $Used.ContainsKey([string]$_.Id) })
}#Old dependency apps nothing depends on

function Remove-PackTuneUnusedDependencyApps {
    # Removes the old dependency apps nothing depends on (on request, never automatic). -WhatIf only lists them.
    param([switch]$WhatIf)
    foreach ($Old in @(Get-PackTuneUnusedDependencyApps)) {
        if (-not $WhatIf) { Invoke-IntuneModule { Remove-IntuneWin32App -ID $Old.Id } | Out-Null }
        [pscustomobject]@{ Id = $Old.Id; DisplayName = $Old.DisplayName; Kind = $Old.Kind; Removed = (-not $WhatIf) }
    }
}#Removes unused old dependency apps

# What the interface already calls: apps without the runtime dependency / adding it. Now for both sources; the old
# dependency apps are switched over at the same time.
function Get-PackTuneAppsWithoutRuntime {
    $RuntimeId = Get-PackTuneRuntimeWin32ID -NoCreate
    $OldIds = @(Get-PackTuneOldDependencyApps | ForEach-Object { $_.Id })
    Get-PackTuneAppsWithRuntimeState -RuntimeId $RuntimeId -OldIds $OldIds | Where-Object { -not $_.HasRuntime -or $_.OldDependencies.Count -gt 0 }
}
function Add-PackTuneRuntimeDependency { param([string[]]$AppId) Switch-PackTuneAppsToRuntime -AppId $AppId | ForEach-Object { $_ | Add-Member -NotePropertyName AlreadyThere -NotePropertyValue (-not $_.Added) -PassThru } }

#endregion
