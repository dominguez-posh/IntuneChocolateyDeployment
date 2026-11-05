<#
    winget packages as Win32 apps in Intune. Loaded by ChocoIntuneDeployment-Main.ps1, uses its helpers
    (work folder, packaging, icons, Invoke-IntuneModule, assignment).

    On the admin machine: package infos and search come from the Microsoft.WinGet.Client module (the winget
    community source) and from the package manifests in github.com/microsoft/winget-pkgs.
    On the devices: install.ps1 runs winget as SYSTEM (winget.exe is not in SYSTEM's path, it is looked up in
    WindowsApps) and registers a startup task "winget upgrade", like the Chocolatey apps. No dependency app is
    needed: winget is part of Windows 10 1809+ and Windows 11 (App Installer).

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

function New-WingetPackageScripts {
    param(
        [Parameter(Mandatory = $true)][string]$WingetId,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [int]$UpdateDelayMinMinutes = 5,
        [int]$UpdateDelayMaxMinutes = 60
    )

    # Plain ASCII on purpose: Windows PowerShell reads BOM-less files as ANSI
    $InstallScript = @'
param(
    [string]$Id = '__ID__',
    [switch]$Uninstall,
    # Run by the startup task: only upgrade, no new task
    [switch]$Update
)

# The Intune Management Extension starts 32-bit PowerShell; winget lives in the 64-bit WindowsApps folder
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $Arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-Id", $Id)
    if ($Uninstall) { $Arguments += "-Uninstall" }
    if ($Update) { $Arguments += "-Update" }
    & "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe" @Arguments
    exit $LASTEXITCODE
}

$Root = Join-Path $env:ProgramData "IntuneWingetDeployment"
$SafeId = $Id -replace '[^A-Za-z0-9._-]', '_'
New-Item -Path (Join-Path $Root "Logs") -ItemType Directory -Force | Out-Null
Start-Transcript -Path (Join-Path $Root "Logs\$SafeId.log") -Append | Out-Null

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

function Invoke-Winget([string]$Verb, [string[]]$Extra) {
    # Machine scope first; packages that only declare a user or no scope are tried without it
    & $Winget $Verb @Common @Extra --scope machine
    $Code = $LASTEXITCODE
    if ($Code -eq $NoApplicableInstaller) {
        Write-Output "No machine-scope installer, trying without scope"
        & $Winget $Verb @Common @Extra
        $Code = $LASTEXITCODE
    }
    Write-Output "winget $Verb exit code $Code"
    return $Code
}

$TaskName = "Update $SafeId on startup"
$TaskPath = "\Intune-Winget-Updates\"
$UpdateScript = Join-Path $Root "$SafeId.ps1"

if ($Uninstall) {
    & $Winget uninstall --id $Id --exact --source winget --silent --accept-source-agreements --disable-interactivity
    $ExitCode = $LASTEXITCODE
    Write-Output "winget uninstall exit code $ExitCode"
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $UpdateScript -Force -ErrorAction SilentlyContinue
    Stop-Transcript | Out-Null
    if ($ExitCode -in $Success) { exit 0 }
    exit $ExitCode
}

if ($Update) {
    $ExitCode = Invoke-Winget "upgrade" @("--accept-package-agreements")
    Stop-Transcript | Out-Null
    exit 0
}

$ExitCode = Invoke-Winget "install" @("--accept-package-agreements")
if ($ExitCode -in $Success -or $ExitCode -in $Reboot) {
    # Keeps the package up to date: winget upgrade on every startup, as SYSTEM, with this script copied next to the logs.
    # Each device waits a random time, so a whole office does not download at the same moment.
    try {
        Copy-Item -Path $PSCommandPath -Destination $UpdateScript -Force
        $Action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$UpdateScript`" -Update"
        $Trigger = New-ScheduledTaskTrigger -AtStartup
        $Trigger.Delay = "PT{0}M" -f (Get-Random -Minimum __DELAYMIN__ -Maximum (__DELAYMAX__ + 1))
        $Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
        Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Force | Out-Null
        Write-Output "Scheduled task $TaskPath$TaskName registered"
    }
    catch {
        Write-Output "Scheduled task could not be registered: $($_.Exception.Message)"
    }
}
Stop-Transcript | Out-Null
if ($ExitCode -in $Success) { exit 0 }
if ($ExitCode -in $Reboot) { exit 3010 }
exit $ExitCode
'@

    $DetectionScript = @'
$Id = '__ID__'
$Arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
$Folders = @(Get-ChildItem -Path (Join-Path $env:ProgramFiles "WindowsApps") -Filter "Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe" -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName "winget.exe") })
$Preferred = @($Folders | Where-Object { $_.Name -like "*_$($Arch)__*" })
if ($Preferred.Count -gt 0) { $Folders = $Preferred }
$Newest = $Folders | Sort-Object { try { [version](($_.Name -split "_")[1]) } catch { [version]"0.0" } } -Descending | Select-Object -First 1
# WindowsApps is readable for SYSTEM (Intune); a signed-in user finds winget through its app alias
$Winget = if ($Newest) { Join-Path $Newest.FullName "winget.exe" } else { (Get-Command winget.exe -ErrorAction SilentlyContinue).Source }
if (-not $Winget) { exit 1 }
$Output = & $Winget list --id $Id --exact --accept-source-agreements --disable-interactivity 2>$null
if ($LASTEXITCODE -eq 0 -and (@($Output) -match [regex]::Escape($Id))) {
    Write-Output "$Id is installed"
    exit 0
}
exit 1
'@

    if ($WingetId -notmatch $script:WingetIdPattern) { throw "'$WingetId' is not a valid winget package id" }
    if ($UpdateDelayMinMinutes -lt 0 -or $UpdateDelayMaxMinutes -lt $UpdateDelayMinMinutes) { throw "Update delay range is invalid" }
    $InstallScript = $InstallScript.Replace("__ID__", $WingetId).Replace("__DELAYMIN__", [string]$UpdateDelayMinMinutes).Replace("__DELAYMAX__", [string]$UpdateDelayMaxMinutes)
    $DetectionScript = $DetectionScript.Replace("__ID__", $WingetId)

    Set-Content -Path (Join-Path $SourcePath "install.ps1") -Value $InstallScript -Encoding ASCII
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
        [string]$IconFile,
        [string]$IconBase64,
        [switch]$NoIconPrompt
    )

    begin {
        Assert-IntuneChocoPrerequisites
        Assert-IntuneChocoConnection
        Assert-WingetClient
    }

    process {
        foreach ($Id in $WingetId) {
            try {
                Update-IntuneChocoToken

                Write-Host "Getting infos from winget for $Id"
                $Infos = Get-WingetInfo -WingetId $Id
                $Id = $Infos.Name
                $AppName = Get-WingetAppName -Info $Infos
                $Notes = "$($script:WingetMarker);package=$Id"

                # Already there: same name, or created by this tool for the same package (also when renamed)
                $Existing = @(Invoke-IntuneModule { Get-IntuneWin32App } | Where-Object { $_.displayName -eq $AppName -or [string]$_.notes -eq $Notes })
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

                Write-Host "Creating the install and detection script"
                $WorkPath = New-IntuneChocoWorkFolder -Name ("winget-" + ($Id -replace '[^A-Za-z0-9._-]', '_'))
                $DetectionFile = New-WingetPackageScripts -WingetId $Id -SourcePath (Join-Path $WorkPath "source") -UpdateDelayMinMinutes $UpdateDelayMinMinutes -UpdateDelayMaxMinutes $UpdateDelayMaxMinutes
                $IntuneWinFile = New-IntuneChocoPackage -WorkPath $WorkPath

                $DetectionRule = Invoke-IntuneModule { New-IntuneWin32AppDetectionRuleScript -ScriptFile $DetectionFile }
                # winget needs Windows 10 1809 or newer
                $RequirementRule = Invoke-IntuneModule { New-IntuneWin32AppRequirementRule -Architecture $Architecture -MinimumSupportedWindowsRelease W10_1809 }

                Write-Host "Creating and Uploading $AppName as win32 App to Intune"
                $Description = if ($Infos.Description) { $Infos.Description } elseif ($Infos.Summary) { $Infos.Summary } else { $AppName }
                $AppParams = @{
                    FilePath             = $IntuneWinFile.Path
                    DisplayName          = $AppName
                    Description          = $Description
                    Publisher            = $(if ($Infos.Authors) { $Infos.Authors } else { "-" })
                    Notes                = $Notes
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
