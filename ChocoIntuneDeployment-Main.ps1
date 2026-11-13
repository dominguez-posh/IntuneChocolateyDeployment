<#
    Deploys Chocolatey packages as Win32 apps to Microsoft Intune.

    Run directly (connects and opens the software list):
        .\ChocoIntuneDeployment-Main.ps1 -TenantID "contoso.onmicrosoft.com" -ClientID "<app registration id>"

    Or dot-source it to use the functions manually:
        . .\ChocoIntuneDeployment-Main.ps1
        Connect-IntuneChoco -TenantID "contoso.onmicrosoft.com" -ClientID "<app registration id>"
        New-IntuneWin32ChocoApplication -ChocoName "googlechrome"

    Graphical interface: Start.cmd (or .\Start-IntuneChocoTool.ps1 in Windows PowerShell 5.1)

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
$script:WingetMarker = "PoweredByWinget"
$script:DefaultAuthority = "https://login.microsoftonline.com"
# Delegated Graph permissions the IntuneWin32App module works with
$script:GraphScopeString = (@("DeviceManagementApps.ReadWrite.All", "DeviceManagementConfiguration.ReadWrite.All", "DeviceManagementRBAC.Read.All", "Group.Read.All" |
        ForEach-Object { "https://graph.microsoft.com/$_" }) + "offline_access", "openid", "profile") -join " "
# Added to the app registration and its consent for the install status and device views (Modules\TenantInsight.psm1).
# Sign-ins request them with Get-InsightScopeSet once the consent exists (Test-InsightReadiness shows what is missing).
$script:GraphInsightScopes = @("DeviceManagementManagedDevices.Read.All")

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
    # Package source the interface starts with: Chocolatey or Winget
    Source                = "Chocolatey"
    # App registrations of all tenants used so far, "tenant=client id;..." (signing in with an account of another
    # tenant switches to that tenant and its app registration)
    TenantClients         = ""
    # Defaults for new apps, changeable per app afterwards:
    #   Off      no automatic updates; a version released in this tool is installed right away by Intune
    #   Startup  update at every startup (random delay above)
    #   Custom   the user is offered the update and can install it at once; after GraceHours it is installed anyway
    UpdateMode            = "Startup"
    GraceHours            = 48
    # Latest = devices follow the newest package version; Pinned = new apps stay on today's version until you release one
    VersionMode           = "Latest"
    # Folder of WindowsSandboxMSIXInstaller (MSIX Sandbox Studio) for the Test button; empty = found automatically
    SandboxStudioPath     = ""
    # Schedule of new apps (when and under which conditions updates install) as compact JSON with the property names of
    # New-ChocoSchedule, e.g. {"OnlyOnMains":true,"WindowFrom":"12:00"}; empty = the built-in defaults (like before)
    UpdateSchedule        = ""
}
$script:UpdateModes = "Off", "Startup", "Custom"
# Raised whenever the device scripts change in a way devices must pick up (it is part of the policy fingerprint)
$script:DeviceScriptRevision = 5
# Longest random delay of the update tasks that is read back from the notes (one week)
$script:MaxDelayMinutes = 10080

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
    # The same apps in the winget repository
    "teamviewer.teamviewer"               = "The free TeamViewer version is for private use only. Business use requires a TeamViewer license."
    "teamviewer.teamviewer.host"          = "The free TeamViewer version is for private use only. Business use requires a TeamViewer license."
    "teamviewer.teamviewer.quicksupport"  = "The free TeamViewer version is for private use only. Business use requires a TeamViewer license."
    "anydesk.anydesk"                     = "The free AnyDesk version is for private use only. Business use requires an AnyDesk license."
    "adobe.acrobat.reader.64-bit"         = "Distributing Acrobat Reader inside an organization requires a (free) Adobe distribution agreement."
    "adobe.acrobat.reader.32-bit"         = "Distributing Acrobat Reader inside an organization requires a (free) Adobe distribution agreement."
    "sublimehq.sublimetext.4"             = "Sublime Text requires a paid license for continued use."
    "agilebits.1password"                 = "Requires a 1Password subscription for the users."
    "oracle.javaruntimeenvironment"       = "Oracle Java: commercial use requires a paid Oracle Java SE subscription. Use Eclipse Temurin instead."
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
        # Keys the caller does not pass keep their saved value (e.g. TenantClients, which no form shows)
        if ($null -eq $Value -and $script:Settings) { $Value = $script:Settings.$Key }
        if ($null -eq $Value) { $Value = $script:DefaultSettings[$Key] }
        if ($script:DefaultSettings[$Key] -is [int]) { $Value = [int]$Value } else { $Value = ([string]$Value).Trim() }
        $Clean[$Key] = $Value
    }
    if ($Clean.Architecture -notin "x64", "x86", "arm64", "x64x86", "AllWithARM64") { throw "Unknown architecture '$($Clean.Architecture)'" }
    if ($Clean.Assignment -notin "Available", "Required", "None") { throw "Unknown assignment '$($Clean.Assignment)'" }
    if ($Clean.Source -notin "Chocolatey", "Winget") { throw "Unknown package source '$($Clean.Source)'" }
    if ($Clean.UpdateDelayMinMinutes -lt 0 -or $Clean.UpdateDelayMaxMinutes -lt $Clean.UpdateDelayMinMinutes) { throw "Update delay range is invalid" }
    if ($Clean.MetadataFeed -notmatch '^https?://') { throw "The metadata feed must be an http(s) URL" }
    Assert-ChocoPackageSource $Clean.PackageSource
    # The current pair is remembered for later tenant switches
    $Map = ConvertFrom-TenantClients $Clean.TenantClients
    if ($Clean.TenantID -and $Clean.ClientID) { $Map[$Clean.TenantID.ToLower()] = $Clean.ClientID }
    $Clean.TenantClients = (@($Map.Keys | Sort-Object | ForEach-Object { "$_=$($Map[$_])" })) -join ";"
    if ($Clean.UpdateMode -notin $script:UpdateModes) { throw "Unknown update mode '$($Clean.UpdateMode)'" }
    if ($Clean.GraceHours -lt 1 -or $Clean.GraceHours -gt 2160) { throw "The grace period must be between 1 hour and 90 days" }
    if ($Clean.VersionMode -notin "Latest", "Pinned") { throw "Unknown version mode '$($Clean.VersionMode)'" }
    if ($Clean.UpdateSchedule) {
        try { $null = New-ChocoSchedule -Values ($Clean.UpdateSchedule | ConvertFrom-Json) } catch { throw "The default schedule is invalid: $($_.Exception.Message)" }
    }

    New-Item -Path $script:WorkRoot -ItemType Directory -Force | Out-Null
    $Clean | ConvertTo-Json | Set-Content -Path $script:SettingsPath -Encoding UTF8
    $script:Settings = [pscustomobject]$Clean
    return $script:Settings
}#Validates and saves the settings

function ConvertFrom-TenantClients([string]$Text) {
    $Map = @{}
    foreach ($Pair in ($Text -split ";")) {
        $Tenant, $Client = $Pair -split "=", 2
        if ($Tenant -and $Client) { $Map[$Tenant.Trim().ToLower()] = $Client.Trim() }
    }
    return $Map
}

function Get-IntuneChocoTenantClient {
    param([Parameter(Mandatory = $true)][string]$TenantID)
    return (ConvertFrom-TenantClients $script:Settings.TenantClients)[$TenantID.ToLower()]
}#The client id of the app registration used in that tenant before, or $null

$script:Settings = Get-IntuneChocoSettings

function Get-ChocoLicenseNote {
    param([string]$ChocoName)
    if (-not $ChocoName) { return $null }
    return $script:LicenseNotes[$ChocoName.ToLower()]
}#Returns a license warning for the package, or $null

# Update schedule of one app: when and under which conditions updates install. Name, short key in the notes, type.
# Defaults equal the behavior before schedules existed (startup + daily 10-15 o'clock, no conditions, check every 4 hours).
$script:ScheduleFields = @(
    @{ Name = "TriggerStart"; Key = "ts"; Type = "bool"; Default = $true }
    @{ Name = "TriggerWindow"; Key = "tw"; Type = "bool"; Default = $true }
    @{ Name = "WindowFrom"; Key = "wf"; Type = "time"; Default = "10:00" }
    @{ Name = "WindowTo"; Key = "wt"; Type = "time"; Default = "15:00" }
    @{ Name = "WindowDays"; Key = "wd"; Type = "days"; Default = "1234567" }
    @{ Name = "IdleMinutes"; Key = "ti"; Type = "int"; Default = 0; Allowed = 0, 1, 5, 10, 15, 30, 60 }
    @{ Name = "TriggerLogon"; Key = "tl"; Type = "bool"; Default = $false }
    @{ Name = "OnlyOnMains"; Key = "cp"; Type = "bool"; Default = $false }
    @{ Name = "NoPresentation"; Key = "cx"; Type = "bool"; Default = $false }
    @{ Name = "NoMetered"; Key = "cm"; Type = "bool"; Default = $false }
    @{ Name = "AppNotRunning"; Key = "ca"; Type = "bool"; Default = $false }
    @{ Name = "CheckIntervalHours"; Key = "ci"; Type = "int"; Default = 4; Allowed = 1, 4, 24 }
    @{ Name = "DeadlineAppMode"; Key = "da"; Type = "enum"; Default = "Install"; Map = [ordered]@{ Install = "I"; AskClose = "A"; Close = "C"; Wait = "W" } }
    @{ Name = "CloseAfterMinutes"; Key = "dc"; Type = "int"; Default = 15; Min = 1; Max = 240 }
    @{ Name = "RestartMode"; Key = "rm"; Type = "enum"; Default = "Never"; Map = [ordered]@{ Never = "N"; Ask = "A"; OutsideWindow = "O" } }
    @{ Name = "RetryMode"; Key = "rr"; Type = "enum"; Default = "Next"; Map = [ordered]@{ Next = "N"; None = "X"; Every = "E" } }
    @{ Name = "RetryCount"; Key = "rn"; Type = "int"; Default = 3; Min = 1; Max = 10 }
    @{ Name = "RetryHours"; Key = "rh"; Type = "int"; Default = 4; Min = 1; Max = 72 }
    @{ Name = "ProcessNames"; Key = "pn"; Type = "names"; Default = "" }
)
# Longest notes text this tool writes. Intune documents no limit for the notes of an app (Graph mobileApp.notes is a
# plain string); we stay well below 1000 characters on purpose.
$script:NotesMaxLength = 1000

function Get-ChocoScheduleValue($Source, [string]$Name) {
    # One value of a hashtable or object, $null when it is not there
    if ($null -eq $Source) { return $null }
    if ($Source -is [System.Collections.IDictionary]) { if ($Source.Contains($Name)) { return $Source[$Name] } else { return $null } }
    $Property = $Source.PSObject.Properties[$Name]
    if ($Property) { return $Property.Value }
    return $null
}

function New-ChocoSchedule {
    <#
        The schedule of one app (when updates install, under which conditions, what happens at the deadline, after a
        failure and when a restart is needed). Values (hashtable or object, may be partial) are laid over Base (an
        earlier schedule); without Base the built-in defaults apply. Invalid values throw.
    #>
    param($Values, $Base)
    $Result = [ordered]@{}
    foreach ($Field in $script:ScheduleFields) {
        $Value = $Field.Default
        $FromBase = Get-ChocoScheduleValue $Base $Field.Name
        if ($null -ne $FromBase) { $Value = $FromBase }
        $FromValues = Get-ChocoScheduleValue $Values $Field.Name
        if ($null -ne $FromValues) { $Value = $FromValues }
        $Name = $Field.Name
        switch ($Field.Type) {
            "bool" {
                if ($Value -is [string]) { $Value = $Value.Trim() -in "1", "true", "yes", "on" } else { $Value = [bool]$Value }
            }
            "time" {
                $Value = ([string]$Value).Trim()
                if ($Value -notmatch '^([01]\d|2[0-3]):([0-5]\d)$') { throw "$Name must be a time like 10:00" }
            }
            "days" {
                $Digits = @(([string]$Value).ToCharArray() | Where-Object { $_ -match '[1-7]' } | Sort-Object -Unique)
                if (([string]$Value) -match '[^1-7]' -or $Digits.Count -eq 0) { throw "$Name must list weekdays as digits 1 (Monday) to 7 (Sunday)" }
                $Value = -join $Digits
            }
            "int" {
                $Number = 0
                if (-not [int]::TryParse([string]$Value, [ref]$Number)) { throw "$Name must be a whole number" }
                if ($Field.Allowed -and $Number -notin $Field.Allowed) { throw "$Name must be one of $($Field.Allowed -join ', ')" }
                if ($Field.Contains("Min") -and ($Number -lt $Field.Min -or $Number -gt $Field.Max)) { throw "$Name must be between $($Field.Min) and $($Field.Max)" }
                $Value = $Number
            }
            "enum" {
                $Match = @($Field.Map.Keys | Where-Object { $_ -eq [string]$Value })
                if ($Match.Count -eq 0) { throw "$Name must be one of $($Field.Map.Keys -join ', ')" }
                $Value = [string]$Match[0]
            }
            "names" {
                $Value = (([string]$Value -split ',' | ForEach-Object { $_.Trim() -replace '\.exe$', '' } | Where-Object { $_ }) -join ',')
                if ($Value -notmatch '^[A-Za-z0-9._+ ,-]{0,150}$') { throw "$Name may only contain process names (letters, digits . _ + -), 150 characters at most" }
            }
        }
        $Result[$Name] = $Value
    }
    if ($Result.WindowFrom -eq $Result.WindowTo) { throw "The time window needs different start and end times" }
    return [pscustomobject]$Result
}#Returns a complete, validated schedule

function Get-ChocoScheduleDefaults {
    # The schedule new apps start with: the built-in defaults, changed by the UpdateSchedule setting (compact JSON)
    $Override = $null
    if ($script:Settings -and $script:Settings.PSObject.Properties["UpdateSchedule"] -and ([string]$script:Settings.UpdateSchedule).Trim()) {
        try { $Override = [string]$script:Settings.UpdateSchedule | ConvertFrom-Json } catch { Write-Warning "The UpdateSchedule setting is not valid JSON, using the built-in defaults" }
    }
    return New-ChocoSchedule -Values $Override
}#Schedule for new apps

function ConvertTo-ChocoScheduleCfg {
    param([Parameter(Mandatory = $true)]$Schedule)
    # Compact JSON with short keys and one-letter enum values, then base64url (no ; = + / in the notes)
    $Compact = [ordered]@{ v = 1 }
    foreach ($Field in $script:ScheduleFields) {
        $Value = $Schedule.($Field.Name)
        $Compact[$Field.Key] = switch ($Field.Type) {
            "bool" { [int][bool]$Value }
            "time" { ([string]$Value).Replace(":", "") }
            "enum" { $Field.Map[[string]$Value] }
            default { $Value }
        }
    }
    return ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes(($Compact | ConvertTo-Json -Compress)))
}#Schedule as the cfg value of the notes

function ConvertFrom-ChocoScheduleCfg {
    param([Parameter(Mandatory = $true)][string]$Cfg)
    $Text = $Cfg.Replace("-", "+").Replace("_", "/")
    $Text += "=" * ((4 - $Text.Length % 4) % 4)
    $Compact = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Text)) | ConvertFrom-Json
    $Values = @{}
    foreach ($Field in $script:ScheduleFields) {
        $Raw = Get-ChocoScheduleValue $Compact $Field.Key
        if ($null -eq $Raw) { continue }
        $Values[$Field.Name] = switch ($Field.Type) {
            "time" { ([string]$Raw).Insert(2, ":") }
            "enum" { $Letter = [string]$Raw; @($Field.Map.Keys | Where-Object { $Field.Map[$_] -eq $Letter })[0] }
            default { $Raw }
        }
    }
    return New-ChocoSchedule -Values $Values
}#Reads the cfg value of the notes (throws when it is damaged)

function New-ChocoAppPolicy {
    <#
        The update policy of one app: version (empty = always the latest), update mode, grace period, the schedule
        and the values baked into the device scripts. The fingerprint goes into the detection rule: when it changes in
        Intune, devices no longer detect the app as current and run install.ps1 again, which applies the policy.
        Update modes: Off (Intune installs a released version right away), Startup (= automatic per schedule),
        Custom (the user is asked, installed after GraceHours at the latest).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Package,
        [string]$Version = "",
        [ValidateSet("Off", "Startup", "Custom")][string]$UpdateMode = "Startup",
        [ValidateRange(1, 2160)][int]$GraceHours = 48,
        [string]$PackageSource = "",
        [int]$UpdateDelayMinMinutes = 5,
        [int]$UpdateDelayMaxMinutes = 60,
        # Hashtable or object with schedule values (see $script:ScheduleFields); missing ones use the built-in defaults
        $Schedule
    )
    if ($Version -eq "latest") { $Version = "" }
    if ($Version -and $Version -notmatch '^[0-9A-Za-z][0-9A-Za-z.+-]*$') { throw "'$Version' is not a valid package version" }
    Assert-ChocoPackageSource $PackageSource
    $ScheduleObject = New-ChocoSchedule -Values $Schedule
    if ($UpdateMode -eq "Startup" -and -not ($ScheduleObject.TriggerStart -or $ScheduleObject.TriggerWindow -or $ScheduleObject.IdleMinutes -gt 0 -or $ScheduleObject.TriggerLogon)) {
        throw "Automatic updates need at least one trigger (PC start, time window, idle or sign-in)"
    }
    $Cfg = ConvertTo-ChocoScheduleCfg $ScheduleObject
    # Every field of the policy is part of the fingerprint (the cfg text covers the whole schedule)
    $Text = "$($Package.ToLower())|$Version|$UpdateMode|$GraceHours|$PackageSource|$UpdateDelayMinMinutes|$UpdateDelayMaxMinutes|$Cfg|$($script:DeviceScriptRevision)"
    $Sha = [Security.Cryptography.SHA256]::Create()
    $Hash = -join ($Sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))[0..7] | ForEach-Object { $_.ToString("x2") })
    $Sha.Dispose()
    return [pscustomobject]@{
        Package               = $Package
        Version               = $Version
        UpdateMode            = $UpdateMode
        GraceHours            = $GraceHours
        PackageSource         = $PackageSource
        UpdateDelayMinMinutes = $UpdateDelayMinMinutes
        UpdateDelayMaxMinutes = $UpdateDelayMaxMinutes
        Schedule              = $ScheduleObject
        Fingerprint           = $Hash
    }
}#Returns the update policy of an app with its fingerprint

function Assert-ChocoPackageSource {
    # A feed URL must not carry a user name, password, query or fragment: they end up in the notes of the app and in
    # the device scripts, readable for everyone who can read the app in Intune (credentials belong on the device)
    param([string]$PackageSource)
    if (-not $PackageSource) { return }
    $Uri = $null
    if ([uri]::TryCreate($PackageSource, [UriKind]::Absolute, [ref]$Uri) -and -not $Uri.IsFile -and ($Uri.UserInfo -or $Uri.Query -or $Uri.Fragment)) {
        throw "The package source must not contain a user name, password or query parameters (e.g. an API key): $($Uri.Scheme)://$($Uri.Host)$($Uri.AbsolutePath)"
    }
}#Refuses feed URLs with credentials or query

function Test-HttpsUrl([string]$Url) {
    $Uri = $null
    return ([uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$Uri) -and $Uri.Scheme -eq "https" -and -not $Uri.UserInfo)
}#True for an absolute https URL without user info

function Get-DeviceScheduleText {
    # The schedule as compact JSON for a single-quoted string of a device script (ASCII only, quotes doubled)
    param([Parameter(Mandatory = $true)]$Schedule)
    return ((New-ChocoSchedule -Values $Schedule | ConvertTo-Json -Compress) -replace '[^\x20-\x7E]', '').Replace("'", "''")
}#Schedule for the device scripts

function ConvertTo-ChocoAppNotes {
    <#
        Notes of the Intune app: marker, then the readable fields of the first versions (package, version, update,
        grace, source, delay: older tool versions still read them), then ";cfg=" with the whole schedule as
        versioned compact JSON (base64url). ConvertFrom-ChocoAppNotes is the only reader.
    #>
    param([Parameter(Mandatory = $true)]$Policy, [string]$Marker = $script:AppMarker)
    $Version = if ($Policy.Version) { $Policy.Version } else { "latest" }
    $Notes = "$Marker;package=$($Policy.Package);version=$Version;update=$($Policy.UpdateMode);grace=$($Policy.GraceHours)" +
        ";source=$([uri]::EscapeDataString([string]$Policy.PackageSource));delay=$($Policy.UpdateDelayMinMinutes)-$($Policy.UpdateDelayMaxMinutes)"
    if ($Policy.Schedule) { $Notes += ";cfg=$(ConvertTo-ChocoScheduleCfg $Policy.Schedule)" }
    if ($Notes.Length -ge $script:NotesMaxLength) { throw "The notes of the app would be $($Notes.Length) characters long (limit used: $($script:NotesMaxLength)). Shorten the package source or the process names." }
    return $Notes
}#Notes of the Intune app (read back by ConvertFrom-ChocoAppNotes)

function ConvertFrom-ChocoAppNotes {
    param([string]$Notes)
    # PackageSource and the delays are $null for apps from before they were stored (callers use the current settings).
    # Schedule is always complete: without cfg (older apps) it is the built-in default, which behaves like before.
    $Result = [ordered]@{ Package = $null; Version = ""; UpdateMode = "Startup"; GraceHours = 48; HasPolicy = $false
        PackageSource = $null; UpdateDelayMinMinutes = $null; UpdateDelayMaxMinutes = $null; Schedule = $null; HasSchedule = $false }
    if ($Notes -match 'package=([A-Za-z0-9._+-]+)') { $Result.Package = $Matches[1] }
    if ($Notes -match 'version=([0-9A-Za-z.+-]+)' -and $Matches[1] -ne "latest") { $Result.Version = $Matches[1] }
    if ($Notes -match 'update=(Off|Startup|Custom)') { $Result.UpdateMode = $Matches[1]; $Result.HasPolicy = $true }
    # Numbers with TryParse and clamped to the valid ranges: crafted notes (grace=99999999999) must not break the app list
    $Number = 0
    if ($Notes -match 'grace=(\d+)' -and [int]::TryParse($Matches[1], [ref]$Number)) { $Result.GraceHours = [Math]::Min(2160, [Math]::Max(1, $Number)) }
    if ($Notes -match 'source=([^;]*)') { try { $Result.PackageSource = [uri]::UnescapeDataString($Matches[1]) } catch { } }
    if ($Notes -match 'delay=(\d+)-(\d+)') {
        $Min = 0; $Max = 0
        if ([int]::TryParse($Matches[1], [ref]$Min) -and [int]::TryParse($Matches[2], [ref]$Max)) {
            $Min = [Math]::Min($script:MaxDelayMinutes, $Min)
            $Result.UpdateDelayMinMinutes = $Min
            $Result.UpdateDelayMaxMinutes = [Math]::Min($script:MaxDelayMinutes, [Math]::Max($Min, $Max))
        }
    }
    if ($Notes -match '(?:^|;)cfg=([A-Za-z0-9_-]+)') {
        try { $Result.Schedule = ConvertFrom-ChocoScheduleCfg $Matches[1]; $Result.HasSchedule = $true }
        catch { Write-Warning "The schedule in the notes could not be read, using the defaults: $($_.Exception.Message)" }
    }
    if (-not $Result.Schedule) { $Result.Schedule = New-ChocoSchedule }
    # Apps from before the update policy keep their behavior: latest version, update at startup
    return [pscustomobject]$Result
}#Reads package, update policy and schedule from the notes of an Intune app

function Install-IntunechocoComponents {
    # IntuneWin32App 1.5.0 or newer is required (older versions break packaging, see issue #5, and dependencies, see issue #3)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # Windows PowerShell asks for the NuGet provider on first use; in the GUI nobody could answer that question
    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue | Where-Object Version -ge "2.8.5.201")) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
    }
    Install-Module IntuneWin32App -MinimumVersion $script:MinimumModuleVersion -Scope CurrentUser -Force -AllowClobber
    Remove-Module IntuneWin32App -ErrorAction SilentlyContinue
    Import-Module IntuneWin32App -MinimumVersion $script:MinimumModuleVersion -Force
    # winget packages: Microsoft's winget module for the package infos and the search
    if (-not (Get-Module -ListAvailable Microsoft.WinGet.Client)) {
        Install-Module Microsoft.WinGet.Client -Scope CurrentUser -Force -AllowClobber
        Write-Host "Microsoft.WinGet.Client $((Get-Module -ListAvailable Microsoft.WinGet.Client | Sort-Object Version -Descending | Select-Object -First 1).Version) is installed."
    }
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

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

function Invoke-IntuneChocoTokenRequest {
    param(
        [Parameter(Mandatory = $true)][string]$TenantID,
        [Parameter(Mandatory = $true)][string]$ClientID,
        [Parameter(Mandatory = $true)][hashtable]$Body,
        [string]$Authority = $script:DefaultAuthority
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $Body.client_id = $ClientID
    if (-not $Body.scope) { $Body.scope = $script:GraphScopeString }
    try {
        return Invoke-RestMethod -Method Post -Uri "$($Authority.TrimEnd('/'))/$TenantID/oauth2/v2.0/token" -Body $Body -ContentType "application/x-www-form-urlencoded" -TimeoutSec 30 -ErrorAction Stop
    }
    catch {
        $Detail = try { ($_.ErrorDetails.Message | ConvertFrom-Json).error_description } catch { $null }
        throw "Token request failed: $(if ($Detail) { ($Detail -split "`r?`n")[0] } else { $_.Exception.Message })"
    }
}#Redeems an authorization code or a refresh token at the tenant's token endpoint

function Connect-IntuneChoco {
    param(
        [Parameter(Mandatory = $true)][string]$TenantID,
        [Parameter(Mandatory = $true)][string]$ClientID,
        # How long to wait for the sign-in in the browser
        [int]$TimeoutSeconds = 300,
        # Other clouds, e.g. https://login.microsoftonline.us
        [string]$Authority = $script:DefaultAuthority,
        # Gets the sign-in URL instead of the default browser
        [scriptblock]$UrlHandler,
        # Asked while waiting; returning $true cancels the sign-in (used by the GUI)
        [scriptblock]$ShouldCancel
    )
    Assert-IntuneChocoPrerequisites
    $Params = @{ TenantID = $TenantID; ClientID = $ClientID; TimeoutSeconds = $TimeoutSeconds; Authority = $Authority; UrlHandler = $UrlHandler; ShouldCancel = $ShouldCancel }
    $Token = Invoke-IntuneChocoPkceSignIn @Params
    Set-IntuneChocoToken -TokenResponse $Token -TenantID $TenantID -ClientID $ClientID -Authority $Authority
    $script:Settings.TenantID = $TenantID
    $script:Settings.ClientID = $ClientID
    $Identity = Get-IntuneChocoIdentity
    Write-Host "Connected to Intune tenant $TenantID$(if ($Identity.Account) { " as $($Identity.Account)" })"
}#Connects to the Intune Graph API with an Entra ID app registration (sign-in in the browser)

function Invoke-IntuneChocoPkceSignIn {
    # (Modules\Keevault.psm1 has its own Invoke-IntuneChocoBrowserSignIn for the embedded WebView2 sign-in)
    param(
        [Parameter(Mandatory = $true)][string]$TenantID,
        [Parameter(Mandatory = $true)][string]$ClientID,
        [string]$Scope = $script:GraphScopeString,
        [int]$TimeoutSeconds = 300,
        [string]$Authority = $script:DefaultAuthority,
        [scriptblock]$UrlHandler,
        [scriptblock]$ShouldCancel,
        [string]$Prompt = "select_account"
    )
    # Authorization code flow with PKCE in the browser, answer on a loopback port. Done here and not with
    # Connect-MSIntuneGraph -Interactive, which waits forever when the browser window is closed.
    $Random = [Security.Cryptography.RandomNumberGenerator]::Create()
    $Bytes = New-Object byte[] 32
    $Random.GetBytes($Bytes); $Verifier = ConvertTo-Base64Url $Bytes
    $Random.GetBytes($Bytes); $State = ConvertTo-Base64Url $Bytes
    $Challenge = ConvertTo-Base64Url ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($Verifier)))

    $Probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $Probe.Start(); $Port = $Probe.LocalEndpoint.Port; $Probe.Stop()
    $RedirectUri = "http://localhost:$Port"
    $Listener = New-Object System.Net.HttpListener
    $Listener.Prefixes.Add("$RedirectUri/")
    $Listener.Start()
    try {
        $Query = [ordered]@{
            client_id             = $ClientID
            response_type         = "code"
            redirect_uri          = $RedirectUri
            response_mode         = "query"
            scope                 = $Scope
            state                 = $State
            code_challenge        = $Challenge
            code_challenge_method = "S256"
            prompt                = $Prompt
        }
        $Url = "$($Authority.TrimEnd('/'))/$TenantID/oauth2/v2.0/authorize?" + (($Query.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, [uri]::EscapeDataString($_.Value) }) -join "&")
        Write-Host "Waiting for the Microsoft sign-in in your browser (up to $TimeoutSeconds seconds)"
        if ($UrlHandler) { & $UrlHandler $Url } else { Start-Process $Url }

        $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $Answer = $null
        $Pending = $null
        $Linger = $null   # after the answer the port stays open a moment: the browser may still fetch the page again
        while ($true) {
            if (-not $Pending) { $Pending = $Listener.GetContextAsync() }
            if ($Answer) {
                if (-not $Pending.Wait([Math]::Max(0, [int]($Linger - (Get-Date)).TotalMilliseconds))) { break }
            }
            else {
                while (-not $Pending.Wait(250)) {
                    if ($ShouldCancel -and (& $ShouldCancel)) { throw "Sign-in cancelled." }
                    if ((Get-Date) -gt $Deadline) { throw "No sign-in within $TimeoutSeconds seconds. Sign in again and complete the sign-in in the browser." }
                }
            }
            $Context = $Pending.Result
            $Pending = $null
            $Request = $Context.Request.QueryString
            $Done = [bool]($Request["code"] -or $Request["error"])
            $Failed = if ($Answer) { [bool]$Answer["error"] } else { [bool]$Request["error"] }
            $Page = if (-not $Done) { "" } elseif ($Failed) { "<h2>Sign-in failed</h2><p>Details are shown in PackTune. You can close this window.</p>" }
                    else { "<h2>Sign-in complete</h2><p>You can close this window and return to PackTune.</p>" }
            $Html = [Text.Encoding]::UTF8.GetBytes("<html><body style='font-family:Segoe UI,sans-serif;margin:48px;color:#0F172A'>$Page</body></html>")
            try {
                $Context.Response.StatusCode = if ($Done) { 200 } else { 404 }
                $Context.Response.ContentType = "text/html; charset=utf-8"
                $Context.Response.KeepAlive = $false
                $Context.Response.ContentLength64 = $Html.Length
                $Context.Response.OutputStream.Write($Html, 0, $Html.Length)
                $Context.Response.OutputStream.Close()
                $Context.Response.Close()
            }
            catch { }   # the browser went away; the answer counts anyway
            if ($Done -and -not $Answer) { $Answer = $Request; $Linger = (Get-Date).AddSeconds(3) }   # anything else (e.g. a favicon) is ignored
        }
    }
    finally {
        $Listener.Stop()
        $Listener.Close()
    }

    if ($Answer["error"]) { throw "Sign-in failed: $(($Answer['error_description'] -split "`r?`n")[0])" }
    if ($Answer["state"] -ne $State) { throw "Sign-in failed: the answer does not belong to this sign-in." }
    return Invoke-IntuneChocoTokenRequest -TenantID $TenantID -ClientID $ClientID -Authority $Authority -Body @{
        grant_type    = "authorization_code"
        code          = $Answer["code"]
        redirect_uri  = $RedirectUri
        code_verifier = $Verifier
        scope         = $Scope
    }
}#Browser sign-in (authorization code with PKCE), returns the token response

function Get-IntuneChocoTokenClaims {
    param([string]$AccessToken)
    $Payload = $AccessToken.Split(".")[1].Replace("-", "+").Replace("_", "/")
    $Payload = $Payload.PadRight($Payload.Length + (4 - $Payload.Length % 4) % 4, "=")
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Payload)) | ConvertFrom-Json
}

function New-IntuneChocoAppRegistration {
    param(
        # Empty: the tenant of the account that signs in
        [string]$TenantID,
        [string]$DisplayName = "PackTune",
        # Earlier versions named the registration like this; it is recognized (owner check unchanged) and renamed
        [string[]]$FormerNames = @("Intune Chocolatey Deployment"),
        [string]$Authority = $script:DefaultAuthority,
        [scriptblock]$UrlHandler,
        [scriptblock]$ShouldCancel,
        # Graph endpoint (tests point it to a stand-in)
        [string]$GraphUrl = "https://graph.microsoft.com"
    )
    # Signs in once with Microsoft's own "Microsoft Graph Command Line Tools" app (the one Connect-MgGraph uses) to
    # create the app registration this tool signs in with, and grants the admin consent for it. Needs an account that
    # may create apps and grant consent (Global Administrator, or Application Administrator plus Privileged Role
    # Administrator); the browser asks to consent to the setup permissions first.
    $SetupClient = "14d82eec-204b-4c2f-b7e8-296a70dab67e"
    $Graph = $GraphUrl.TrimEnd("/")
    $SignInTenant = if ($TenantID) { $TenantID } else { "organizations" }
    $SetupScopes = (@("Application.ReadWrite.All", "DelegatedPermissionGrant.ReadWrite.All", "User.Read") | ForEach-Object { "https://graph.microsoft.com/$_" }) -join " "
    Write-Host "Setup: sign in with an administrator account in your browser (creates the app registration and grants the consent)"
    $Token = Invoke-IntuneChocoPkceSignIn -TenantID $SignInTenant -ClientID $SetupClient -Scope $SetupScopes -Authority $Authority -UrlHandler $UrlHandler -ShouldCancel $ShouldCancel
    $Claims = Get-IntuneChocoTokenClaims $Token.access_token
    $Headers = @{ Authorization = "Bearer $($Token.access_token)"; "Content-Type" = "application/json" }
    $Call = {
        param([string]$Method, [string]$Path, $Body)
        $Request = @{ Method = $Method; Uri = "$Graph$Path"; Headers = $Headers; TimeoutSec = 60; ErrorAction = "Stop" }
        if ($null -ne $Body) { $Request.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 8 -Compress)) }
        try { Invoke-RestMethod @Request }
        catch {
            $Detail = try { ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch { $null }
            throw "Graph $Method $Path failed: $(if ($Detail) { $Detail } else { $_.Exception.Message })"
        }
    }

    # The tenant: its initial domain, as in the settings field
    $Tenant = [string]$Claims.tid
    try {
        $Org = (& $Call GET "/v1.0/organization?`$select=verifiedDomains" $null).value | Select-Object -First 1
        $Initial = $Org.verifiedDomains | Where-Object isInitial | Select-Object -First 1
        if ($Initial.name) { $Tenant = [string]$Initial.name }
    }
    catch { Write-Warning "The tenant domain could not be read, the tenant id is used: $($_.Exception.Message)" }

    $GraphApp = "00000003-0000-0000-c000-000000000000"
    $GraphSp = (& $Call GET "/v1.0/servicePrincipals?`$filter=appId eq '$GraphApp'&`$select=id,oauth2PermissionScopes" $null).value | Select-Object -First 1
    if (-not $GraphSp) { throw "Microsoft Graph was not found in the tenant." }
    $ScopeNames = @($script:GraphScopeString -split " " | Where-Object { $_ -like "https://graph.microsoft.com/*" } | ForEach-Object { $_ -replace '^https://graph\.microsoft\.com/', '' })
    $ScopeNames += $script:GraphInsightScopes
    $Access = foreach ($Name in $ScopeNames) {
        $Scope = $GraphSp.oauth2PermissionScopes | Where-Object value -eq $Name | Select-Object -First 1
        if (-not $Scope) { throw "The Graph permission $Name was not found." }
        @{ id = $Scope.id; type = "Scope" }
    }

    # An app registration of an earlier setup is reused only when the signed-in account is its only owner (the
    # setup creates it as the signed-in admin, who becomes its owner). The name alone proves nothing: any user may
    # register an app with this name, and it would get the admin consent below. The tag only marks registrations of
    # this tool; it is not trusted, an owner can set any tag.
    $Tag = "IntuneChocoDeployment"
    $Me = [string]$Claims.oid
    $Names = @($DisplayName) + @($FormerNames | Where-Object { $_ -and $_ -ne $DisplayName })
    $Filter = [uri]::EscapeDataString((@($Names | ForEach-Object { "displayName eq '$($_.Replace("'", "''"))'" }) -join " or "))
    $App = $null
    foreach ($Candidate in @((& $Call GET "/v1.0/applications?`$filter=$Filter&`$select=id,appId,publicClient,tags" $null).value)) {
        if (-not $Candidate -or $Candidate.publicClient.redirectUris -notcontains "http://localhost") { continue }
        $Owners = @((& $Call GET "/v1.0/applications/$($Candidate.id)/owners?`$select=id" $null).value | ForEach-Object { [string]$_.id })
        if ($Me -and $Owners.Count -gt 0 -and @($Owners | Where-Object { $_ -ne $Me }).Count -eq 0) { $App = $Candidate; break }
        Write-Warning "The app registration '$DisplayName' ($($Candidate.appId)) is not reused: you are not its only owner. A new one is created."
    }
    # Authorization code with PKCE on the loopback redirect (http://localhost) works as a public client through the
    # redirect URI alone; the fallback (device code, password flows) is not needed and stays off
    $Definition = @{
        isFallbackPublicClient = $false
        publicClient           = @{ redirectUris = @("http://localhost") }
        requiredResourceAccess = @(@{ resourceAppId = $GraphApp; resourceAccess = @($Access) })
        tags                   = @($Tag)
    }
    if ($App) {
        Write-Host "App registration '$DisplayName' exists already ($($App.appId)), its permissions are updated"
        $Definition.displayName = $DisplayName
        & $Call PATCH "/v1.0/applications/$($App.id)" $Definition | Out-Null
    }
    else {
        $Definition.displayName = $DisplayName
        $Definition.signInAudience = "AzureADMyOrg"
        $App = & $Call POST "/v1.0/applications" $Definition
        Write-Host "App registration '$DisplayName' created ($($App.appId))"
    }

    # Enterprise app (service principal); right after creating the app registration Graph may not know it yet
    $Sp = $null
    for ($Attempt = 1; -not $Sp; $Attempt++) {
        $Sp = (& $Call GET "/v1.0/servicePrincipals?`$filter=appId eq '$($App.appId)'&`$select=id" $null).value | Select-Object -First 1
        if ($Sp) { break }
        try { $Sp = & $Call POST "/v1.0/servicePrincipals" @{ appId = $App.appId } }
        catch { if ($Attempt -ge 6) { throw }; Start-Sleep -Seconds (5 * $Attempt) }
    }

    # Admin consent for the whole organization
    $ScopeText = $ScopeNames -join " "
    $Grant = (& $Call GET "/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$($Sp.id)' and consentType eq 'AllPrincipals' and resourceId eq '$($GraphSp.id)'" $null).value | Select-Object -First 1
    if ($Grant) { & $Call PATCH "/v1.0/oauth2PermissionGrants/$($Grant.id)" @{ scope = $ScopeText } | Out-Null }
    else { & $Call POST "/v1.0/oauth2PermissionGrants" @{ clientId = $Sp.id; consentType = "AllPrincipals"; resourceId = $GraphSp.id; scope = $ScopeText } | Out-Null }
    Write-Host "Admin consent granted: $ScopeText"

    $script:Settings.TenantID = $Tenant
    $script:Settings.ClientID = [string]$App.appId
    return [pscustomobject]@{ TenantID = $Tenant; ClientID = [string]$App.appId; Account = [string]$(if ($Claims.upn) { $Claims.upn } else { $Claims.preferred_username }) }
}#Creates (or updates) the Entra ID app registration of this tool with admin consent, returns tenant and client id

function Invoke-IntuneModule {
    param([Parameter(Mandatory = $true)][scriptblock]$Script)

    # Every call into the IntuneWin32App module goes through here, for two reasons:
    # 1. The module checks the token expiry by writing the date as text in the current culture and reading it back
    #    as en-US. With a German date format 05.11. becomes May 11th, the fresh token counts as expired and the
    #    call is given up (on days after the 12th the check throws). The invariant culture avoids that.
    # 2. The module leaves its functions with "break" when something is wrong with the sign-in. Without a loop
    #    around the call that silently ends the caller as well: a deployment would stop without any error.
    $Thread = [System.Threading.Thread]::CurrentThread
    $Culture = $Thread.CurrentCulture
    $Completed = $false
    try {
        $Thread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
        do { & $Script; $Completed = $true } while ($false)
    }
    finally { $Thread.CurrentCulture = $Culture }
    if (-not $Completed) {
        throw "The IntuneWin32App module gave up without a result (see the warning above). Usually the sign-in has expired or lacks a permission: sign in again."
    }
}#Runs a call into the IntuneWin32App module safely

function Assert-IntuneChocoConnection {
    # The module functions call "break" when no token exists, which would silently stop the whole script
    if ($null -eq $Global:AccessToken) {
        throw "Not connected to Intune. Run Connect-IntuneChoco -TenantID <tenant> -ClientID <app id> first."
    }
}

function Update-IntuneChocoToken {
    Assert-IntuneChocoConnection
    $Current = $Global:AccessToken
    if (-not $Current.ExpiresOn -or ([datetime]$Current.ExpiresOn).ToUniversalTime() -ge (Get-Date).ToUniversalTime().AddMinutes(10)) { return }

    # Renewed here with the refresh token. Connect-MSIntuneGraph -Refresh would open an interactive sign-in when
    # the renewal fails, which must not happen in the middle of a background deployment.
    $ClientID = if ($Current.ClientID) { $Current.ClientID } else { $script:Settings.ClientID }
    if (-not $Current.RefreshToken -or -not $ClientID) {
        Write-Warning "The Intune sign-in expires soon and cannot be renewed silently. Sign in again if the next step fails."
        return
    }
    try {
        $Authority = if ($Current.Authority) { $Current.Authority } else { $script:DefaultAuthority }
        $Token = Invoke-IntuneChocoTokenRequest -TenantID $Global:AccessTokenTenantID -ClientID $ClientID -Authority $Authority -Body @{
            grant_type    = "refresh_token"
            refresh_token = $Current.RefreshToken
        }
        if (-not $Token.refresh_token) { $Token | Add-Member -MemberType NoteProperty -Name "refresh_token" -Value $Current.RefreshToken -Force }
        Set-IntuneChocoToken -TokenResponse $Token -TenantID $Global:AccessTokenTenantID -ClientID $ClientID -Authority $Authority
        Write-Host "Intune sign-in renewed"
    }
    catch { Write-Warning "The Intune sign-in could not be renewed ($($_.Exception.Message)). Sign in again if the next step fails." }
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

function Set-IntuneChocoToken {
    param(
        [Parameter(Mandatory = $true)]$TokenResponse,
        [Parameter(Mandatory = $true)][string]$TenantID,
        # Remembered on the token for the silent renewal (Update-IntuneChocoToken), also in other runspaces
        [string]$ClientID,
        [string]$Authority = $script:DefaultAuthority
    )
    # Same shape as the module's own New-DelegatedAccessToken, which the module functions expect
    if (-not $TokenResponse.access_token) { throw "The token response contains no access token" }
    $TokenResponse | Add-Member -MemberType NoteProperty -Name "ClientID" -Value $ClientID -Force
    $TokenResponse | Add-Member -MemberType NoteProperty -Name "client_id" -Value $ClientID -Force   # read by the module's own renewal
    $TokenResponse | Add-Member -MemberType NoteProperty -Name "Authority" -Value $Authority -Force
    $TokenResponse | Add-Member -MemberType NoteProperty -Name "ExpiresOn" -Value ((Get-Date).AddSeconds([int]$TokenResponse.expires_in).ToUniversalTime()) -Force
    $TokenResponse | Add-Member -MemberType NoteProperty -Name "Scopes" -Value @([string]$TokenResponse.scope -split " " | Where-Object { $_ }) -Force
    $TokenResponse | Add-Member -MemberType NoteProperty -Name "AccessToken" -Value $TokenResponse.access_token -Force
    if ($TokenResponse.refresh_token) { $TokenResponse | Add-Member -MemberType NoteProperty -Name "RefreshToken" -Value $TokenResponse.refresh_token -Force }
    $Global:AccessToken = $TokenResponse
    $Global:AuthenticationHeader = @{
        "Content-Type"  = "application/json"
        "Authorization" = "Bearer $($TokenResponse.access_token)"
        "ExpiresOn"     = $TokenResponse.ExpiresOn
    }
    $Global:AccessTokenTenantID = $TenantID
}#Takes a token from another sign-in (e.g. the Keevault sign-in of the GUI) into the IntuneWin32App module

function Get-IntuneChocoIdentity {
    # Name, account and tenant from the access token (display only, Graph checks the signature)
    if ($null -eq $Global:AccessToken) { return $null }
    try {
        $Claims = Get-IntuneChocoTokenClaims ([string]$Global:AccessToken.access_token)
        $Account = if ($Claims.upn) { $Claims.upn } elseif ($Claims.preferred_username) { $Claims.preferred_username } else { $Claims.unique_name }
        return [pscustomobject]@{ Name = $Claims.name; Account = $Account; TenantId = $Claims.tid; ExpiresOn = $Global:AccessToken.ExpiresOn }
    }
    catch { return [pscustomobject]@{ Name = $null; Account = $null; TenantId = $Global:AccessTokenTenantID; ExpiresOn = $Global:AccessToken.ExpiresOn } }
}#Who is signed in

function Get-FeedText {
    param($Node, [string]$Name)
    # OData writes empty values as <d:Title m:null="true"/>, which PowerShell returns as an element, not as text
    $Value = $Node.$Name
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Xml.XmlElement]) {
        if ($Value.GetAttribute("null", "http://schemas.microsoft.com/ado/2007/08/dataservices/metadata") -eq "true") { return $null }
        return $Value.InnerText
    }
    return [string]$Value
}

function Invoke-ChocoFeed {
    param([Parameter(Mandatory = $true)][string]$Query)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $Uri = if ($Query -match '^https?://') { $Query } else { $script:Settings.MetadataFeed.TrimEnd("/") + "/" + $Query }
    $Response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
    $Xml = [xml]$Response.Content
    foreach ($Entry in @($Xml.feed.entry)) {
        if ($null -eq $Entry) { continue }
        $Properties = $Entry.properties
        $Id = [string]$Entry.title.InnerText
        [pscustomobject]@{
            Name            = $Id
            Title           = Get-FeedText $Properties "Title"
            Version         = Get-FeedText $Properties "Version"
            Summary         = Get-FeedText $Properties "Summary"
            Description     = Get-FeedText $Properties "Description"
            Authors         = (@($Entry.author | ForEach-Object { [string]$_.name } | Where-Object { $_ }) -join ", ")
            SoftwareSite    = Get-FeedText $Properties "ProjectUrl"
            SoftwareLicense = Get-FeedText $Properties "LicenseUrl"
            IconUrl         = Get-FeedText $Properties "IconUrl"
            Downloads       = Get-FeedText $Properties "DownloadCount"
            IsLatest        = (Get-FeedText $Properties "IsLatestVersion") -eq "true"
            LicenseNote     = Get-ChocoLicenseNote $Id
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

function Get-ChocoAppName {
    param([Parameter(Mandatory = $true)]$Info)
    # The curated name from catalog.json, otherwise the feed title without the "(Install)" / "(Portable)" suffix
    # that Chocolatey puts on its .install and .portable packages
    $Entry = @(Get-IntuneChocoCatalog | Where-Object { $_.Id -eq $Info.Name }) | Select-Object -First 1
    if ($Entry -and $Entry.Name) { return $Entry.Name }
    $Title = ([string]$Info.Title) -replace '\s*\((Install|Portable)\)\s*$', ''
    if ([string]::IsNullOrWhiteSpace($Title)) { return $Info.Name }
    return $Title.Trim()
}#Display name of the app in Intune and the Company Portal

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
        # Headless Edge sometimes keeps running after writing the screenshot: wait for the file, not for the process.
        # Two headless instances at the same time (icon previews next to a deployment) often hang, so only one
        # renders at a time, across runspaces and processes; a hang now and then is covered by a second start.
        $Mutex = New-Object System.Threading.Mutex($false, "Local\IntuneChocoEdgeRender")
        $Owned = $false
        try { $Owned = $Mutex.WaitOne([TimeSpan]::FromMinutes(3)) } catch [System.Threading.AbandonedMutexException] { $Owned = $true }
        if (-not $Owned) { $Mutex.Dispose(); throw "Another icon conversion with Edge did not finish within 3 minutes" }
        try {
        for ($Attempt = 1; $Attempt -le 2; $Attempt++) {
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
                Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($EdgeProfile, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            if ((Test-Path $Png) -and (Get-Item $Png).Length -gt 0) { break }
            if ($Attempt -eq 1) { Write-Verbose "Edge did not render the SVG icon, trying once more"; Start-Sleep -Seconds 2 }
        }
        }
        finally { $Mutex.ReleaseMutex(); $Mutex.Dispose() }
        if (-not (Test-Path $Png) -or (Get-Item $Png).Length -eq 0) { throw "Edge did not render the SVG icon (two attempts of 30 seconds)" }
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
        [switch]$NoIconPrompt,
        # Do not look the icon up on the Chocolatey feed (winget packages)
        [switch]$NoFeedLookup
    )

    $WorkPath = Join-Path $script:WorkRoot "icons\$ChocoName"
    New-Item -Path $WorkPath -ItemType Directory -Force | Out-Null

    if (-not $IconFile -and -not $IconUrl -and -not $NoFeedLookup) {
        try { $IconUrl = (Get-ChocoInfo -ChocoName $ChocoName).IconUrl } catch { Write-Warning $_ }
    }

    $Bytes = $null
    if ($IconFile) {
        $Bytes = [IO.File]::ReadAllBytes((Resolve-Path $IconFile).ProviderPath)
    }
    elseif ($IconUrl -and -not (Test-HttpsUrl $IconUrl)) {
        # The URL comes from the package metadata: only https, never file, UNC or plain http
        Write-Warning "The icon of $ChocoName is not downloaded: $IconUrl is not an https URL"
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
        Write-Warning "Package $ChocoName has no icon$(if (-not $NoFeedLookup) { ' on chocolatey.org' })"
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

function Get-DeviceScriptCommon {
    # Functions of install.ps1 and update.ps1, for Chocolatey and winget apps: the device wide lock and the protected
    # folders of the update helpers (both run as SYSTEM)
    return @'
# Every folder of this tool on the device is under %ProgramFiles%\IntuneChocoDeployment: Chocolatey\<package>,
# Winget\<id>, Winget\Runtime, Winget\Logs. Users cannot create anything in %ProgramFiles%, so no user can prepare
# this tree (with links or own folders) before SYSTEM uses it. Older versions used %ProgramData%\IntuneChocoUpdates and
# %ProgramData%\IntuneWingetDeployment; those folders are left alone (a user could have changed them).
$ToolRoot = Join-Path $(if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }) "IntuneChocoDeployment"
# SYSTEM, Administrators, TrustedInstaller
$script:AdminSids = @("S-1-5-18", "S-1-5-32-544", "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464")

# One choco or winget operation at a time on the device, for all apps of both sources. The mutex gets a security
# descriptor (SYSTEM and Administrators only, nothing for users). One that exists already and belongs to someone else
# was made by a user to block or steer the installations: then nothing is installed (fail closed) and the cause logged.
$script:LockHeld = $false
$script:Lock = $null
$script:LockError = ""
function Open-DeploymentLock {
    $Name = "Global\IntuneChocoDeployment"
    $Security = New-Object System.Security.AccessControl.MutexSecurity
    foreach ($Sid in "S-1-5-18", "S-1-5-32-544") {
        $Identity = New-Object System.Security.Principal.SecurityIdentifier $Sid
        $Security.AddAccessRule((New-Object System.Security.AccessControl.MutexAccessRule($Identity, [System.Security.AccessControl.MutexRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow)))
    }
    $Created = $false
    try { $Mutex = [System.Threading.Mutex]::new($false, $Name, [ref]$Created, $Security) }
    catch { $script:LockError = "the lock $Name exists but cannot be opened, so it was not made by this tool: nothing is installed ($($_.Exception.GetType().Name))"; return $null }
    if (-not $Created) {
        $Owner = ""
        try { $Owner = $Mutex.GetAccessControl().GetOwner([System.Security.Principal.SecurityIdentifier]).Value } catch { }
        if ($Owner -notin $script:AdminSids) {
            $Mutex.Dispose()
            $script:LockError = "the lock $Name belongs to someone else (owner '$Owner'), not to SYSTEM or Administrators: nothing is installed"
            return $null
        }
    }
    return $Mutex
}
function Enter-DeploymentLock {
    if (-not $script:Lock) { $script:Lock = Open-DeploymentLock }
    if (-not $script:Lock) { Write-DeviceLog $script:LockError; Write-Host $script:LockError; return $false }
    try { $script:LockHeld = $script:Lock.WaitOne([TimeSpan]::FromMinutes(30)) }
    catch [System.Threading.AbandonedMutexException] { $script:LockHeld = $true }
    return $script:LockHeld
}
function Exit-DeploymentLock {
    if ($script:LockHeld) { $script:Lock.ReleaseMutex(); $script:LockHeld = $false }
}

function Test-ForeignItem([string]$Path) {
    # Links, and anything not owned by SYSTEM or Administrators, could have been planted by a user
    $Item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $Item) { return $false }
    if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $true }
    try { $Owner = $Item.GetAccessControl("Owner").GetOwner([System.Security.Principal.SecurityIdentifier]).Value } catch { return $true }
    return $Owner -notin $script:AdminSids
}
function Test-AdminOnlyFolder([string]$Path) {
    # A real folder (no link), owned by SYSTEM, Administrators or TrustedInstaller, in which nobody else may create,
    # change or delete anything. Only in such a folder SYSTEM writes, creates or removes files.
    $Item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $Item -or -not $Item.PSIsContainer -or ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    try {
        $Acl = $Item.GetAccessControl()
        if ($Acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -notin $script:AdminSids) { return $false }
        # write data, append, write attributes, delete child, delete, change permissions, take ownership, generic all/write
        $Write = 0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000
        foreach ($Rule in $Acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
            if ($Rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
            if ($Rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
            if (([int]$Rule.FileSystemRights -band $Write) -and $Rule.IdentityReference.Value -notin $script:AdminSids) { return $false }
        }
        return $true
    }
    catch { return $false }
}
function Assert-ToolPath([string]$Path) {
    # SYSTEM changes files and folders only inside %ProgramFiles%\IntuneChocoDeployment
    $Full = [IO.Path]::GetFullPath($Path).TrimEnd("\")
    if ($Full -ne $ToolRoot -and -not $Full.StartsWith($ToolRoot + "\", [StringComparison]::OrdinalIgnoreCase)) { throw "$Path is not a folder of this tool, nothing is changed there" }
}
function Remove-ItemSafely([string]$Path) {
    # Only inside the tool's folder (no user can create anything there); links are removed themselves, never what
    # they point to
    Assert-ToolPath $Path
    $Item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $Item) { return }
    $IsLink = [bool]($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    if (-not $IsLink) { [IO.File]::SetAttributes($Path, [IO.FileAttributes]::Normal) }
    if ($Item.PSIsContainer) {
        if (-not $IsLink) { foreach ($Child in @(Get-ChildItem -LiteralPath $Path -Force)) { Remove-ItemSafely $Child.FullName } }
        [IO.Directory]::Delete($Path, $false)
    }
    else { [IO.File]::Delete($Path) }
}
function Protect-Folder([string]$Path) {
    # Owner SYSTEM, no inherited rights: SYSTEM and Administrators full control, Users read and execute.
    # Only folders of this tool, parent first: the parent must be admin-only and the folder must not be a link or a
    # file. Nothing is removed or entered recursively; anything unexpected stops the script (fail closed).
    # SIDs, not names: the names are translated on non-English Windows.
    Assert-ToolPath $Path
    $Parent = Split-Path -Path $Path -Parent
    if (-not (Test-AdminOnlyFolder $Parent)) { throw "$Parent is not protected (link, other owner or writable for users), nothing is changed" }
    $Item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($Item -and (-not $Item.PSIsContainer -or ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint))) { throw "$Path is a link or a file, nothing is changed" }
    if (-not $Item) { [void][IO.Directory]::CreateDirectory($Path) }
    $Acl = New-Object System.Security.AccessControl.DirectorySecurity
    $Acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier "S-1-5-18"))
    $Acl.SetAccessRuleProtection($true, $false)
    foreach ($Entry in @(@("S-1-5-18", "FullControl"), @("S-1-5-32-544", "FullControl"), @("S-1-5-32-545", "ReadAndExecute"))) {
        $Sid = New-Object System.Security.Principal.SecurityIdentifier $Entry[0]
        $Acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($Sid, $Entry[1], "ContainerInherit, ObjectInherit", "None", "Allow")))
    }
    [IO.Directory]::SetAccessControl($Path, $Acl)
}
function Write-ProtectedFile([string]$Path, [string]$Text) {
    # A new file instead of writing into an existing one (which could be a hard link)
    Assert-ToolPath $Path
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $Path -Value $Text -Encoding ASCII
}

# Log: %ProgramData%\Microsoft\IntuneManagementExtension\Logs\IntuneChocoDeployment-<id>.log, so that "Collect
# diagnostics" in Intune includes it. At 1 MB it becomes IntuneChocoDeployment-<id>.1.log (one rollover).
# The scripts set $LogId (package or winget id, file name safe) and $LogTag before they log.
function Add-CappedLine([string]$Path, [string]$Line) {
    # Only into a folder no user can write to (so nobody can have prepared the file or a link there), and never into
    # a link or a file that belongs to someone else: then nothing is written (fail closed)
    try {
        if (-not (Test-AdminOnlyFolder (Split-Path -Path $Path -Parent))) { return }
        if (Test-ForeignItem $Path) { return }
        if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -gt 1MB) {
            $Old = $Path -replace '\.log$', '.1.log'
            if (Test-ForeignItem $Old) { return }
            Move-Item -LiteralPath $Path -Destination $Old -Force
        }
        Add-Content -LiteralPath $Path -Value $Line
    }
    catch { }
}
function Write-DeviceLog([string]$Text) {
    # The folder belongs to the Intune Management Extension (SYSTEM and Administrators only); it is not created here.
    # It and the folders above it are checked once per run, not trusted: links or rights for users mean no log there.
    $Dir = Join-Path $env:ProgramData "Microsoft\IntuneManagementExtension\Logs"
    if ($null -eq $script:DeviceLogOk) {
        $script:DeviceLogOk = $true
        foreach ($Level in (Join-Path $env:ProgramData "Microsoft"), (Join-Path $env:ProgramData "Microsoft\IntuneManagementExtension"), $Dir) {
            if (-not (Test-AdminOnlyFolder $Level)) { $script:DeviceLogOk = $false }
        }
    }
    if ($script:DeviceLogOk) { Add-CappedLine (Join-Path $Dir "IntuneChocoDeployment-$LogId.log") ("{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $LogTag, $Text) }
}

# last-result.json: the last attempt of this app, in its protected folder (%ProgramFiles%\IntuneChocoDeployment\
# Chocolatey\<package> or ...\Winget\<id>), written by install.ps1 and update.ps1, read by the status script
# (Get-InsightStatusScriptText in Modules\TenantInsight.psm1). One JSON object, plain ASCII:
#   format            1 (raised when fields change meaning)
#   package           Chocolatey package id or winget id
#   lastAttempt       time of the attempt, ISO 8601 with offset, local time
#   action            install | upgrade | uninstall | check | restart
#   status            ok | failed | skipped | pending   (skipped = a condition did not allow it now, pending = update known, not installed yet)
#   exitCode          exit code of choco, winget or the installer; 0 for ok, skipped and pending
#   cause             short text, e.g. "ok", "up to date", "waiting: on battery", "failed: exit code 1603"
#   installedVersion  installed version after the attempt, "" when unknown
#   targetVersion     version aimed at (pinned version or newest known), "" when unknown
# $ResultFile is set by the scripts once the folder is protected.
function Save-LastResult([string]$Action, [string]$Status, [int]$ExitCode, [string]$Cause, [string]$Installed = "", [string]$Target = "") {
    if (-not $ResultFile) { return }
    $Clean = { param($Text) $Short = ([string]$Text -replace '[^\x20-\x7E]', '?'); if ($Short.Length -gt 120) { $Short.Substring(0, 120) } else { $Short } }
    try {
        $Result = [ordered]@{ format = 1; package = (& $Clean $LogId); lastAttempt = (Get-Date).ToString("o"); action = $Action; status = $Status
            exitCode = $ExitCode; cause = (& $Clean $Cause); installedVersion = (& $Clean $Installed); targetVersion = (& $Clean $Target) }
        Write-ProtectedFile $ResultFile ($Result | ConvertTo-Json -Compress)
    }
    catch { }
}
'@
}#Lock, folder protection, log and last result of the device scripts

function Get-ScreenProbeScript {
    # Runs in the session of a signed-in user (started on demand by update.ps1 through the task "Probe <id> screen state"):
    # asks Windows whether the user is presenting or has a full-screen app and leaves the answer for update.ps1.
    return @'
# Writes SHQueryUserNotificationState of this session to the registry of this user,
# HKCU\Software\IntuneChocoDeployment\ScreenProbe: State (number) and Nonce (the value update.ps1 passed, so it knows
# the answer is fresh). Not a file: SYSTEM never opens a file in the profile of a user for this.
# (The exit code cannot carry the answer: the task starts this through conhost --headless, which always returns 0.)
#   2 busy (full screen), 3 Direct3D full screen, 4 presentation mode, 5 ready for notifications, 6 quiet time, 7 app
param([string]$Nonce = "")
if ($Nonce -notmatch '^[0-9a-f]{32}$') { exit 1 }
Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class NotifyState { [DllImport("shell32.dll")] public static extern int SHQueryUserNotificationState(out int state); }'
$State = 0
[void][NotifyState]::SHQueryUserNotificationState([ref]$State)
$Key = "HKCU:\Software\IntuneChocoDeployment\ScreenProbe"
if (-not (Test-Path -LiteralPath $Key)) { New-Item -Path $Key -Force | Out-Null }
Set-ItemProperty -LiteralPath $Key -Name State -Value ([int]$State) -Type DWord
Set-ItemProperty -LiteralPath $Key -Name Nonce -Value $Nonce -Type String
exit 0
'@
}#Script that reports the screen state of a user session

function Get-DeviceTaskRegistration {
    # Register-UpdateTasks of install.ps1 (Chocolatey and winget). Needs: $TaskPath, $TaskNames (9 names, see below),
    # $AppRoot, $Mode, $Sched (schedule), $DelayMin, $DelayMax.
    #   0 start   1 now   2 check   3 notify   4 window   5 idle   6 sign-in   7 retry (made by update.ps1)   8 probe
    return @'
function Register-UpdateTasks {
    $PowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $UpdateScript = Join-Path $AppRoot "update.ps1"
    $System = New-ScheduledTaskPrincipal -UserId "S-1-5-18" -LogonType ServiceAccount -RunLevel Highest
    # Each device waits a random time, so a whole office behind one IP doesn't hit the download limits at once
    $Spread = { "PT{0}M" -f (Get-Random -Minimum $DelayMin -Maximum ($DelayMax + 1)) }
    function New-UpdateSettings([bool]$Restrict, [hashtable]$Extra = @{}) {
        # Restrict: honor "only on mains power" (Task Scheduler does not start the task on battery and stops it when the
        # device goes on battery). The tasks of Custom mode are not restricted: the deadline decides there.
        $Parameters = @{ StartWhenAvailable = $true; ExecutionTimeLimit = (New-TimeSpan -Hours 2); MultipleInstances = "IgnoreNew"; RunOnlyIfNetworkAvailable = $true }
        if (-not ($Restrict -and $Sched.OnlyOnMains)) { $Parameters.AllowStartIfOnBatteries = $true; $Parameters.DontStopIfGoingOnBatteries = $true }
        foreach ($Key in $Extra.Keys) { $Parameters[$Key] = $Extra[$Key] }
        return New-ScheduledTaskSettingsSet @Parameters
    }
    function Add-UpdateTask([int]$Index, $Triggers, $Settings, [string]$Step, [string]$Why) {
        $Action = New-ScheduledTaskAction -Execute $PowerShell -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$UpdateScript`" -Mode $Step -Trigger $Why"
        Register-ScheduledTask -TaskName $TaskNames[$Index] -TaskPath $TaskPath -Action $Action -Trigger $Triggers -Principal $System -Settings $Settings -Force -ErrorAction Stop | Out-Null
    }

    if ($Mode -in "Startup", "Custom") {
        # Startup = install automatically per schedule; Custom = only check (the user prompt and the deadline decide)
        $Step = if ($Mode -eq "Custom") { "Check" } else { "Startup" }
        $Restrict = $Mode -eq "Startup"
        if ($Sched.TriggerStart) {
            $Trigger = New-ScheduledTaskTrigger -AtStartup
            $Trigger.Delay = & $Spread
            Add-UpdateTask 0 @($Trigger) (New-UpdateSettings $Restrict) $Step "Start"
        }
        if ($Sched.TriggerLogon) {
            $Trigger = New-ScheduledTaskTrigger -AtLogOn
            $Trigger.Delay = & $Spread
            Add-UpdateTask 6 @($Trigger) (New-UpdateSettings $Restrict) $Step "Logon"
        }
    }
    if ($Mode -eq "Startup" -and $Sched.TriggerWindow) {
        # Weekly at the start of the window plus a random delay up to its end; a run that starts late (device was off)
        # checks again inside update.ps1 whether the window is still open
        $Days = @($Sched.WindowDays.ToCharArray() | ForEach-Object { if ($_ -eq '7') { "Sunday" } else { [string][DayOfWeek][int][string]$_ } })
        $From = [timespan]::Parse($Sched.WindowFrom)
        $Length = ([timespan]::Parse($Sched.WindowTo) - $From).TotalMinutes
        if ($Length -le 0) { $Length += 1440 }
        $Trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Days -At ([datetime]::Today + $From) -RandomDelay (New-TimeSpan -Minutes ([Math]::Max(1, $Length - 1)))
        Add-UpdateTask 4 @($Trigger) (New-UpdateSettings $true) "Startup" "Window"
    }
    if ($Mode -eq "Startup" -and $Sched.IdleMinutes -gt 0) {
        # PowerShell 5.1 has no cmdlet for the idle trigger: create it from its CIM class. The idle time is a task setting.
        $Class = Get-CimClass -Namespace "Root/Microsoft/Windows/TaskScheduler" -ClassName "MSFT_TaskIdleTrigger"
        $Trigger = New-CimInstance -CimClass $Class -ClientOnly
        $Trigger.Enabled = $true
        $IdleSettings = New-UpdateSettings $true @{ RunOnlyIfIdle = $true; IdleDuration = (New-TimeSpan -Minutes $Sched.IdleMinutes); IdleWaitTimeout = (New-TimeSpan -Hours 2); DontStopOnIdleEnd = $true }
        Add-UpdateTask 5 @($Trigger) $IdleSettings "Startup" "Idle"
    }
    if ($Mode -eq "Custom") {
        # "Update now" from the user prompt: started on demand; signed-in users may run it (not change it)
        $NowSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
        $NowAction = New-ScheduledTaskAction -Execute $PowerShell -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$UpdateScript`" -Mode Now -Trigger Manual"
        Register-ScheduledTask -TaskName $TaskNames[1] -TaskPath $TaskPath -Action $NowAction -Principal $System -Settings $NowSettings -Force -ErrorAction Stop | Out-Null
        $Service = New-Object -ComObject Schedule.Service
        $Service.Connect()
        $Service.GetFolder($TaskPath.TrimEnd("\")).GetTask($TaskNames[1]).SetSecurityDescriptor("D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;AU)", 0)

        # Every 1, 4 or 24 hours: is there an update, is the grace period over?
        $Check = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes((Get-Random -Minimum 5 -Maximum 60)) -RepetitionInterval (New-TimeSpan -Hours $Sched.CheckIntervalHours) -RepetitionDuration (New-TimeSpan -Days 3650)
        Add-UpdateTask 2 @($Check) (New-UpdateSettings $false) "Check" "Interval"
    }
    if ($Mode -eq "Custom" -or ($Mode -eq "Startup" -and $Sched.RestartMode -eq "Ask")) {
        # The prompts (update, closing the app, restart) run in the session of every signed-in user (Users group), at
        # logon and every hour, without a console window
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
    if ($Sched.NoPresentation -and $Mode -ne "Off") {
        # On demand only: update.ps1 starts it in the session of each signed-in user to ask for the screen state
        $Users = New-ScheduledTaskPrincipal -GroupId "S-1-5-32-545" -RunLevel Limited
        $ProbeScript = Join-Path $AppRoot "probe.ps1"
        # $(Arg0) = the nonce update.ps1 passes with RunEx
        $ProbeAction = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" -Argument "--headless `"$PowerShell`" -NoProfile -ExecutionPolicy Bypass -File `"$ProbeScript`" -Nonce `$(Arg0)"
        $ProbeSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances Parallel
        Register-ScheduledTask -TaskName $TaskNames[8] -TaskPath $TaskPath -Action $ProbeAction -Principal $Users -Settings $ProbeSettings -Force -ErrorAction Stop | Out-Null
    }
}
'@
}#Task registration of install.ps1

function Get-DeviceUpdateCommon {
    # The schedule logic of update.ps1 (Chocolatey and winget). Before it the script defines $Config, $Mode, $Trigger,
    # $StateFile, $LogFile, $AppKey, $LogId; after it the source functions Invoke-Upgrade (exit code, 0/1641/3010 = success),
    # Get-PendingUpdate (Pending, Installed, Target), Get-InstalledText and Invoke-SourceMaintenance.
    return @'
$S = $Config.Schedule
$TaskId = $Config.TaskId
$LogTag = "$Mode/$Trigger"
$ResultFile = Join-Path $PSScriptRoot "last-result.json"
$RetryFile = Join-Path $PSScriptRoot "retry.json"
$RestartFile = Join-Path $PSScriptRoot "restart.json"
$AttemptFile = Join-Path $PSScriptRoot "attempt.txt"
function Write-Log([string]$Text) {
    Add-CappedLine $LogFile ("{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $LogTag, $Text)
    Write-DeviceLog $Text
}
function Read-JsonFile([string]$Path) {
    if (Test-Path -LiteralPath $Path) { try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } catch { } }
    return $null
}
function Save-Result([string]$Action, [string]$Status, [int]$Code, [string]$Cause, [string]$Target = "") {
    if (-not $Target) { $Target = [string]$Config.Version }
    Save-LastResult $Action $Status $Code $Cause ([string](Get-InstalledText)) $Target
}

# --- Conditions ---
function Test-OnBattery {
    try { return [bool](@(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop | Where-Object { $_.BatteryStatus -eq 1 }).Count) } catch { return $false }
}
function Test-Metered {
    # Windows connection cost of the internet connection: fixed or variable data plan, roaming, over the limit
    try {
        [void][Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]
        $Connection = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
        if (-not $Connection) { return $false }
        $Cost = $Connection.GetConnectionCost()
        return ([string]$Cost.NetworkCostType -in "Fixed", "Variable") -or [bool]$Cost.Roaming -or [bool]$Cost.OverDataLimit
    }
    catch { return $false }
}
function Test-ScreenBusy {
    # SHQueryUserNotificationState only answers for the session of the caller. SYSTEM has none, so the task "Probe ..."
    # (Users group, runs probe.ps1) is started in each signed-in session with a random nonce; the answer comes back in the
    # registry of that user (HKU\<sid>\Software\IntuneChocoDeployment\ScreenProbe, values State and Nonce). No file of
    # the user is opened as SYSTEM; the value is only parsed as a number and never logged. The user could give a wrong
    # answer there; that only moves the time of an update, nothing else.
    try {
        $Sessions = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | Where-Object { $_.SessionId -gt 0 } | Sort-Object SessionId -Unique)
        if ($Sessions.Count -eq 0) { return $false }
        $Service = New-Object -ComObject Schedule.Service
        $Service.Connect()
        $Task = $Service.GetFolder($Config.TaskPath.TrimEnd("\")).GetTask("Probe $TaskId screen state")
        foreach ($Explorer in $Sessions) {
            $Sid = [string](Invoke-CimMethod -InputObject $Explorer -MethodName GetOwnerSid -ErrorAction Stop).Sid
            if ($Sid -notmatch '^S-1-5-21-[0-9-]+$') { continue }
            $Key = "Registry::HKEY_USERS\$Sid\Software\IntuneChocoDeployment\ScreenProbe"
            $Nonce = [guid]::NewGuid().ToString("N")
            # 4 = TASK_RUN_USE_SESSION_ID; the nonce replaces $(Arg0) in the arguments of the task
            [void]$Task.RunEx($Nonce, 4, [int]$Explorer.SessionId, $null)
            for ($i = 0; $i -lt 15; $i++) {
                Start-Sleep -Seconds 1
                $Answer = Get-ItemProperty -LiteralPath $Key -ErrorAction SilentlyContinue
                if ($Answer -and [string]$Answer.Nonce -eq $Nonce) {
                    $State = 0
                    if ([int]::TryParse([string]$Answer.State, [ref]$State) -and $State -in 2, 3, 4, 6) { return $true }
                    break
                }
            }
        }
    }
    catch { Write-Log "screen state unknown ($($_.Exception.GetType().Name))" }
    return $false
}
function Get-IsoDay([datetime]$Date) { if ($Date.DayOfWeek -eq [DayOfWeek]::Sunday) { return 7 } else { return [int]$Date.DayOfWeek } }
function Test-InWindow([datetime]$At = (Get-Date)) {
    $From = [timespan]::Parse($S.WindowFrom)
    $To = [timespan]::Parse($S.WindowTo)
    $Time = $At.TimeOfDay
    if ($From -lt $To) { return ($Time -ge $From -and $Time -lt $To -and ([string]$S.WindowDays).Contains([string](Get-IsoDay $At))) }
    # The window crosses midnight; its weekday is the day it starts
    if ($Time -ge $From) { return ([string]$S.WindowDays).Contains([string](Get-IsoDay $At)) }
    if ($Time -lt $To) { return ([string]$S.WindowDays).Contains([string](Get-IsoDay $At.AddDays(-1))) }
    return $false
}
function Get-AppFolders {
    # Install folders of the app from its uninstall entry (best effort)
    $Name = [string]$Config.DisplayName
    $Last = ($AppKey -split '\.')[-1]
    $Roots = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    $Folders = @()
    foreach ($Entry in @(Get-ItemProperty -Path $Roots -ErrorAction SilentlyContinue)) {
        $Display = [string]$Entry.DisplayName
        if (-not $Display -or -not $Entry.InstallLocation) { continue }
        if (($Name -and $Display -like ([WildcardPattern]::Escape($Name) + "*")) -or $Display -eq $Last) {
            $Folder = ([string]$Entry.InstallLocation).Trim().Trim('"').TrimEnd("\")
            if ($Folder.Length -gt 12 -and (Test-Path -LiteralPath $Folder) -and $Folder -ne $env:ProgramFiles -and $Folder -ne ${env:ProgramFiles(x86)}) { $Folders += $Folder }
        }
    }
    return @($Folders | Select-Object -Unique)
}
function Get-RunningApp {
    # Processes of the app: the names of the policy, otherwise programs in its install folder or the tools folder of its
    # Chocolatey package. Best effort: when nothing is known, the app counts as not running.
    $Names = @()
    $Folders = @()
    if ($S.ProcessNames) { $Names = @($S.ProcessNames -split ',') }
    else {
        $Folders = @(Get-AppFolders)
        if ($ChocoRoot) {
            $Tools = Join-Path $ChocoRoot "lib\$AppKey\tools"
            if (Test-Path -LiteralPath $Tools) { $Folders += $Tools }
        }
    }
    $Found = @()
    foreach ($Process in @(Get-Process -ErrorAction SilentlyContinue)) {
        if ($Process.Id -eq $PID) { continue }
        $Path = $null
        try { $Path = $Process.Path } catch { }
        $InFolder = $false
        foreach ($Folder in $Folders) { if ($Path -and $Path.StartsWith($Folder + "\", [StringComparison]::OrdinalIgnoreCase)) { $InFolder = $true } }
        if ($InFolder -or $Process.ProcessName -in $Names) { $Found += $Process }
    }
    return $Found
}
function Stop-AppProcesses($Processes) {
    # Ask politely (close the main window), after 30 seconds end what is left
    foreach ($Process in $Processes) { try { [void]$Process.CloseMainWindow() } catch { } }
    foreach ($Process in $Processes) { try { [void]$Process.WaitForExit(30000) } catch { } }
    foreach ($Process in $Processes) { try { if (-not $Process.HasExited) { Stop-Process -Id $Process.Id -Force -ErrorAction Stop } } catch { } }
    Write-Log ("closed " + (($Processes | ForEach-Object { $_.ProcessName } | Select-Object -Unique) -join ", "))
}
function Get-Blocker([bool]$PastDeadline, [bool]$WaivePresentation) {
    # Why an update must not start now ($null = go). The deadline waives power, network and app-open conditions (the app
    # is handled by the deadline setting); presentations still count for 4 hours after the deadline.
    if (-not $PastDeadline) {
        if ($S.OnlyOnMains -and (Test-OnBattery)) { return "on battery" }
        if ($S.NoMetered -and (Test-Metered)) { return "metered network" }
    }
    if ($S.NoPresentation -and -not $WaivePresentation -and (Test-ScreenBusy)) { return "presentation or full-screen app" }
    if (-not $PastDeadline -and $S.AppNotRunning -and @(Get-RunningApp).Count -gt 0) { return "app is running" }
    return $null
}

# --- Waiting, retrying, restarting ---
function Set-RetryTask([datetime]$At, [string]$Step) {
    try {
        $PowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $Action = New-ScheduledTaskAction -Execute $PowerShell -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Mode $Step -Trigger Retry"
        $System = New-ScheduledTaskPrincipal -UserId "S-1-5-18" -LogonType ServiceAccount -RunLevel Highest
        $Parameters = @{ StartWhenAvailable = $true; ExecutionTimeLimit = (New-TimeSpan -Hours 2); MultipleInstances = "IgnoreNew"; RunOnlyIfNetworkAvailable = $true }
        if (-not ($Config.Mode -eq "Startup" -and $S.OnlyOnMains)) { $Parameters.AllowStartIfOnBatteries = $true; $Parameters.DontStopIfGoingOnBatteries = $true }
        Register-ScheduledTask -TaskName "Retry $TaskId update" -TaskPath $Config.TaskPath -Action $Action -Trigger (New-ScheduledTaskTrigger -Once -At $At) -Principal $System `
            -Settings (New-ScheduledTaskSettingsSet @Parameters) -Force -ErrorAction Stop | Out-Null
    }
    catch { Write-Log "the retry task could not be registered: $($_.Exception.Message)" }
}
function Get-RetryState {
    $State = [pscustomobject]@{ Attempts = 0; WaitSince = ""; Failed = ""; FailedAt = "" }
    $Old = Read-JsonFile $RetryFile
    if ($Old) { foreach ($Name in "Attempts", "WaitSince", "Failed", "FailedAt") { if ($null -ne $Old.$Name) { $State.$Name = $Old.$Name } } }
    # A new trigger starts a new chain of retries and waits
    if ($Trigger -ne "Retry") { $State.Attempts = 0; $State.WaitSince = "" }
    return $State
}
function Save-RetryState($State) { Write-ProtectedFile $RetryFile ($State | ConvertTo-Json -Compress) }
function Wait-ForChance([string]$Reason, [string]$Step, [int]$Minutes = 30) {
    # Next chance: the next trigger, and meanwhile a short retry (for at most a day)
    Write-Log "waiting: $Reason"
    Save-Result "upgrade" "skipped" 0 "waiting: $Reason"
    $State = Get-RetryState
    if (-not $State.WaitSince) { $State.WaitSince = (Get-Date).ToString("o") }
    if (((Get-Date) - [datetime]$State.WaitSince).TotalHours -lt 24) {
        Save-RetryState $State
        Set-RetryTask (Get-Date).AddMinutes($Minutes) $Step
    }
    else { Save-RetryState $State; Write-Log "waiting for more than a day, the next trigger tries again" }
}
function Get-FailTarget {
    try { $Info = Get-PendingUpdate; if ($Info.Target) { return [string]$Info.Target } } catch { }
    return "unknown"
}
function Register-FailureRetry([string]$Step) {
    $State = Get-RetryState
    switch ($S.RetryMode) {
        "Every" {
            if ($State.Attempts -lt $S.RetryCount) {
                $State.Attempts++
                Save-RetryState $State
                Set-RetryTask (Get-Date).AddHours($S.RetryHours) $Step
                Write-Log "retry $($State.Attempts) of $($S.RetryCount) in $($S.RetryHours) hour(s)"
            }
            else { Save-RetryState $State; Write-Log "no retries left" }
        }
        "None" {
            $State.Failed = Get-FailTarget
            $State.FailedAt = (Get-Date).ToString("o")
            Save-RetryState $State
            Write-Log "no retry (setting): not tried again for this version"
        }
        default { Save-RetryState $State; Write-Log "next chance is the next trigger" }
    }
}
function Start-NotifyTask { & schtasks.exe /run /tn "$($Config.TaskPath)Notify $TaskId update" | Out-Null }
function Invoke-RestartStep {
    $Request = Read-JsonFile $RestartFile
    if (-not $Request) { return 0 }
    if ((Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime -gt [datetime]$Request.Since) {
        Remove-Item -LiteralPath $RestartFile -Force -ErrorAction SilentlyContinue
        Write-Log "the device has restarted since"
        return 0
    }
    if ($S.RestartMode -ne "OutsideWindow") { return 0 }
    if ($S.NoPresentation -and (Test-ScreenBusy)) { Set-RetryTask (Get-Date).AddMinutes(30) "Restart"; return 0 }
    if (Test-InWindow) {
        # Not inside the time window: wait for its end
        $End = [datetime]::Today + [timespan]::Parse($S.WindowTo)
        if ($End -le (Get-Date)) { $End = $End.AddDays(1) }
        Set-RetryTask $End.AddMinutes(1) "Restart"
        Write-Log "restart waits for the end of the time window ($End)"
        return 0
    }
    & shutdown.exe /r /t 600 /c "A software update needs a restart. The device restarts in 10 minutes. Save your work." | Out-Null
    Write-Log "restart announced in 10 minutes"
    Save-Result "restart" "ok" 0 "restart in 10 minutes"
    return 0
}
function Request-Restart {
    if ($S.RestartMode -eq "Never") { Write-Log "a restart is needed, not done (restart setting: never)"; return }
    Write-ProtectedFile $RestartFile (@{ Since = (Get-Date).ToString("o"); Package = $TaskId; DisplayName = [string]$Config.DisplayName } | ConvertTo-Json -Compress)
    if ($S.RestartMode -eq "Ask") { Start-NotifyTask; Write-Log "asked the user to restart" }
    else { [void](Invoke-RestartStep) }
}

# --- The runs ---
function Invoke-Install([string]$Step) {
    Invoke-SourceMaintenance
    Write-ProtectedFile $AttemptFile (Get-Date).ToString("o")
    $Code = Invoke-Upgrade
    if ($Code -in 0, 1641, 3010) {
        Write-Log "update installed (exit code $Code)"
        $State = Get-RetryState
        $State.Attempts = 0; $State.WaitSince = ""; $State.Failed = ""; $State.FailedAt = ""
        Save-RetryState $State
        Save-Result "upgrade" "ok" 0 $(if ($Code -in 1641, 3010) { "ok, restart needed" } else { "ok" })
        if ($Code -in 1641, 3010) { Request-Restart }
        return 0
    }
    if ($Code -eq 1618) { Wait-ForChance "another installation is running" $Step; return $Code }
    Save-Result "upgrade" "failed" $Code "failed: exit code $Code"
    Register-FailureRetry $Step
    return $Code
}
function Invoke-CheckStep {
    $Info = Get-PendingUpdate
    if (-not $Info.Pending) {
        Remove-Item -Path $StateFile -Force -ErrorAction SilentlyContinue
        Save-Result "check" "ok" 0 "up to date"
        return 0
    }
    $State = Read-JsonFile $StateFile
    if (-not $State -or $State.Target -ne $Info.Target) {
        $Now = Get-Date
        $State = [pscustomobject]@{
            Package     = $TaskId
            DisplayName = $Config.DisplayName
            Installed   = [string]$Info.Installed
            Target      = [string]$Info.Target
            FirstSeen   = $Now.ToString("o")
            Deadline    = $Now.AddHours([int]$Config.GraceHours).ToString("o")
        }
        Write-ProtectedFile $StateFile ($State | ConvertTo-Json)
        Write-Log "update $($Info.Installed) -> $($Info.Target) available, installed automatically from $($State.Deadline)"
    }
    $Deadline = [datetime]$State.Deadline
    if ((Get-Date) -lt $Deadline) { Save-Result "check" "pending" 0 "update available, installed from $($Deadline.ToString('g'))" ([string]$Info.Target); return 0 }
    Write-Log "grace period is over"
    $Block = Get-Blocker $true ((Get-Date) -gt $Deadline.AddHours(4))
    if ($Block) { Wait-ForChance $Block "Check"; return 0 }
    $Open = @(Get-RunningApp)
    if ($Open.Count -gt 0) {
        switch ($S.DeadlineAppMode) {
            "Wait" { Wait-ForChance "the app is open" "Check"; return 0 }
            "Close" { Stop-AppProcesses $Open }
            "AskClose" {
                if (-not $State.CloseAt) {
                    $CloseAt = (Get-Date).AddMinutes([int]$S.CloseAfterMinutes)
                    $State | Add-Member -NotePropertyName CloseAt -NotePropertyValue $CloseAt.ToString("o") -Force
                    Write-ProtectedFile $StateFile ($State | ConvertTo-Json)
                    Start-NotifyTask
                    Set-RetryTask $CloseAt "Check"
                    Write-Log "asked the user to close the app, it is closed at $CloseAt"
                    Save-Result "check" "pending" 0 "waiting for the user to close the app" ([string]$Info.Target)
                    return 0
                }
                if ((Get-Date) -lt [datetime]$State.CloseAt) { return 0 }
                Stop-AppProcesses $Open
            }
        }
    }
    return (Invoke-Install "Check")
}
function Invoke-UpdateRun {
    Write-Log "start"
    if ($Mode -eq "Restart") { return (Invoke-RestartStep) }
    # "Update now" from the user prompt: no conditions
    if ($Mode -eq "Now") { return (Invoke-Install "Startup") }
    if ($Mode -eq "Check") { return (Invoke-CheckStep) }
    # Automatic per schedule
    if ($Trigger -eq "Window" -and -not (Test-InWindow)) { Write-Log "outside the time window, skipped"; return 0 }
    if ($Trigger -in "Idle", "Logon" -and (Test-Path -LiteralPath $AttemptFile)) {
        try { if (((Get-Date) - [datetime](Get-Content -LiteralPath $AttemptFile -Raw).Trim()).TotalHours -lt 12) { Write-Log "tried less than 12 hours ago, skipped"; return 0 } } catch { }
    }
    if ($S.RetryMode -eq "None") {
        $State = Get-RetryState
        if ($State.Failed -and $State.FailedAt -and ((Get-Date) - [datetime]$State.FailedAt).TotalDays -lt 7 -and (Get-FailTarget) -eq $State.Failed) {
            Write-Log "failed before for this version and no retry is set, skipped"
            return 0
        }
    }
    $Block = Get-Blocker $false $false
    if ($Block) { Wait-ForChance $Block "Startup"; return 0 }
    return (Invoke-Install "Startup")
}
'@
}#Schedule logic of update.ps1

function Get-UpdateNotifyScript {
    # The prompts for the signed-in user, for Chocolatey and winget apps (only the task folder differs): update prompt of
    # Custom mode, warning before the app is closed at the deadline, restart request
    param([Parameter(Mandatory = $true)][string]$TaskPath)
    $Script = @'
# Shows prompts in the session of a signed-in user (scheduled task of the Users group, no admin rights).
# Update: "Install now" starts the SYSTEM task "Update <package> now"; "Later" is respected for 4 hours, but not within
# the last hour before the update is installed anyway. Closing: after the deadline, tells when the app is closed.
# Restart: asks to restart after an update that needs it.
Add-Type -AssemblyName System.Windows.Forms
# DefaultDesktopOnly: the prompt comes to the front without a window of its own
$Options = [System.Windows.Forms.MessageBoxOptions]::DefaultDesktopOnly
$SnoozeFolder = Join-Path $env:LOCALAPPDATA "IntuneChocoUpdates"

$RestartFile = Join-Path $PSScriptRoot "restart.json"
if (Test-Path $RestartFile) {
    try {
        $Request = Get-Content -Path $RestartFile -Raw | ConvertFrom-Json
        $Booted = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime -gt [datetime]$Request.Since
        $SnoozeFile = Join-Path $SnoozeFolder "$($Request.Package).restart"
        $Snoozed = $false
        if (Test-Path $SnoozeFile) { try { $Snoozed = (Get-Date) -lt [datetime](Get-Content -Path $SnoozeFile -Raw).Trim() } catch { } }
        if (-not $Booted -and -not $Snoozed) {
            $Name = if ($Request.DisplayName) { $Request.DisplayName } else { $Request.Package }
            $Answer = [System.Windows.Forms.MessageBox]::Show("The update of $Name needs a restart of this device.`r`n`r`nRestart now? Save your work first.", "Software update: $Name", "YesNo", "Information", "Button2", $Options)
            if ($Answer -eq "Yes") { & shutdown.exe /r /t 60 /c "Restart for the update of $Name" | Out-Null }
            else {
                New-Item -Path $SnoozeFolder -ItemType Directory -Force | Out-Null
                Set-Content -Path $SnoozeFile -Value (Get-Date).AddHours(4).ToString("o")
            }
        }
    }
    catch { }
}

$StateFile = Join-Path $PSScriptRoot "state.json"
if (-not (Test-Path $StateFile)) { exit 0 }
try { $State = Get-Content -Path $StateFile -Raw | ConvertFrom-Json } catch { exit 0 }
$Deadline = [datetime]$State.Deadline
$Name = if ($State.DisplayName) { $State.DisplayName } else { $State.Package }
if ((Get-Date) -ge $Deadline) {
    if ($State.CloseAt -and (Get-Date) -lt [datetime]$State.CloseAt) {
        $WarnFile = Join-Path $SnoozeFolder "$($State.Package).closing"
        $Warned = (Test-Path $WarnFile) -and ((Get-Content -Path $WarnFile -Raw).Trim() -eq [string]$State.CloseAt)
        if (-not $Warned) {
            New-Item -Path $SnoozeFolder -ItemType Directory -Force | Out-Null
            Set-Content -Path $WarnFile -Value ([string]$State.CloseAt)
            [void][System.Windows.Forms.MessageBox]::Show("$Name is updated now and will be closed at $(([datetime]$State.CloseAt).ToString('t')).`r`n`r`nPlease save your work and close $Name.", "Software update: $Name", "OK", "Warning", "Button1", $Options)
        }
    }
    exit 0
}

$SnoozeFile = Join-Path $SnoozeFolder "$($State.Package).snooze"
if (Test-Path $SnoozeFile) {
    try { $Until = [datetime](Get-Content -Path $SnoozeFile -Raw).Trim() } catch { $Until = Get-Date }
    if ((Get-Date) -lt $Until -and $Deadline -gt (Get-Date).AddHours(1)) { exit 0 }
}

$Versions = if ($State.Installed -and $State.Target) { " ($($State.Installed) -> $($State.Target))" } else { "" }
$Text = "An update for $Name is available$Versions.`r`n`r`n" +
    "Install it now? Save your work in $Name first, it may be closed during the update.`r`n`r`n" +
    "Otherwise it is installed automatically from $($Deadline.ToString('g'))."
$Answer = [System.Windows.Forms.MessageBox]::Show($Text, "Software update: $Name", "YesNo", "Information", "Button1", $Options)
if ($Answer -eq "Yes") {
    & schtasks.exe /run /tn "__TASKPATH__Update $($State.Package) now" | Out-Null
    $Message = if ($LASTEXITCODE -eq 0) { "The update of $Name is being installed now." } else { "The update could not be started. It is installed automatically from $($Deadline.ToString('g'))." }
    [void][System.Windows.Forms.MessageBox]::Show($Message, "Software update: $Name", "OK", "Information", "Button1", $Options)
}
else {
    New-Item -Path $SnoozeFolder -ItemType Directory -Force | Out-Null
    Set-Content -Path $SnoozeFile -Value (Get-Date).AddHours(4).ToString("o")
}
'@
    return $Script.Replace("__TASKPATH__", $TaskPath)
}#Script of the prompts for the signed-in user

function New-ChocoPackageScripts {
    <#
        Writes the package content (install.ps1 plus the update helpers update.ps1 and notify.ps1) into SourcePath
        and the detection script next to it. All values of the policy are baked into the scripts.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ChocoName,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)]$Policy,
        [string]$DisplayName = ""
    )

    # Plain ASCII on purpose: Windows PowerShell reads BOM-less files as ANSI
    $InstallScript = @'
# Installs or removes a Chocolatey package and applies its update policy (runs as SYSTEM through Intune).
param(
    [string]$Package = '__PACKAGE__',
    [string]$Source = '__SOURCE__',
    [string]$Version = '__VERSION__',
    [string]$Mode = '__MODE__',
    [int]$GraceHours = __GRACE__,
    [string]$DisplayName = '__DISPLAYNAME__',
    [string]$Policy = '__POLICY__',
    [string]$ScheduleJson = '__SCHEDULE__',
    [int]$DelayMin = __DELAYMIN__,
    [int]$DelayMax = __DELAYMAX__,
    [switch]$Uninstall
)

# The Intune Management Extension starts 32-bit PowerShell; choco and many packages need the 64-bit one
# (all values are baked in as defaults, so only -Uninstall has to be passed on)
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $Arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    if ($Uninstall) { $Arguments += "-Uninstall" }
    & "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe" @Arguments
    exit $LASTEXITCODE
}

$ChocoRoot = $env:ChocolateyInstall
if (-not $ChocoRoot) { $ChocoRoot = Join-Path $env:ProgramData "chocolatey" }
$Choco = Join-Path $ChocoRoot "bin\choco.exe"
if (-not (Test-Path $Choco)) { Write-Output "choco.exe not found in $ChocoRoot"; exit 1 }

$TaskPath = "\Intune-Choco-Updates\"
$TaskNames = @("Update $Package on startup", "Update $Package now", "Check $Package for updates", "Notify $Package update",
    "Update $Package in time window", "Update $Package when idle", "Update $Package at sign-in", "Retry $Package update", "Probe $Package screen state")
$LogId = $Package -replace '[^A-Za-z0-9._-]', '_'
$LogTag = if ($Uninstall) { "uninstall" } else { "install" }
$ResultFile = ""
$Sched = $ScheduleJson | ConvertFrom-Json
function Remove-UpdateTasks {
    foreach ($Name in $TaskNames) { Unregister-ScheduledTask -TaskName $Name -TaskPath $TaskPath -Confirm:$false -ErrorAction SilentlyContinue }
}
$SourceArguments = @()
if ($Source) { $SourceArguments = @("--source", $Source) }

__COMMON__
__CHOCOCOMMON__

# The helpers of this app: %ProgramFiles%\IntuneChocoDeployment\Chocolatey\<package> (see $ToolRoot). The tasks of
# older versions (same names, helpers under %ProgramData%\IntuneChocoUpdates) are replaced below; that old folder is
# not touched.
$Base = Join-Path $ToolRoot "Chocolatey"
$AppRoot = Join-Path $Base $Package

if ($Uninstall) {
    $ExitCode = 0
    if (Get-InstalledVersion) {
        if (-not (Enter-DeploymentLock)) { Write-Output "Another choco or winget installation is still running"; exit 1618 }
        # --remove-dependencies: a meta package (e.g. vlc) takes its installer package (vlc.install) with it
        & $Choco uninstall $Package -y --no-progress --remove-dependencies
        $ExitCode = $LASTEXITCODE
        Exit-DeploymentLock
    }
    # Tasks, helpers and marker only go when the software is gone; otherwise Intune reports the error and retries
    Write-DeviceLog "choco uninstall $Package exit code $ExitCode"
    if ($ExitCode -notin 0, 1605, 1614, 1641, 3010) { Write-Output "choco uninstall failed with exit code $ExitCode"; exit $ExitCode }
    Remove-UpdateTasks
    try { Remove-ItemSafely $AppRoot } catch { Write-Output "$AppRoot could not be removed: $($_.Exception.Message)" }
    if ($ExitCode -in 1641, 3010) { exit $ExitCode }
    exit 0
}

$VersionArguments = @()
if ($Version) { $VersionArguments = @("--version", $Version, "--allow-downgrade") }
$Installed = Get-InstalledVersion

# The update helpers run as SYSTEM: their folders must not be writable for users
try {
    Protect-Folder $ToolRoot
    Protect-Folder $Base
    Protect-Folder $AppRoot
}
catch { Write-Output "The folder $AppRoot could not be protected: $($_.Exception.Message)"; exit 1 }
$ResultFile = Join-Path $AppRoot "last-result.json"

# A new installation always installs. When only the policy changed (released version, update mode), the device
# follows its update mode: Off installs a released version right away (latest + Off leaves the installed version
# alone), Startup at the next startup, Custom asks the user and installs at the latest when the grace period is over.
$Upgrade = (-not $Installed) -or ($Mode -eq "Off" -and $Version -and (Compare-PackageVersion $Version $Installed) -ne 0)
if (-not (Enter-DeploymentLock)) { Write-Output "Another choco or winget installation is still running after 30 minutes"; Write-DeviceLog "another installation is still running, Intune tries again"; exit 1618 }
if (Test-ChocolateyUpdateDue) { Write-Output (Update-Chocolatey) }
$ExitCode = 0
if ($Upgrade) {
    & $Choco upgrade $Package -y --no-progress @VersionArguments @SourceArguments
    $ExitCode = $LASTEXITCODE
}
Exit-DeploymentLock
if ($Upgrade) {
    $InstallAction = if ($Installed) { "upgrade" } else { "install" }
    $InstallOk = $ExitCode -in 0, 1641, 3010
    Write-DeviceLog "choco $InstallAction $Package exit code $ExitCode"
    Save-LastResult $InstallAction $(if ($InstallOk) { "ok" } else { "failed" }) $(if ($ExitCode -in 1641, 3010) { 0 } else { $ExitCode }) $(if ($InstallOk) { "ok" } else { "failed: exit code $ExitCode" }) ([string](Get-InstalledVersion)) $Version
}
if ($ExitCode -notin 0, 1641, 3010) { exit $ExitCode }

# Settings for the update helpers; a new policy starts its own grace period
try {
    foreach ($File in "update.ps1", "notify.ps1", "probe.ps1") {
        Remove-Item -LiteralPath (Join-Path $AppRoot $File) -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $File) -Destination $AppRoot -Force -ErrorAction Stop
    }
    Write-ProtectedFile (Join-Path $AppRoot "config.json") (@{ Package = $Package; TaskId = $Package; TaskPath = $TaskPath; Source = $Source; Version = $Version; Mode = $Mode; GraceHours = $GraceHours; DisplayName = $DisplayName; Schedule = $Sched } | ConvertTo-Json -Depth 4)
    foreach ($File in "state.json", "retry.json", "restart.json") { Remove-Item -Path (Join-Path $AppRoot $File) -Force -ErrorAction SilentlyContinue }
}
catch { Write-Output "The update helpers could not be copied: $($_.Exception.Message)"; exit 1 }

__TASKREG__

Remove-UpdateTasks
try {
    Register-UpdateTasks
    Write-Output "Update mode $Mode applied for $Package"
    Write-DeviceLog "update mode $Mode applied"
}
catch {
    # Without its tasks the app is not set up: no marker, so detection fails and Intune runs install.ps1 again
    Write-Output "Update tasks could not be registered: $($_.Exception.Message)"
    Write-DeviceLog "update tasks could not be registered: $($_.Exception.Message)"
    Save-LastResult "install" "failed" 1 "update tasks could not be registered"
    exit 1
}

# The detection rule compares this marker with the policy in Intune
Write-ProtectedFile (Join-Path $AppRoot "policy.txt") $Policy
exit $ExitCode
'@

    $UpdateScript = @'
# Update helper of one Chocolatey app (scheduled tasks, SYSTEM). Settings come from config.json next to it.
#   -Mode Startup  update automatically per schedule (conditions, time window, retries); started by the triggers
#   -Mode Check    update available? Remember since when; after the grace period install it (Custom mode)
#   -Mode Now      install the update at once (started from the user prompt)
#   -Mode Restart  restart the device when an update asked for it (restart setting "outside the time window")
#   -Trigger       what started the run: Start, Window, Idle, Logon, Interval, Retry or Manual (for the log)
param(
    [ValidateSet("Startup", "Check", "Now", "Restart")][string]$Mode = "Check",
    [ValidateSet("Start", "Window", "Idle", "Logon", "Interval", "Retry", "Manual")][string]$Trigger = "Manual"
)

$Config = Get-Content -Path (Join-Path $PSScriptRoot "config.json") -Raw | ConvertFrom-Json
$Package = $Config.Package
$AppKey = $Package
$LogId = $Package -replace '[^A-Za-z0-9._-]', '_'
$StateFile = Join-Path $PSScriptRoot "state.json"
$LogFile = Join-Path $PSScriptRoot "update.log"

$ChocoRoot = $env:ChocolateyInstall
if (-not $ChocoRoot) { $ChocoRoot = Join-Path $env:ProgramData "chocolatey" }
$Choco = Join-Path $ChocoRoot "bin\choco.exe"
$SourceArguments = @()
if ($Config.Source) { $SourceArguments = @("--source", $Config.Source) }

__COMMON__
__CHOCOCOMMON__
__UPDATECOMMON__

if (-not (Test-Path $Choco)) { Write-Log "choco.exe not found"; exit 1 }

function Get-TargetVersion {
    # A released version is known; "latest" asks the source for the newest version of this one package
    # (choco 2 needs --exact to search for one id; the output is "id|version")
    if ($Config.Version) { return $Config.Version }
    $Line = & $Choco search $Package --exact --limit-output @SourceArguments 2>$null | Where-Object { $_ -like "$Package|*" } | Select-Object -First 1
    if ($Line) { return ($Line -split "\|")[1] }
}
function Get-InstalledText { return (Get-InstalledVersion) }
function Get-PendingUpdate {
    $Installed = Get-InstalledVersion
    $Target = Get-TargetVersion
    # "1.2.0" and "1.2" are the same version; latest: only something newer than the installed one counts
    $Pending = if (-not $Installed) { [bool]$Target }
    elseif ($Config.Version) { (Compare-PackageVersion $Target $Installed) -ne 0 }
    else { $Target -and (Compare-PackageVersion $Target $Installed) -gt 0 }
    return [pscustomobject]@{ Pending = [bool]$Pending; Installed = $Installed; Target = $Target }
}
function Invoke-SourceMaintenance {
    # Chocolatey itself, at most once a day (no waiting when another installation runs, the next run does it)
    if (Test-ChocolateyUpdateDue) {
        if (Enter-DeploymentLock) {
            try { Write-Log (Update-Chocolatey) } finally { Exit-DeploymentLock }
        }
    }
}
function Invoke-Upgrade {
    if (-not (Enter-DeploymentLock)) { Write-Log "another choco or winget installation is still running, next try later"; return 1618 }
    try {
        $VersionArguments = @()
        if ($Config.Version) { $VersionArguments = @("--version", $Config.Version, "--allow-downgrade") }
        & $Choco upgrade $Package -y --no-progress @VersionArguments @SourceArguments | Out-Null
        $Code = $LASTEXITCODE
    }
    finally { Exit-DeploymentLock }
    Write-Log "choco upgrade $Package exit code $Code"
    if ($Code -in 0, 1641, 3010) { Remove-Item -Path $StateFile -Force -ErrorAction SilentlyContinue }
    return $Code
}

$RunResult = @(Invoke-UpdateRun)
exit [int]$RunResult[-1]
'@

    $ChocoCommon = @'
function Get-InstalledVersion {
    $Nuspec = Join-Path $ChocoRoot "lib\$Package\$Package.nuspec"
    if (Test-Path $Nuspec) { return ([xml](Get-Content -Path $Nuspec -Raw)).package.metadata.version }
}
function ConvertTo-VersionParts([string]$Text) {
    # "01.2.0" -> 1, 2: no leading zeros, no trailing .0 parts
    $Parts = @(([string]$Text).Trim() -split '\.' | ForEach-Object { if ($_ -match '^\d+$') { $_.TrimStart('0') } else { $_ } } |
        ForEach-Object { if ($_ -eq '') { '0' } else { $_ } })
    $Count = $Parts.Count
    while ($Count -gt 1 -and $Parts[$Count - 1] -eq '0') { $Count-- }
    return , @($Parts[0..($Count - 1)])
}
function Compare-PackageVersion([string]$A, [string]$B) {
    # -1, 0 or 1. Number parts are compared as numbers ("1.10" is newer than "1.9"), other parts as text
    $Left = ConvertTo-VersionParts $A
    $Right = ConvertTo-VersionParts $B
    for ($i = 0; $i -lt [Math]::Max($Left.Count, $Right.Count); $i++) {
        $L = if ($i -lt $Left.Count) { [string]$Left[$i] } else { '0' }
        $R = if ($i -lt $Right.Count) { [string]$Right[$i] } else { '0' }
        if ($L -match '^\d+$' -and $R -match '^\d+$') {
            # Without leading zeros the longer number is the bigger one; same length compares like text
            $Result = if ($L.Length -ne $R.Length) { $L.Length.CompareTo($R.Length) } else { [string]::CompareOrdinal($L, $R) }
        }
        else { $Result = [string]::Compare($L, $R, [StringComparison]::OrdinalIgnoreCase) }
        if ($Result -ne 0) { return [Math]::Sign($Result) }
    }
    return 0
}
# Chocolatey itself is updated at most once a day, by whichever app gets there first
$ChocoStamp = Join-Path $ToolRoot "Chocolatey\chocolatey-update.txt"
function Test-ChocolateyUpdateDue {
    if (-not (Test-Path $ChocoStamp)) { return $true }
    try { return ([datetime](Get-Content -Path $ChocoStamp -Raw).Trim()).Date -lt (Get-Date).Date } catch { return $true }
}
function Update-Chocolatey {
    # Call it inside the deployment lock
    Write-ProtectedFile $ChocoStamp (Get-Date).ToString("o")
    & $Choco upgrade chocolatey -y --no-progress @SourceArguments | Out-Null
    return "choco upgrade chocolatey exit code $LASTEXITCODE"
}
'@

    $NotifyScript = Get-UpdateNotifyScript -TaskPath "\Intune-Choco-Updates\"

    $DetectionScript = @'
$Package = "__PACKAGE__"
$Policy = "__POLICY__"
$ChocoRoot = $env:ChocolateyInstall
if (-not $ChocoRoot) { $ChocoRoot = Join-Path $env:ProgramData "chocolatey" }
# Installed, and with the update policy that is set in Intune (otherwise Intune runs install.ps1 again to apply it)
$ProgramFilesDir = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
$Marker = Join-Path $ProgramFilesDir "IntuneChocoDeployment\Chocolatey\$Package\policy.txt"
if ((Test-Path (Join-Path $ChocoRoot "lib\$Package\$Package.nuspec")) -and (Test-Path $Marker) -and ((Get-Content -Path $Marker -Raw).Trim() -eq $Policy)) {
    Write-Output "$Package is installed (update policy $Policy)"
    exit 0
}
exit 1
'@

    if ($ChocoName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "'$ChocoName' is not a valid Chocolatey package id" }
    if ($Policy.UpdateDelayMinMinutes -lt 0 -or $Policy.UpdateDelayMaxMinutes -lt $Policy.UpdateDelayMinMinutes) { throw "Update delay range is invalid" }
    # Values go into single-quoted strings of ASCII files
    $Quote = { param($Text) ([string]$Text -replace '[^\x20-\x7E]', '').Replace("'", "''") }
    $Common = Get-DeviceScriptCommon
    $UpdateCommon = Get-DeviceUpdateCommon
    $InstallScript = $InstallScript.Replace("__TASKREG__", (Get-DeviceTaskRegistration)).Replace("__COMMON__", $Common).Replace("__CHOCOCOMMON__", $ChocoCommon)
    $UpdateScript = $UpdateScript.Replace("__UPDATECOMMON__", $UpdateCommon).Replace("__COMMON__", $Common).Replace("__CHOCOCOMMON__", $ChocoCommon)
    $InstallScript = $InstallScript.Replace("__SCHEDULE__", (Get-DeviceScheduleText $Policy.Schedule))
    $InstallScript = $InstallScript.Replace("__PACKAGE__", $ChocoName).Replace("__SOURCE__", (& $Quote $Policy.PackageSource))
    $InstallScript = $InstallScript.Replace("__VERSION__", (& $Quote $Policy.Version)).Replace("__MODE__", $Policy.UpdateMode).Replace("__GRACE__", [string][int]$Policy.GraceHours)
    $InstallScript = $InstallScript.Replace("__DISPLAYNAME__", (& $Quote $DisplayName)).Replace("__POLICY__", $Policy.Fingerprint)
    $InstallScript = $InstallScript.Replace("__DELAYMIN__", [string]$Policy.UpdateDelayMinMinutes).Replace("__DELAYMAX__", [string]$Policy.UpdateDelayMaxMinutes)
    $DetectionScript = $DetectionScript.Replace("__PACKAGE__", $ChocoName).Replace("__POLICY__", $Policy.Fingerprint)

    Set-Content -Path (Join-Path $SourcePath "install.ps1") -Value $InstallScript -Encoding ASCII
    Set-Content -Path (Join-Path $SourcePath "update.ps1") -Value $UpdateScript -Encoding ASCII
    Set-Content -Path (Join-Path $SourcePath "notify.ps1") -Value $NotifyScript -Encoding ASCII
    Set-Content -Path (Join-Path $SourcePath "probe.ps1") -Value (Get-ScreenProbeScript) -Encoding ASCII
    $DetectionFile = Join-Path (Split-Path $SourcePath) "detection.ps1"
    Set-Content -Path $DetectionFile -Value $DetectionScript -Encoding ASCII
    return $DetectionFile
}#Writes install.ps1, the update helpers and the detection script for an update policy

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
    $Package = Invoke-IntuneModule { New-IntuneWin32AppPackage -SourceFolder $SourcePath -SetupFile "install.ps1" -OutputFolder $WorkPath -Force }
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
        # Off, Startup or Custom (user prompt, installed after GraceHours at the latest)
        [ValidateSet("Off", "Startup", "Custom")]
        [string]$UpdateMode = $script:Settings.UpdateMode,
        [ValidateRange(1, 2160)]
        [int]$GraceHours = $script:Settings.GraceHours,
        # When and under which conditions updates install (hashtable of New-ChocoSchedule values); default = the UpdateSchedule setting
        $Schedule = (Get-ChocoScheduleDefaults),
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
                $AppName = Get-ChocoAppName -Info $Infos

                # Already there: same name, or created by this tool for the same package (also when renamed).
                # The module reads the whole list for a name filter anyway, so the full list costs the same.
                $Existing = @(Invoke-IntuneModule { Get-IntuneWin32App } | Where-Object { $_.displayName -eq $AppName -or (ConvertFrom-ChocoAppNotes ([string]$_.notes)).Package -eq $Name -and [string]$_.notes -like "$($script:AppMarker)*" })
                if ($Existing.Count -gt 0) {
                    Write-Warning "$AppName is already deployed ($($Existing[0].displayName)), please update or remove first"
                    continue
                }

                ### PackTune Runtime (the one dependency app of both sources), created once per tenant
                if ($null -eq $ChocoID) {
                    Write-Host "Checking if the PackTune Runtime is deployed in Intune"
                    $ChocoID = Get-PackTuneRuntimeWin32ID
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

                ### Update policy: version and update mode
                $PinnedVersion = switch ($Version) {
                    { $_ -eq "latest" } { ""; break }
                    { $_ -eq "current" } { $Infos.Version; break }
                    { -not $_ } { if ($script:Settings.VersionMode -eq "Pinned") { $Infos.Version } else { "" }; break }
                    default {
                        if ($Version -notin (Get-ChocoPackageVersions -ChocoName $Name)) { throw "Version $Version of $Name does not exist on $($script:Settings.MetadataFeed)" }
                        $Version
                    }
                }
                $Policy = New-ChocoAppPolicy -Package $Name -Version $PinnedVersion -UpdateMode $UpdateMode -GraceHours $GraceHours `
                    -PackageSource $PackageSource -UpdateDelayMinMinutes $UpdateDelayMinMinutes -UpdateDelayMaxMinutes $UpdateDelayMaxMinutes -Schedule $Schedule
                Write-Host ("Version: {0}, updates: {1}" -f $(if ($PinnedVersion) { $PinnedVersion } else { "always the latest" }), (Format-ChocoUpdateMode $Policy))

                ### Install and Detection Script, package
                Write-Host "Creating the install and detection script"
                $WorkPath = New-IntuneChocoWorkFolder -Name $Name
                $DetectionFile = New-ChocoPackageScripts -ChocoName $Name -SourcePath (Join-Path $WorkPath "source") -Policy $Policy -DisplayName $AppName
                $IntuneWinFile = New-IntuneChocoPackage -WorkPath $WorkPath

                $DetectionRule = Invoke-IntuneModule { New-IntuneWin32AppDetectionRuleScript -ScriptFile $DetectionFile }
                $RequirementRule = Invoke-IntuneModule { New-IntuneWin32AppRequirementRule -Architecture $Architecture -MinimumSupportedWindowsRelease W10_1607 }

                ### Deploy Application
                Write-Host "Creating and Uploading $AppName as win32 App to Intune"
                $AppParams = @{
                    FilePath             = $IntuneWinFile.Path
                    DisplayName          = $AppName
                    Description          = $Infos.Description
                    Publisher            = $(if ($Infos.Authors) { $Infos.Authors } else { "-" })
                    AppVersion           = $(if ($PinnedVersion) { $PinnedVersion } else { "latest" })
                    Notes                = ConvertTo-ChocoAppNotes $Policy
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

                Write-Host "Adding dependency for the PackTune Runtime to the created Application"
                Invoke-IntuneModule {
                    $Dependency = New-IntuneWin32AppDependency -ID $ChocoID -DependencyType AutoInstall
                    Add-IntuneWin32AppDependency -ID $IntuneApp.id -Dependency $Dependency
                } | Out-Null

                Set-IntuneChocoAssignment -Id $IntuneApp.id -Assignment $Assignment

                Write-Host "Deployment of $AppName was successful"
                $IntuneApp.id
            }
            catch {
                Write-Error "Deployment of $Name failed: $($_.Exception.Message)"
            }
        }
    }

}#Main function for deploying The Applications

function Set-IntuneChocoAssignment {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [ValidateSet("Available", "Required", "None")][string]$Assignment
    )
    switch ($Assignment) {
        "Required" {
            Write-Host "Enable autodeployment for all users"
            Invoke-IntuneModule { Add-IntuneWin32AppAssignmentAllUsers -ID $Id -Intent required -Notification showReboot } | Out-Null
        }
        "Available" {
            Write-Host "Making application available in companyportal for all users"
            Invoke-IntuneModule { Add-IntuneWin32AppAssignmentAllUsers -ID $Id -Intent available -Notification showReboot } | Out-Null
        }
        default { Write-Host "No assignment created, assign the app in Intune yourself" }
    }
}#Assigns an app to all users (available or required)

function Format-ChocoUpdateMode {
    param([Parameter(Mandatory = $true)]$Policy)
    switch ($Policy.UpdateMode) {
        "Off" { "off (released versions are installed by Intune right away)" }
        "Startup" {
            $S = $Policy.Schedule
            $When = @()
            if ($S.TriggerStart) { $When += "at startup" }
            if ($S.TriggerWindow) { $When += "daily $($S.WindowFrom)-$($S.WindowTo)" }
            if ($S.IdleMinutes -gt 0) { $When += "when idle $($S.IdleMinutes) min" }
            if ($S.TriggerLogon) { $When += "at sign-in" }
            "automatic ($($When -join ', '))"
        }
        "Custom" {
            $Grace = if ($Policy.GraceHours % 24 -eq 0) { "$($Policy.GraceHours / 24) day(s)" } else { "$($Policy.GraceHours) hour(s)" }
            "user prompt, installed after $Grace at the latest"
        }
    }
}#Update mode in words

function Get-ChocoPackageVersions {
    param([Parameter(Mandatory = $true)][string]$ChocoName)
    $Id = [uri]::EscapeDataString($ChocoName.ToLower().Replace("'", "''"))
    @(Invoke-ChocoFeed -Query "FindPackagesById()?id='$Id'&semVerLevel=2.0.0" | ForEach-Object { $_.Version })
}#All versions of a package on the metadata feed

function Get-IntuneChocoPackageVersions {
    param([Parameter(Mandatory = $true)][string]$Package, [ValidateSet("Chocolatey", "Winget")][string]$Source = "Chocolatey")
    $All = if ($Source -eq "Winget") { Get-WingetPackageVersions -WingetId $Package } else { Get-ChocoPackageVersions -ChocoName $Package }
    # Newest first, prereleases left out
    @($All | Where-Object { $_ -and $_ -notmatch '-' } | Sort-Object { try { [version](([string]$_ -replace '[^\d.].*$', '').TrimEnd('.')) } catch { [version]'0.0' } } -Descending | Select-Object -Unique -First 40)
}#Versions an admin can release for a package

function Update-IntuneChocoApp {
    <#
        Changes the update policy of an app in Intune, or releases another version: builds the package with the new
        policy, uploads it as new content and replaces the detection rule. Devices no longer detect the app as
        current and run install.ps1 again, which applies the policy (and, depending on the update mode, the version).
        Without parameters it keeps the current values (useful to roll out improved device scripts).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AppId,
        # Exact version to release, or "latest" to follow the newest version again
        [string]$Version,
        [ValidateSet("Off", "Startup", "Custom")][string]$UpdateMode,
        [ValidateRange(1, 2160)][int]$GraceHours,
        # Schedule values to change (hashtable of New-ChocoSchedule values, may be partial); the others stay as they are
        $Schedule
    )
    Assert-IntuneChocoPrerequisites
    Assert-IntuneChocoConnection
    Update-IntuneChocoToken

    $App = Invoke-IntuneModule { Get-IntuneWin32App -ID $AppId }
    if ($null -eq $App) { throw "App $AppId was not found in Intune" }
    $IsWinget = [string]$App.notes -like "$($script:WingetMarker)*"
    $Current = ConvertFrom-ChocoAppNotes $App.notes
    if (-not $Current.Package) { throw "$($App.displayName) has no package id in its notes (created by an older version of this tool). Remove it and deploy it again." }
    $Package = $Current.Package

    $NewVersion = if ($PSBoundParameters.ContainsKey("Version")) { $Version } else { $Current.Version }
    if ($NewVersion -eq "latest") { $NewVersion = "" }
    if ($NewVersion -and ($NewVersion -notin $(if ($IsWinget) { Get-WingetPackageVersions -WingetId $Package } else { Get-ChocoPackageVersions -ChocoName $Package }))) {
        throw "Version $NewVersion of $Package does not exist on $(if ($IsWinget) { 'the winget source' } else { $script:Settings.MetadataFeed })"
    }
    $NewMode = if ($UpdateMode) { $UpdateMode } else { $Current.UpdateMode }
    $NewGrace = if ($PSBoundParameters.ContainsKey("GraceHours")) { $GraceHours } else { $Current.GraceHours }

    # Source and delay stay those of the app; apps from before they were in the notes take the current settings
    $NewSource = if ($IsWinget) { "" } elseif ($null -ne $Current.PackageSource) { $Current.PackageSource } else { $script:Settings.PackageSource }
    $DelayMin = if ($null -ne $Current.UpdateDelayMinMinutes) { $Current.UpdateDelayMinMinutes } else { $script:Settings.UpdateDelayMinMinutes }
    $DelayMax = if ($null -ne $Current.UpdateDelayMaxMinutes) { $Current.UpdateDelayMaxMinutes } else { $script:Settings.UpdateDelayMaxMinutes }

    # The schedule stays that of the app (apps from before schedules existed keep the built-in defaults = their old behavior)
    $NewSchedule = New-ChocoSchedule -Values $Schedule -Base $Current.Schedule
    $Policy = New-ChocoAppPolicy -Package $Package -Version $NewVersion -UpdateMode $NewMode -GraceHours $NewGrace -PackageSource $NewSource `
        -UpdateDelayMinMinutes $DelayMin -UpdateDelayMaxMinutes $DelayMax -Schedule $NewSchedule
    Write-Host ("{0}: version {1}, updates {2}" -f $App.displayName, $(if ($NewVersion) { $NewVersion } else { "always the latest" }), (Format-ChocoUpdateMode $Policy))

    Write-Host "Building the package with the new policy"
    $WorkPath = New-IntuneChocoWorkFolder -Name $(if ($IsWinget) { "winget-" + ($Package -replace '[^A-Za-z0-9._-]', '_') } else { $Package })
    $DetectionFile = if ($IsWinget) { New-WingetPackageScripts -WingetId $Package -SourcePath (Join-Path $WorkPath "source") -Policy $Policy -DisplayName $App.displayName }
    else { New-ChocoPackageScripts -ChocoName $Package -SourcePath (Join-Path $WorkPath "source") -Policy $Policy -DisplayName $App.displayName }
    $IntuneWinFile = New-IntuneChocoPackage -WorkPath $WorkPath

    # Content first, then the detection rule: until the rule changes, devices keep the old state
    Write-Host "Uploading the new content"
    Invoke-IntuneModule { Update-IntuneWin32AppPackageFile -ID $AppId -FilePath $IntuneWinFile.Path } | Out-Null
    Write-Host "Updating detection rule, version and notes"
    $DetectionRule = Invoke-IntuneModule { New-IntuneWin32AppDetectionRuleScript -ScriptFile $DetectionFile }
    $Notes = ConvertTo-ChocoAppNotes -Policy $Policy -Marker $(if ($IsWinget) { $script:WingetMarker } else { $script:AppMarker })
    Invoke-IntuneModule { Set-IntuneWin32App -ID $AppId -DetectionRule @($DetectionRule) -Notes $Notes -AppVersion $(if ($NewVersion) { $NewVersion } else { "latest" }) } | Out-Null
    Write-Host "Done: devices apply it at their next Intune check (or startup)."
    $AppId
}#Applies a changed update policy or released version to an app in Intune

function Find-SandboxStudio {
    <# Path of MsixSandboxStudio.psd1 (WindowsSandboxMSIXInstaller) for the Test button, or $null. #>
    $Candidates = @()
    if ($script:Settings.SandboxStudioPath) { $Candidates += $script:Settings.SandboxStudioPath }
    $Candidates += (Join-Path (Split-Path $PSScriptRoot -Parent) "WindowsSandboxMSIXInstaller"), "C:\git\WindowsSandboxMSIXInstaller"
    foreach ($Folder in $Candidates) {
        foreach ($File in (Join-Path $Folder "MsixSandboxStudio\MsixSandboxStudio.psd1"), (Join-Path $Folder "MsixSandboxStudio.psd1")) {
            if (Test-Path $File) { return (Resolve-Path $File).ProviderPath }
        }
    }
    $Module = Get-Module -ListAvailable MsixSandboxStudio | Sort-Object Version -Descending | Select-Object -First 1
    if ($Module) { return $Module.Path }
    return $null
}

function Copy-LabPackageFiles {
    <#
        The package content for the Win32 Test Lab: every file of the generated source folder, like the Intune package
        (which packs the whole folder), so a new helper of install.ps1 cannot be forgotten. install.ps1 becomes
        choco-app.ps1, because the lab's own Install.ps1 is the same file name on Windows.
    #>
    param([Parameter(Mandatory = $true)][string]$SourcePath, [Parameter(Mandatory = $true)][string]$Destination)
    foreach ($File in @(Get-ChildItem -LiteralPath $SourcePath -File)) {
        $Name = if ($File.Name -eq "install.ps1") { "choco-app.ps1" } else { $File.Name }
        Copy-Item -LiteralPath $File.FullName -Destination (Join-Path $Destination $Name) -Force
    }
}#Copies the generated package files into the lab project

function Test-IntuneChocoPackage {
    <#
        Tests a package in Windows Sandbox with the Win32 Test Lab of MSIX Sandbox Studio (WindowsSandboxMSIXInstaller):
        a fresh sandbox installs Chocolatey (in Intune it is a dependency app), then you run Install, Detect and
        Uninstall with one click each, as SYSTEM like Intune, and report the result. Returns the verdict.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ChocoName,
        [string]$Version = "",
        [ValidateSet("Off", "Startup", "Custom")][string]$UpdateMode = $script:Settings.UpdateMode,
        [ValidateRange(1, 2160)][int]$GraceHours = $script:Settings.GraceHours,
        [ValidateSet("Chocolatey", "Winget")][string]$Source = "Chocolatey",
        $Schedule = (Get-ChocoScheduleDefaults)
    )
    $IsWinget = $Source -eq "Winget"
    $Studio = Find-SandboxStudio
    if (-not $Studio) { throw "MSIX Sandbox Studio (WindowsSandboxMSIXInstaller) was not found. Set its folder in Settings (Sandbox Studio path)." }
    Import-Module $Studio -Force -ErrorAction Stop
    $Info = if ($IsWinget) { Get-WingetInfo -WingetId $ChocoName } else { Get-ChocoInfo -ChocoName $ChocoName }
    $Package = $Info.Name
    if ($Version -eq "latest") { $Version = "" }
    if ($Version -eq "current") { $Version = $Info.Version }
    $Policy = New-ChocoAppPolicy -Package $Package -Version $Version -UpdateMode $UpdateMode -GraceHours $GraceHours -PackageSource $(if ($IsWinget) { "" } else { $script:Settings.PackageSource }) `
        -UpdateDelayMinMinutes $script:Settings.UpdateDelayMinMinutes -UpdateDelayMaxMinutes $script:Settings.UpdateDelayMaxMinutes -Schedule $Schedule

    # The package scripts exactly as deployed
    $SafePackage = $Package -replace '[^A-Za-z0-9._-]', '_'
    $WorkPath = New-IntuneChocoWorkFolder -Name "test-$SafePackage"
    $SourcePath = Join-Path $WorkPath "source"
    $DetectionFile = if ($IsWinget) { New-WingetPackageScripts -WingetId $Package -SourcePath $SourcePath -Policy $Policy -DisplayName $Info.Title }
    else { New-ChocoPackageScripts -ChocoName $Package -SourcePath $SourcePath -Policy $Policy -DisplayName $Info.Title }

    # Lab scripts: Chocolatey first (Intune installs it as dependency), then the package's own install.ps1.
    # The package script is copied as choco-app.ps1: Install.ps1 and install.ps1 are the same file on Windows.
    $DownloadUrl = $script:Settings.ChocolateyDownloadUrl.Replace("'", "''")
    $LabInstall = @"
# Win32 Test Lab: Chocolatey (a dependency app in Intune), then the package as deployed
`$Choco = Join-Path `$env:ProgramData 'chocolatey\bin\choco.exe'
if (-not (Test-Path `$Choco)) {
    Write-Output 'Installing Chocolatey (in Intune it is the dependency app)'
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    if ('$DownloadUrl') { `$env:chocolateyDownloadUrl = '$DownloadUrl' }
    Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    if (-not (Test-Path `$Choco)) { Write-Output 'Chocolatey could not be installed'; exit 1 }
}
& "`$PSScriptRoot\choco-app.ps1"
exit `$LASTEXITCODE
"@
    if ($IsWinget) {
        # Windows Sandbox has no working winget for SYSTEM: Microsoft's module installs it for all users first
        $LabInstall = @'
# Win32 Test Lab: winget (part of Windows on real devices), then the package as deployed
$Found = Get-ChildItem -Path (Join-Path $env:ProgramFiles "WindowsApps") -Filter "Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe" -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName "winget.exe") }
if (-not $Found) {
    Write-Output 'Installing winget for the test (real devices already have it)'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    Install-Module Microsoft.WinGet.Client -Force -Scope AllUsers -AllowClobber
    Import-Module Microsoft.WinGet.Client
    Repair-WinGetPackageManager -AllUsers -Latest -Force
}
& "$PSScriptRoot\choco-app.ps1"
exit $LASTEXITCODE
'@
    }
    $LabUninstall = "& `"`$PSScriptRoot\choco-app.ps1`" -Uninstall`r`nexit `$LASTEXITCODE"
    $LabDetect = Get-Content -Path $DetectionFile -Raw

    $Id = $(if ($IsWinget) { "Winget-" } else { "Choco-" }) + ($Package -replace '[^A-Za-z0-9._-]', '')
    $Project = Save-Win32AppProject -Id $Id -DisplayName "$($Info.Title) ($Source)" -Publisher $(if ($Info.Authors) { [string]$Info.Authors } else { "" }) `
        -Version $(if ($Version) { $Version } else { $Info.Version }) -Detection (New-Win32Detection -Type Script) -RunAs system `
        -Scripts @{ "Install.ps1" = $LabInstall; "Uninstall.ps1" = $LabUninstall; "Detect.ps1" = $LabDetect; "Update.ps1" = "" }
    Copy-LabPackageFiles -SourcePath $SourcePath -Destination $Project.SourcePath

    Write-Host "Opening the Win32 Test Lab in Windows Sandbox for $($Info.Title): run Install, Detect, Uninstall there, then report the result"
    $Result = Start-Win32TestLab -Id $Id
    Write-Host "Test result: $($Result.Verdict). $($Result.Message)"
    [pscustomobject]@{ Package = $Package; Source = $Source; Verdict = $Result.Verdict; Message = $Result.Message; JobPath = $Result.JobPath }
}#Tests a package in Windows Sandbox (Win32 Test Lab of MSIX Sandbox Studio)

function Get-IntuneChocoTenantApps {

    Assert-IntuneChocoPrerequisites
    Assert-IntuneChocoConnection
    Update-IntuneChocoToken

    foreach ($App in @(Invoke-IntuneModule { Get-IntuneWin32App })) {
        $Notes = [string]$App.notes
        $IsChocolatey = $Notes -like "*$($script:ChocoAppMarker)*" -and $App.displayName -eq "Chocolatey"
        $IsWinget = $Notes -like "$($script:WingetMarker)*"
        if (-not $IsChocolatey -and -not $IsWinget -and $Notes -notlike "$($script:AppMarker)*") { continue }

        # Apps created before the package id was stored in the notes only carry "PoweredByChocolatey"
        $Policy = ConvertFrom-ChocoAppNotes $Notes
        $Package = $Policy.Package
        if ($IsChocolatey) { $Package = "chocolatey" }

        [pscustomobject]@{
            Id           = $App.id
            DisplayName  = $App.displayName
            Package      = $Package
            Source       = $(if ($IsWinget) { "Winget" } else { "Chocolatey" })
            IsChocolatey = $IsChocolatey
            Created      = $App.createdDateTime
            AppVersion   = $App.displayVersion
            # Update policy ("" = always the latest version); apps from older versions: latest, update at startup
            Version      = $Policy.Version
            UpdateMode   = $Policy.UpdateMode
            GraceHours   = $Policy.GraceHours
            HasPolicy    = $Policy.HasPolicy
            Schedule     = $Policy.Schedule
        }
    }

}#Lists the Win32 apps in the tenant that were created by this tool

function Remove-IntuneChocoApplication {
    param([Parameter(Mandatory = $true)][string]$Id)

    # Only apps this tool created (recognized by their notes) are removed, never anything else in the tenant
    $Apps = @(Get-IntuneChocoTenantApps)
    $App = $Apps | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $App) { throw "App $Id was not created by this tool or does not exist anymore, nothing was removed" }
    if ($App.IsChocolatey) {
        # The old Chocolatey dependency app: only when none of the tool's apps depends on it any more
        $Users = @($Apps | Where-Object { -not $_.IsChocolatey -and @(Invoke-IntuneModule { Get-IntuneWin32AppDependency -ID $_.Id } | Where-Object { [string]$_.targetId -eq $Id }).Count -gt 0 })
        if ($Users.Count -gt 0) { throw "Chocolatey is the dependency of $($Users.Count) app(s) created by this tool. Switch them to the PackTune Runtime first (Switch-IntuneChocoAppsToRuntime)." }
    }
    Write-Host "Removing $($App.DisplayName) from Intune"
    Invoke-IntuneModule { Remove-IntuneWin32App -ID $Id } | Out-Null
    if (@(Invoke-IntuneModule { Get-IntuneWin32App } | Where-Object { $_.id -eq $Id }).Count -gt 0) { throw "Intune still lists $($App.DisplayName), it was not removed" }
    Write-Host "$($App.DisplayName) was removed from Intune. Devices keep the installed software and its update task."
}#Removes an app this tool created from the tenant

function Get-IntuneChocoCatalog {

    $Catalog = Get-Content -Path $script:CatalogPath -Raw | ConvertFrom-Json
    foreach ($Entry in $Catalog) {
        [pscustomobject]@{
            Id          = $Entry.id
            # Optional: the same app in the winget community repository
            WingetId    = $Entry.winget
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

# winget packages (same helpers, own install script)
. (Join-Path $PSScriptRoot "ChocoIntuneDeployment-Winget.ps1")
# One app list for both sources, the PackTune Runtime dependency app, release via supersedence
. (Join-Path $PSScriptRoot "ChocoIntuneDeployment-Sources.ps1")
. (Join-Path $PSScriptRoot "ChocoIntuneDeployment-Runtime.ps1")
. (Join-Path $PSScriptRoot "ChocoIntuneDeployment-Release.ps1")

# Tenant insight (import of existing apps, install status): own module, gets the functions it needs from here
Import-Module (Join-Path $PSScriptRoot "Modules\TenantInsight.psm1") -Force -Global
Set-TenantInsightHooks -Markers @{ Tool = $script:AppMarker; Winget = $script:WingetMarker; ChocolateyApp = $script:ChocoAppMarker } `
    -ConvertFromNotes ${function:ConvertFrom-ChocoAppNotes} -ConvertToNotes ${function:ConvertTo-ChocoAppNotes} -NewPolicy ${function:New-ChocoAppPolicy} `
    -NewChocoApp ${function:New-IntuneWin32ChocoApplication} -NewWingetApp ${function:New-IntuneWin32WingetApplication} -SignIn ${function:Invoke-IntuneChocoPkceSignIn}

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
