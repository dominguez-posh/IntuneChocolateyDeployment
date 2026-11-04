<#
    Deploys Chocolatey packages as Win32 apps to Microsoft Intune.

    Run directly (connects and opens the software list):
        .\ChocoIntuneDeployment-Main.ps1 -TenantID "contoso.onmicrosoft.com" -ClientID "<app registration id>"

    Or dot-source it to use the functions manually:
        . .\ChocoIntuneDeployment-Main.ps1
        Connect-IntuneChoco -TenantID "contoso.onmicrosoft.com" -ClientID "<app registration id>"
        New-IntuneWin32ChocoApplication -ChocoName "googlechrome"

    Graphical interface: .\Start-IntuneChocoGui.ps1

    First use: run Install-IntunechocoComponents once to install the IntuneWin32App module.
    Works with Windows PowerShell 5.1 and PowerShell 7 on Windows 10 and Windows 11.
#>
[CmdletBinding()]
param(
    [string]$TenantID,
    [string]$ClientID
)

$script:WorkRoot = Join-Path $env:LOCALAPPDATA "IntuneChocoDeployment"
$script:SettingsPath = Join-Path $script:WorkRoot "settings.json"
$script:CatalogPath = Join-Path $PSScriptRoot "catalog.json"
$script:MinimumModuleVersion = [version]"1.5.0"
$script:ChocoAppMarker = "FiredWithPowershell"
$script:AppMarker = "PoweredByChocolatey"

$script:DefaultSettings = [ordered]@{
    TenantID              = ""
    ClientID              = ""
    # Package infos, icons and search
    MetadataFeed          = "https://community.chocolatey.org/api/v2"
    # choco --source on the endpoints, empty = community repository
    PackageSource         = ""
    # nupkg URL the Chocolatey bootstrap installs from, empty = community repository
    ChocolateyDownloadUrl = ""
    Architecture          = "x64x86"
    Assignment            = "Available"
    # The startup update task waits a random time in this range, so devices behind one IP don't download at once
    UpdateDelayMinMinutes = 5
    UpdateDelayMaxMinutes = 60
}

# Packages whose software license restricts business use or distribution
$script:LicenseNotes = @{
    "jre8"                 = "Oracle Java: commercial use requires a paid Oracle Java SE subscription. Use Eclipse Temurin (temurin21jre, temurin8jre) instead."
    "jdk8"                 = "Oracle Java: commercial use requires a paid Oracle Java SE subscription. Use Eclipse Temurin (temurin21, temurin8) instead."
    "teamviewer"           = "The free TeamViewer version is for private use only. Business use requires a TeamViewer license."
    "teamviewer.host"      = "The free TeamViewer version is for private use only. Business use requires a TeamViewer license."
    "teamviewer-qs"        = "The free TeamViewer version is for private use only. Business use requires a TeamViewer license."
    "anydesk"              = "The free AnyDesk version is for private use only. Business use requires an AnyDesk license."
    "adobereader"          = "Distributing Acrobat Reader inside an organization requires a (free) Adobe distribution agreement."
    "adobe-creative-cloud" = "Requires Adobe Creative Cloud licenses for the users."
    "sublimetext4"         = "Sublime Text requires a paid license for continued use."
    "1password"            = "Requires a 1Password subscription for the users."
}

function Get-IntuneChocoSettings {
    $Settings = [ordered]@{}
    foreach ($Key in $script:DefaultSettings.Keys) { $Settings[$Key] = $script:DefaultSettings[$Key] }
    if (Test-Path $script:SettingsPath) {
        try {
            $Saved = Get-Content -Path $script:SettingsPath -Raw | ConvertFrom-Json
            foreach ($Property in $Saved.PSObject.Properties) {
                if ($Settings.Contains($Property.Name)) { $Settings[$Property.Name] = $Property.Value }
            }
        }
        catch { Write-Warning "Settings file $($script:SettingsPath) is unreadable, using defaults" }
    }
    return [pscustomobject]$Settings
}#Returns the saved settings merged with the defaults

function Save-IntuneChocoSettings {
    param([Parameter(Mandatory = $true)]$Settings)

    $Clean = [ordered]@{}
    foreach ($Key in $script:DefaultSettings.Keys) {
        $Value = $Settings.$Key
        if ($null -eq $Value) { $Value = $script:DefaultSettings[$Key] }
        if ($script:DefaultSettings[$Key] -is [int]) { $Value = [int]$Value } else { $Value = ([string]$Value).Trim() }
        $Clean[$Key] = $Value
    }
    if ($Clean.Architecture -notin "x64", "x86", "arm64", "x64x86", "AllWithARM64") { throw "Unknown architecture '$($Clean.Architecture)'" }
    if ($Clean.Assignment -notin "Available", "Required", "None") { throw "Unknown assignment '$($Clean.Assignment)'" }
    if ($Clean.UpdateDelayMinMinutes -lt 0 -or $Clean.UpdateDelayMaxMinutes -lt $Clean.UpdateDelayMinMinutes) { throw "Update delay range is invalid" }
    if ($Clean.MetadataFeed -notmatch '^https?://') { throw "The metadata feed must be an http(s) URL" }

    New-Item -Path $script:WorkRoot -ItemType Directory -Force | Out-Null
    $Clean | ConvertTo-Json | Set-Content -Path $script:SettingsPath -Encoding UTF8
    $script:Settings = [pscustomobject]$Clean
    return $script:Settings
}#Validates and saves the settings

$script:Settings = Get-IntuneChocoSettings

function Get-ChocoLicenseNote {
    param([string]$ChocoName)
    if (-not $ChocoName) { return $null }
    return $script:LicenseNotes[$ChocoName.ToLower()]
}#Returns a license warning for the package, or $null

function Install-IntunechocoComponents {
    # IntuneWin32App 1.5.0 or newer is required (older versions break packaging, see issue #5, and dependencies, see issue #3)
    Install-Module IntuneWin32App -MinimumVersion $script:MinimumModuleVersion -Scope CurrentUser -Force -AllowClobber
    Import-Module IntuneWin32App -MinimumVersion $script:MinimumModuleVersion -Force
    Write-Host "IntuneWin32App $((Get-Module IntuneWin32App).Version) is installed. Chocolatey and Inkscape are no longer needed on this machine."
}#Installs all required script components

function Assert-IntuneChocoPrerequisites {
    $Module = Get-Module -ListAvailable IntuneWin32App | Sort-Object Version -Descending | Select-Object -First 1
    if ($null -eq $Module -or $Module.Version -lt $script:MinimumModuleVersion) {
        throw "IntuneWin32App $($script:MinimumModuleVersion) or newer is required (found: $(if ($Module) { $Module.Version } else { 'none' })). Run Install-IntunechocoComponents first."
    }
    if (-not (Get-Module IntuneWin32App | Where-Object Version -ge $script:MinimumModuleVersion)) {
        Import-Module IntuneWin32App -MinimumVersion $script:MinimumModuleVersion -Force
    }
}#Makes sure a working IntuneWin32App version is loaded

function Connect-IntuneChoco {
    param(
        [Parameter(Mandatory = $true)][string]$TenantID,
        [Parameter(Mandatory = $true)][string]$ClientID
    )
    Assert-IntuneChocoPrerequisites
    Connect-MSIntuneGraph -TenantID $TenantID -ClientID $ClientID -Interactive | Out-Null
    Assert-IntuneChocoConnection
    $script:Settings.TenantID = $TenantID
    $script:Settings.ClientID = $ClientID
    Write-Host "Connected to Intune tenant $TenantID"
}#Connects to the Intune Graph API with an Entra ID app registration

function Assert-IntuneChocoConnection {
    # The module functions call "break" when no token exists, which would silently stop the whole script
    if ($null -eq $Global:AccessToken) {
        throw "Not connected to Intune. Run Connect-IntuneChoco -TenantID <tenant> -ClientID <app id> first."
    }
}

function Update-IntuneChocoToken {
    Assert-IntuneChocoConnection
    $ExpiresOn = $Global:AccessToken.ExpiresOn
    if ($ExpiresOn -and ([datetime]$ExpiresOn).ToUniversalTime() -lt (Get-Date).ToUniversalTime().AddMinutes(10) -and $script:Settings.ClientID) {
        Write-Host "Refreshing the Intune access token"
        Connect-MSIntuneGraph -TenantID $Global:AccessTokenTenantID -ClientID $script:Settings.ClientID -Refresh | Out-Null
    }
}#Silently renews the token before it runs out (long bulk deployments)

function Get-IntuneChocoAuthState {
    return @{
        AccessToken          = $Global:AccessToken
        AuthenticationHeader = $Global:AuthenticationHeader
        AccessTokenTenantID  = $Global:AccessTokenTenantID
    }
}

function Set-IntuneChocoAuthState {
    param($State)
    $Global:AccessToken = $State.AccessToken
    $Global:AuthenticationHeader = $State.AuthenticationHeader
    $Global:AccessTokenTenantID = $State.AccessTokenTenantID
}#Hands the sign-in over to another runspace (used by the GUI)

function Invoke-ChocoFeed {
    param([Parameter(Mandatory = $true)][string]$Query)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $Uri = if ($Query -match '^https?://') { $Query } else { $script:Settings.MetadataFeed.TrimEnd("/") + "/" + $Query }
    $Response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -ErrorAction Stop
    $Xml = [xml]$Response.Content
    foreach ($Entry in @($Xml.feed.entry)) {
        if ($null -eq $Entry) { continue }
        $Properties = $Entry.properties
        [pscustomobject]@{
            Name            = $Entry.title.InnerText
            Title           = $Properties.Title
            Version         = $Properties.Version
            Summary         = $Properties.Summary
            Description     = $Properties.Description
            Authors         = $Entry.author.name
            SoftwareSite    = $Properties.ProjectUrl
            SoftwareLicense = $Properties.LicenseUrl
            IconUrl         = $Properties.IconUrl
            Downloads       = $Properties.DownloadCount.InnerText
            IsLatest        = $Properties.IsLatestVersion.InnerText -eq "true"
            LicenseNote     = Get-ChocoLicenseNote $Entry.title.InnerText
        }
    }
    # The feed pages its results (FindPackagesById returns 40 versions per page)
    $Next = @($Xml.feed.link) | Where-Object { $_.rel -eq "next" } | Select-Object -First 1
    if ($Next -and $Query -match 'FindPackagesById') { Invoke-ChocoFeed -Query $Next.href }
}#Queries the Chocolatey feed (NuGet v2 OData), no local chocolatey needed

function Get-ChocoInfo {
    param(
        [Parameter(Mandatory = $true)][string]$ChocoName
    )

    $Id = [uri]::EscapeDataString($ChocoName.ToLower().Replace("'", "''"))
    $Info = $null
    try {
        $Info = Invoke-ChocoFeed -Query "Packages()?`$filter=tolower(Id)%20eq%20'$Id'%20and%20IsLatestVersion" | Select-Object -First 1
    }
    catch {
        # Chocolatey only guarantees the queries choco itself sends; this one is what choco v2 uses
        Write-Verbose "Packages() query failed ($($_.Exception.Message)), falling back to FindPackagesById"
    }
    if ($null -eq $Info) {
        $Info = Invoke-ChocoFeed -Query "FindPackagesById()?id='$Id'&semVerLevel=2.0.0" | Where-Object IsLatest | Select-Object -First 1
    }
    if ($null -eq $Info) {
        throw "Chocolatey package '$ChocoName' was not found on $($script:Settings.MetadataFeed)"
    }

    if ([string]::IsNullOrWhiteSpace($Info.Title)) { $Info.Title = $Info.Name }
    if ([string]::IsNullOrWhiteSpace($Info.Description)) { $Info.Description = $Info.Summary }
    if ([string]::IsNullOrWhiteSpace($Info.Description)) { $Info.Description = $Info.Title }
    return $Info

}#Returns The Infos of Choco Repository

function Search-ChocoPackage {
    param(
        [Parameter(Mandatory = $true)][string]$SearchPattern,
        [int]$Top = 30
    )
    $Term = [uri]::EscapeDataString($SearchPattern.Replace("'", "''"))
    Invoke-ChocoFeed -Query "Search()?searchTerm='$Term'&targetFramework=''&includePrerelease=false&`$filter=IsLatestVersion&`$top=$Top"
}#Searches the Chocolatey community feed

function Select-FromList {
    param(
        [Parameter(Mandatory = $true)]$Items,
        [Parameter(Mandatory = $true)][string]$Title,
        [string[]]$Property
    )
    $Items = @($Items)
    if ($Items.Count -eq 0) { return }

    # Out-GridView is only built into Windows PowerShell; PowerShell 7 gets a console menu instead
    if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
        return $Items | Select-Object -Property $Property | Out-GridView -Title $Title -PassThru | ForEach-Object {
            $Selected = $_
            $Items | Where-Object { $_.($Property[0]) -eq $Selected.($Property[0]) } | Select-Object -First 1
        }
    }

    Write-Host $Title
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $Text = ($Property | ForEach-Object { $Items[$i].$_ }) -join " | "
        Write-Host ("{0,4}  {1}" -f ($i + 1), $Text)
    }
    $Answer = Read-Host "Numbers separated by comma (empty = cancel)"
    foreach ($Number in ($Answer -split "[,; ]+" | Where-Object { $_ -match '^\d+$' })) {
        $Index = [int]$Number - 1
        if ($Index -ge 0 -and $Index -lt $Items.Count) { $Items[$Index] }
    }
}#Lets the user pick one or more entries

function Get-ChocoPackageBySearch {

    $SearchPattern = Read-Host "Enter the Software you want to Install"
    if ([string]::IsNullOrWhiteSpace($SearchPattern)) { return }

    $Results = Search-ChocoPackage -SearchPattern $SearchPattern
    $Selection = Select-FromList -Items $Results -Title "Select Application" -Property Name, Title, Version, Downloads

    return $Selection.Name

}

function ConvertTo-PngBytes {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$WorkPath
    )

    # PNG and JPEG are accepted by Intune as they are
    if ($Bytes.Length -gt 4 -and $Bytes[0] -eq 0x89 -and $Bytes[1] -eq 0x50 -and $Bytes[2] -eq 0x4E -and $Bytes[3] -eq 0x47) { return ,$Bytes }
    if ($Bytes.Length -gt 3 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xD8 -and $Bytes[2] -eq 0xFF) { return ,$Bytes }

    $Head = [Text.Encoding]::UTF8.GetString($Bytes, 0, [Math]::Min($Bytes.Length, 1024))
    if ($Head -match '<svg|<\?xml') {
        # SVG: render with headless Edge, which every Windows 10/11 machine has (replaces the Inkscape dependency)
        $Edge = @(
            "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
            "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $Edge) { throw "Microsoft Edge was not found, cannot convert the SVG icon" }

        $Html = Join-Path $WorkPath "icon.html"
        $Png = Join-Path $WorkPath "icon.png"
        $EdgeProfile = Join-Path $WorkPath "edge"
        if (Test-Path $Png) { Remove-Item $Png -Force }
        $Svg = [Convert]::ToBase64String($Bytes)
        Set-Content -Path $Html -Encoding ASCII -Value ("<html><body style='margin:0;background:transparent'>" +
            "<img src='data:image/svg+xml;base64,$Svg' style='width:256px;height:256px;object-fit:contain;display:block'></body></html>")
        $Arguments = @(
            "--headless=new", "--disable-gpu", "--hide-scrollbars", "--default-background-color=00000000",
            "--no-first-run", "--window-size=256,256", "--user-data-dir=`"$EdgeProfile`"",
            "--screenshot=`"$Png`"", ("file:///" + $Html.Replace('\', '/'))
        )
        # Headless Edge sometimes keeps running after writing the screenshot: wait for the file, not for the process
        $Process = Start-Process -FilePath $Edge -ArgumentList $Arguments -WindowStyle Hidden -PassThru
        $Deadline = (Get-Date).AddSeconds(30)
        $LastSize = -1
        while ((Get-Date) -lt $Deadline) {
            Start-Sleep -Milliseconds 300
            $Size = if (Test-Path $Png) { (Get-Item $Png).Length } else { -1 }
            if ($Size -gt 0 -and ($Size -eq $LastSize -or $Process.HasExited)) { break }
            if ($Process.HasExited -and $Size -le 0) { break }
            $LastSize = $Size
        }
        # Stop exactly this Edge instance (recognized by its own profile folder), never the user's browser
        Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*$EdgeProfile*" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        if (-not (Test-Path $Png) -or (Get-Item $Png).Length -eq 0) { throw "Edge did not render the SVG icon within 30 seconds" }
        return ,[IO.File]::ReadAllBytes($Png)
    }

    # ICO, GIF, BMP and the like
    Add-Type -AssemblyName System.Drawing
    $InStream = New-Object IO.MemoryStream(, $Bytes)
    $OutStream = New-Object IO.MemoryStream
    try {
        $Image = [Drawing.Image]::FromStream($InStream)
        $Image.Save($OutStream, [Drawing.Imaging.ImageFormat]::Png)
        $Image.Dispose()
        return ,$OutStream.ToArray()
    }
    finally {
        $InStream.Dispose()
        $OutStream.Dispose()
    }
}#Converts any icon format to PNG or JPEG bytes

function Get-ChocoIconBase64 {
    param(
        [Parameter(Mandatory = $true)][string]$ChocoName,
        [string]$IconUrl,
        [string]$IconFile,
        [switch]$NoIconPrompt
    )

    $WorkPath = Join-Path $script:WorkRoot "icons\$ChocoName"
    New-Item -Path $WorkPath -ItemType Directory -Force | Out-Null

    if (-not $IconFile -and -not $IconUrl) {
        try { $IconUrl = (Get-ChocoInfo -ChocoName $ChocoName).IconUrl } catch { Write-Warning $_ }
    }

    $Bytes = $null
    if ($IconFile) {
        $Bytes = [IO.File]::ReadAllBytes((Resolve-Path $IconFile).ProviderPath)
    }
    elseif ($IconUrl) {
        try {
            $Download = Join-Path $WorkPath "download"
            Invoke-WebRequest -Uri $IconUrl -OutFile $Download -UseBasicParsing -ErrorAction Stop
            $Bytes = [IO.File]::ReadAllBytes($Download)
        }
        catch { Write-Warning "Icon could not be downloaded from $IconUrl ($($_.Exception.Message))" }
    }
    else {
        Write-Warning "Package $ChocoName has no icon on chocolatey.org"
    }

    if ($null -ne $Bytes) {
        try { return [Convert]::ToBase64String((ConvertTo-PngBytes -Bytes $Bytes -WorkPath $WorkPath)) }
        catch { Write-Warning "Icon could not be converted ($($_.Exception.Message))" }
    }

    if (-not $NoIconPrompt -and -not $IconFile -and [Environment]::UserInteractive) {
        Add-Type -AssemblyName System.Windows.Forms
        $FileBrowser = New-Object System.Windows.Forms.OpenFileDialog -Property @{
            Title            = "Select an icon for $ChocoName (Cancel = no icon)"
            InitialDirectory = [Environment]::GetFolderPath('Desktop')
            Filter           = 'Images (*.png;*.jpg;*.jpeg;*.svg;*.ico)|*.png;*.jpg;*.jpeg;*.svg;*.ico'
        }
        if ($FileBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return Get-ChocoIconBase64 -ChocoName $ChocoName -IconFile $FileBrowser.FileName -NoIconPrompt
        }
    }

    # Intune accepts apps without icon, so a missing icon never stops the deployment (issue #4)
    Write-Warning "$ChocoName will be created without an icon"
    return $null

}#Returns a Intune-Deployment-ready Base64-Coded PNG, or $null if there is no usable icon

function New-ChocoPackageScripts {
    param(
        [Parameter(Mandatory = $true)][string]$ChocoName,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [string]$PackageSource = "",
        [int]$UpdateDelayMinMinutes = 5,
        [int]$UpdateDelayMaxMinutes = 60
    )

    # Plain ASCII on purpose: Windows PowerShell reads BOM-less files as ANSI
    $InstallScript = @'
param(
    [string]$Package = '__PACKAGE__',
    [string]$Source = '__SOURCE__',
    [switch]$Uninstall
)

# The Intune Management Extension starts 32-bit PowerShell; choco and many packages need the 64-bit one
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $Arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-Package", $Package)
    if ($Source) { $Arguments += @("-Source", "`"$Source`"") }
    if ($Uninstall) { $Arguments += "-Uninstall" }
    & "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe" @Arguments
    exit $LASTEXITCODE
}

$ChocoRoot = $env:ChocolateyInstall
if (-not $ChocoRoot) { $ChocoRoot = Join-Path $env:ProgramData "chocolatey" }
$Choco = Join-Path $ChocoRoot "bin\choco.exe"
if (-not (Test-Path $Choco)) { Write-Output "choco.exe not found in $ChocoRoot"; exit 1 }

$TaskName = "Update $Package on startup"
$TaskPath = "\Intune-Choco-Updates\"

if ($Uninstall) {
    & $Choco uninstall $Package -y --no-progress
    $ExitCode = $LASTEXITCODE
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false -ErrorAction SilentlyContinue
    exit $ExitCode
}

$SourceArguments = @()
$SourceText = ""
if ($Source) {
    $SourceArguments = @("--source", $Source)
    $SourceText = " --source `"$Source`""
}

& $Choco upgrade $Package -y --no-progress @SourceArguments
$ExitCode = $LASTEXITCODE

if ($ExitCode -in 0, 1641, 3010) {
    # Keeps the package up to date: choco upgrade on every startup, as SYSTEM.
    # Each device waits a random time, so a whole office behind one IP doesn't hit the Chocolatey rate limit at once.
    try {
        $Action = New-ScheduledTaskAction -Execute $Choco -Argument "upgrade $Package -y --no-progress$SourceText"
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

exit $ExitCode
'@

    $DetectionScript = @'
$Package = "__PACKAGE__"
$ChocoRoot = $env:ChocolateyInstall
if (-not $ChocoRoot) { $ChocoRoot = Join-Path $env:ProgramData "chocolatey" }
if (Test-Path (Join-Path $ChocoRoot "lib\$Package\$Package.nuspec")) {
    Write-Output "$Package is installed"
    exit 0
}
exit 1
'@

    if ($ChocoName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "'$ChocoName' is not a valid Chocolatey package id" }
    if ($UpdateDelayMinMinutes -lt 0 -or $UpdateDelayMaxMinutes -lt $UpdateDelayMinMinutes) { throw "Update delay range is invalid" }
    $InstallScript = $InstallScript.Replace("__PACKAGE__", $ChocoName).Replace("__SOURCE__", $PackageSource.Replace("'", "''"))
    $InstallScript = $InstallScript.Replace("__DELAYMIN__", [string]$UpdateDelayMinMinutes).Replace("__DELAYMAX__", [string]$UpdateDelayMaxMinutes)
    $DetectionScript = $DetectionScript.Replace("__PACKAGE__", $ChocoName)

    Set-Content -Path (Join-Path $SourcePath "install.ps1") -Value $InstallScript -Encoding ASCII
    $DetectionFile = Join-Path (Split-Path $SourcePath) "detection.ps1"
    Set-Content -Path $DetectionFile -Value $DetectionScript -Encoding ASCII
    return $DetectionFile
}#Writes install.ps1 (with update task) into the package and the detection script next to it

function New-IntuneChocoWorkFolder {
    param([Parameter(Mandatory = $true)][string]$Name)

    # A per package folder under LOCALAPPDATA: no 8.3 short names like in TEMP, no leftovers from other packages
    $WorkPath = Join-Path $script:WorkRoot ("package\" + $Name)
    if (Test-Path $WorkPath) { Remove-Item -Path $WorkPath -Recurse -Force }
    $SourcePath = Join-Path $WorkPath "source"
    New-Item -Path $SourcePath -ItemType Directory -Force | Out-Null
    return $WorkPath
}

function New-IntuneChocoPackage {
    param(
        [Parameter(Mandatory = $true)][string]$WorkPath
    )
    $SourcePath = Join-Path $WorkPath "source"
    $Package = New-IntuneWin32AppPackage -SourceFolder $SourcePath -SetupFile "install.ps1" -OutputFolder $WorkPath -Force
    if ($null -eq $Package -or -not (Test-Path $Package.Path)) {
        throw "Packaging with IntuneWinAppUtil.exe failed. Make sure IntuneWin32App $($script:MinimumModuleVersion)+ is loaded; if it still fails, delete $env:TEMP\IntuneWinAppUtil.exe so a fresh copy is downloaded."
    }
    return $Package
}#Creates the .intunewin file and fails loudly instead of continuing without one

function New-IntuneWin32ChocoApplication {
    param(
        [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [String[]]$ChocoName,
        [Switch]$Required = $false,
        [ValidateSet("Available", "Required", "None")]
        [string]$Assignment = $script:Settings.Assignment,
        [ValidateSet("x64", "x86", "arm64", "x64x86", "AllWithARM64")]
        [string]$Architecture = $script:Settings.Architecture,
        [string]$PackageSource = $script:Settings.PackageSource,
        [int]$UpdateDelayMinMinutes = $script:Settings.UpdateDelayMinMinutes,
        [int]$UpdateDelayMaxMinutes = $script:Settings.UpdateDelayMaxMinutes,
        [string]$IconFile,
        [string]$IconBase64,
        [switch]$NoIconPrompt
    )

    begin {
        Assert-IntuneChocoPrerequisites
        Assert-IntuneChocoConnection
        if ($Required) { $Assignment = "Required" }
        $ChocoID = $null
    }

    process {
        if (-not $ChocoName) { $ChocoName = Get-ChocoPackageBySearch }
        if (-not $ChocoName) { Write-Warning "No software selected, repeat it"; return }

        foreach ($Name in $ChocoName) {
            try {
                Update-IntuneChocoToken

                ### Get Informations of Software
                Write-Host "Getting Infos from Chocolatey for $Name"
                $Infos = Get-ChocoInfo -ChocoName $Name
                $Name = $Infos.Name
                $AppName = $Infos.Title

                $Existing = @(Get-IntuneWin32App -DisplayName $AppName | Where-Object { $_.displayName -eq $AppName })
                if ($Existing.Count -gt 0) {
                    Write-Warning "$AppName is already deployed, please update or remove first"
                    continue
                }

                ### Chocolatey Dependency
                if ($null -eq $ChocoID) {
                    Write-Host "Checking if Chocolatey is deployed in Intune"
                    $ChocoID = get-ChocoWin32ID
                }

                if ($Infos.LicenseNote) { Write-Warning "License: $($Infos.LicenseNote)" }

                ### Icon
                Write-Host "Getting Icon"
                if ($IconBase64) {
                    $Icon = $IconBase64
                }
                else {
                    $Icon = Get-ChocoIconBase64 -ChocoName $Name -IconUrl $Infos.IconUrl -IconFile $IconFile -NoIconPrompt:$NoIconPrompt
                }

                ### Install and Detection Script, package
                Write-Host "Creating the install and detection script"
                $WorkPath = New-IntuneChocoWorkFolder -Name $Name
                $ScriptParams = @{
                    ChocoName             = $Name
                    SourcePath            = (Join-Path $WorkPath "source")
                    PackageSource         = $PackageSource
                    UpdateDelayMinMinutes = $UpdateDelayMinMinutes
                    UpdateDelayMaxMinutes = $UpdateDelayMaxMinutes
                }
                $DetectionFile = New-ChocoPackageScripts @ScriptParams
                $IntuneWinFile = New-IntuneChocoPackage -WorkPath $WorkPath

                $DetectionRule = New-IntuneWin32AppDetectionRuleScript -ScriptFile $DetectionFile
                $RequirementRule = New-IntuneWin32AppRequirementRule -Architecture $Architecture -MinimumSupportedWindowsRelease W10_1607

                ### Deploy Application
                Write-Host "Creating and Uploading $AppName as win32 App to Intune"
                $AppParams = @{
                    FilePath             = $IntuneWinFile.Path
                    DisplayName          = $AppName
                    Description          = $Infos.Description
                    Publisher            = $(if ($Infos.Authors) { $Infos.Authors } else { "-" })
                    Notes                = "$($script:AppMarker);package=$Name"
                    InstallExperience    = "system"
                    RestartBehavior      = "suppress"
                    DetectionRule        = $DetectionRule
                    RequirementRule      = $RequirementRule
                    InstallCommandLine   = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1"
                    UninstallCommandLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall"
                }
                if ($Infos.SoftwareSite) { $AppParams.InformationURL = $Infos.SoftwareSite }
                if ($Icon) { $AppParams.Icon = $Icon }

                $IntuneApp = Add-IntuneWin32App @AppParams
                if ($null -eq $IntuneApp -or -not $IntuneApp.id) { throw "Intune did not return the created app" }

                Write-Host "Adding dependency for chocolatey to the created Application"
                $Dependency = New-IntuneWin32AppDependency -ID $ChocoID -DependencyType AutoInstall
                Add-IntuneWin32AppDependency -ID $IntuneApp.id -Dependency $Dependency | Out-Null

                switch ($Assignment) {
                    "Required" {
                        Write-Host "Enable autodeployment for all users"
                        Add-IntuneWin32AppAssignmentAllUsers -ID $IntuneApp.id -Intent required -Notification showReboot | Out-Null
                    }
                    "Available" {
                        Write-Host "Making application available in companyportal for all users"
                        Add-IntuneWin32AppAssignmentAllUsers -ID $IntuneApp.id -Intent available -Notification showReboot | Out-Null
                    }
                    default { Write-Host "No assignment created, assign the app in Intune yourself" }
                }

                Write-Host "Deployment of $AppName was successful"
                $IntuneApp.id
            }
            catch {
                Write-Error "Deployment of $Name failed: $($_.Exception.Message)"
            }
        }
    }

}#Main function for deploying The Applications

function install-chocolatey {

    Assert-IntuneChocoPrerequisites
    Assert-IntuneChocoConnection
    write-host "Starting Deploy Chocolatey as win32 app to intune"

    $Icon = "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" -replace "\s", ""

    $WorkPath = New-IntuneChocoWorkFolder -Name "_chocolatey"
    $SourcePath = Join-Path $WorkPath "source"

    write-host "Creating install Script"
    $InstallScriptContent = @'
# Installs the Chocolatey package manager (runs as SYSTEM through Intune)
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    & "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$PSCommandPath"
    exit $LASTEXITCODE
}
Set-ExecutionPolicy Bypass -Scope Process -Force
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
$DownloadUrl = '__DOWNLOADURL__'
if ($DownloadUrl) { $env:chocolateyDownloadUrl = $DownloadUrl }
$Choco = Join-Path $env:ProgramData "chocolatey\bin\choco.exe"

# The community repository allows only a few chocolatey downloads per minute and IP: retry with a random wait
for ($Attempt = 1; $Attempt -le 4; $Attempt++) {
    try {
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    }
    catch {
        Write-Output "Attempt $Attempt failed: $($_.Exception.Message)"
    }
    if (Test-Path $Choco) { exit 0 }
    if ($Attempt -lt 4) { Start-Sleep -Seconds (Get-Random -Minimum 60 -Maximum 300) }
}
Write-Output "Chocolatey installation failed"
exit 1
'@
    $InstallScriptContent = $InstallScriptContent.Replace("__DOWNLOADURL__", $script:Settings.ChocolateyDownloadUrl.Replace("'", "''"))
    $UninstallScriptContent = @'
# Chocolatey is not removed automatically: all apps deployed with it depend on it
Write-Output "Chocolatey removal is not automated, remove it manually if needed"
exit 0
'@
    Set-Content -Path (Join-Path $SourcePath "install.ps1") -Value $InstallScriptContent -Encoding ASCII
    Set-Content -Path (Join-Path $SourcePath "uninstall.ps1") -Value $UninstallScriptContent -Encoding ASCII

    Write-Host "Creating Win32 APP Package File"
    $AppPackage = New-IntuneChocoPackage -WorkPath $WorkPath

    write-host "Creating Detection Rule"
    $DetectionRule = New-IntuneWin32AppDetectionRuleFile -Existence -DetectionType exists -Path "C:\ProgramData\chocolatey" -FileOrFolder "choco.exe"
    $RequirementRule = New-IntuneWin32AppRequirementRule -Architecture "AllWithARM64" -MinimumSupportedWindowsRelease W10_1607

    write-host "Starting uploading to intune"
    $APP = Add-IntuneWin32App -FilePath $AppPackage.Path -DisplayName "Chocolatey" -RequirementRule $RequirementRule -Notes $script:ChocoAppMarker -Description "Chocolatey Package Manager" -Publisher "www.linkedin.com/in/LuEd" -RestartBehavior suppress -InstallExperience system -Icon $Icon -InstallCommandLine "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1" -UninstallCommandLine "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1" -DetectionRule $DetectionRule
    if ($null -eq $APP -or -not $APP.id) { throw "Chocolatey could not be created in Intune" }

    write-host "Make application installable for everyone in the company"
    Add-IntuneWin32AppAssignmentAllUsers -ID $APP.id -Intent available -Notification hideAll | Out-Null

    write-host "chocolatey successfully deployed"
    return $APP.id

}# Deploys Chocolatey to Intune-Tenant

function get-ChocoWin32ID {

    $APP = Get-IntuneWin32App -DisplayName "Chocolatey" | Where-Object { $_.displayName -eq "Chocolatey" -and $_.notes -like "*$($script:ChocoAppMarker)*" } | Select-Object -First 1
    if ($APP) {
        write-host "chocolatey found"
        return $APP.id
    }

    # Deploy once and return the new ID directly (the old loop could deploy Chocolatey endlessly, see issue #5)
    write-host "Chocolatey not found in intune, it will be deployed now"
    return install-chocolatey

}#Returns the Intune ID of the Cocolatey App in Intune

function Get-IntuneChocoTenantApps {

    Assert-IntuneChocoPrerequisites
    Assert-IntuneChocoConnection
    Update-IntuneChocoToken

    foreach ($App in @(Get-IntuneWin32App)) {
        $Notes = [string]$App.notes
        $IsChocolatey = $Notes -like "*$($script:ChocoAppMarker)*" -and $App.displayName -eq "Chocolatey"
        if (-not $IsChocolatey -and $Notes -notlike "$($script:AppMarker)*") { continue }

        # Apps created before the package id was stored in the notes only carry "PoweredByChocolatey"
        $Package = $null
        if ($Notes -match 'package=([A-Za-z0-9._-]+)') { $Package = $Matches[1] }
        if ($IsChocolatey) { $Package = "chocolatey" }

        [pscustomobject]@{
            Id           = $App.id
            DisplayName  = $App.displayName
            Package      = $Package
            IsChocolatey = $IsChocolatey
            Created      = $App.createdDateTime
        }
    }

}#Lists the Win32 apps in the tenant that were created by this tool

function Get-IntuneChocoCatalog {

    $Catalog = Get-Content -Path $script:CatalogPath -Raw | ConvertFrom-Json
    foreach ($Entry in $Catalog) {
        [pscustomobject]@{
            Id          = $Entry.id
            Name        = $Entry.name
            Category    = $Entry.category
            LicenseNote = Get-ChocoLicenseNote $Entry.id
        }
    }

}#Returns the curated software list from catalog.json

function New-IntuneWin32ChocoApplicationInstallFromRepo {
    param(
        [switch]$autoupdate = $true,
        [switch]$autoinstall = $false
    )

    $Softwarelist = Get-IntuneChocoCatalog | Select-Object Name, @{ Name = "ChocoName"; Expression = { $_.Id } }, Category, LicenseNote

    $SelectedSoftware = Select-FromList -Items $Softwarelist -Title "Select software to deploy" -Property Name, ChocoName, Category

    foreach ($Software in $SelectedSoftware) {
        New-IntuneWin32ChocoApplication -ChocoName $Software.ChocoName -Required:$autoinstall
    }

}

# Run interactively when started as a script, only load the functions when dot-sourced
if ($MyInvocation.InvocationName -ne '.') {
    if (-not $TenantID) { $TenantID = $script:Settings.TenantID }
    if (-not $ClientID) { $ClientID = $script:Settings.ClientID }
    if (-not $TenantID) { $TenantID = Read-Host "Tenant (e.g. contoso.onmicrosoft.com)" }
    if (-not $ClientID) { $ClientID = Read-Host "Application (client) ID of your Entra ID app registration" }

    Connect-IntuneChoco -TenantID $TenantID -ClientID $ClientID

    New-IntuneWin32ChocoApplicationInstallFromRepo

    Read-Host "Done, press Enter to close"
}
