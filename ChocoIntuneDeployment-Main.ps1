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
}
$script:UpdateModes = "Off", "Startup", "Custom"
# Raised whenever the device scripts change in a way devices must pick up (it is part of the policy fingerprint)
$script:DeviceScriptRevision = 3

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
    # The current pair is remembered for later tenant switches
    $Map = ConvertFrom-TenantClients $Clean.TenantClients
    if ($Clean.TenantID -and $Clean.ClientID) { $Map[$Clean.TenantID.ToLower()] = $Clean.ClientID }
    $Clean.TenantClients = (@($Map.Keys | Sort-Object | ForEach-Object { "$_=$($Map[$_])" })) -join ";"
    if ($Clean.UpdateMode -notin $script:UpdateModes) { throw "Unknown update mode '$($Clean.UpdateMode)'" }
    if ($Clean.GraceHours -lt 1 -or $Clean.GraceHours -gt 2160) { throw "The grace period must be between 1 hour and 90 days" }
    if ($Clean.VersionMode -notin "Latest", "Pinned") { throw "Unknown version mode '$($Clean.VersionMode)'" }

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

function New-ChocoAppPolicy {
    <#
        The update policy of one app: version (empty = always the latest), update mode, grace period and the
        values baked into the device scripts. The fingerprint goes into the detection rule: when it changes in
        Intune, devices no longer detect the app as current and run install.ps1 again, which applies the policy.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Package,
        [string]$Version = "",
        [ValidateSet("Off", "Startup", "Custom")][string]$UpdateMode = "Startup",
        [ValidateRange(1, 2160)][int]$GraceHours = 48,
        [string]$PackageSource = "",
        [int]$UpdateDelayMinMinutes = 5,
        [int]$UpdateDelayMaxMinutes = 60
    )
    if ($Version -eq "latest") { $Version = "" }
    if ($Version -and $Version -notmatch '^[0-9A-Za-z][0-9A-Za-z.+-]*$') { throw "'$Version' is not a valid package version" }
    $Text = "$($Package.ToLower())|$Version|$UpdateMode|$GraceHours|$PackageSource|$UpdateDelayMinMinutes|$UpdateDelayMaxMinutes|$($script:DeviceScriptRevision)"
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
        Fingerprint           = $Hash
    }
}#Returns the update policy of an app with its fingerprint

function ConvertTo-ChocoAppNotes {
    param([Parameter(Mandatory = $true)]$Policy, [string]$Marker = $script:AppMarker)
    $Version = if ($Policy.Version) { $Policy.Version } else { "latest" }
    # Package source (URL encoded) and startup delay belong to the app too, so a later change keeps them
    return "$Marker;package=$($Policy.Package);version=$Version;update=$($Policy.UpdateMode);grace=$($Policy.GraceHours)" +
        ";source=$([uri]::EscapeDataString([string]$Policy.PackageSource));delay=$($Policy.UpdateDelayMinMinutes)-$($Policy.UpdateDelayMaxMinutes)"
}#Notes of the Intune app: marker, package and update policy (read back by ConvertFrom-ChocoAppNotes)

function ConvertFrom-ChocoAppNotes {
    param([string]$Notes)
    # PackageSource and the delays are $null for apps from before they were stored (callers use the current settings)
    $Result = [ordered]@{ Package = $null; Version = ""; UpdateMode = "Startup"; GraceHours = 48; HasPolicy = $false
        PackageSource = $null; UpdateDelayMinMinutes = $null; UpdateDelayMaxMinutes = $null }
    if ($Notes -match 'package=([A-Za-z0-9._+-]+)') { $Result.Package = $Matches[1] }
    if ($Notes -match 'version=([0-9A-Za-z.+-]+)' -and $Matches[1] -ne "latest") { $Result.Version = $Matches[1] }
    if ($Notes -match 'update=(Off|Startup|Custom)') { $Result.UpdateMode = $Matches[1]; $Result.HasPolicy = $true }
    if ($Notes -match 'grace=(\d+)') { $Result.GraceHours = [int]$Matches[1] }
    if ($Notes -match 'source=([^;]*)') { $Result.PackageSource = [uri]::UnescapeDataString($Matches[1]) }
    if ($Notes -match 'delay=(\d+)-(\d+)') { $Result.UpdateDelayMinMinutes = [int]$Matches[1]; $Result.UpdateDelayMaxMinutes = [int]$Matches[2] }
    # Apps from before the update policy keep their behavior: latest version, update at startup
    return [pscustomobject]$Result
}#Reads package and update policy from the notes of an Intune app

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
            $Page = if (-not $Done) { "" } elseif ($Failed) { "<h2>Sign-in failed</h2><p>Details are shown in Intune Chocolatey Deployment. You can close this window.</p>" }
                    else { "<h2>Sign-in complete</h2><p>You can close this window and return to Intune Chocolatey Deployment.</p>" }
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
        [string]$DisplayName = "Intune Chocolatey Deployment",
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
    $Access = foreach ($Name in $ScopeNames) {
        $Scope = $GraphSp.oauth2PermissionScopes | Where-Object value -eq $Name | Select-Object -First 1
        if (-not $Scope) { throw "The Graph permission $Name was not found." }
        @{ id = $Scope.id; type = "Scope" }
    }

    # An app registration of an earlier setup is reused
    $Filter = [uri]::EscapeDataString("displayName eq '$($DisplayName.Replace("'", "''"))'")
    $App = (& $Call GET "/v1.0/applications?`$filter=$Filter&`$select=id,appId,publicClient,isFallbackPublicClient" $null).value |
        Where-Object { $_.publicClient.redirectUris -contains "http://localhost" } | Select-Object -First 1
    $Definition = @{
        isFallbackPublicClient = $true
        publicClient           = @{ redirectUris = @("http://localhost") }
        requiredResourceAccess = @(@{ resourceAppId = $GraphApp; resourceAccess = @($Access) })
    }
    if ($App) {
        Write-Host "App registration '$DisplayName' exists already ($($App.appId)), its permissions are updated"
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
# One choco or winget operation at a time on the device, for all apps of both sources
$script:LockHeld = $false
$script:Lock = New-Object System.Threading.Mutex($false, "Global\IntuneChocoDeployment")
function Enter-DeploymentLock {
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
    return $Owner -notin "S-1-5-18", "S-1-5-32-544"
}
function Remove-ItemSafely([string]$Path) {
    # Links are removed themselves, never what they point to
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
function Remove-ForeignItems([string]$Path) {
    foreach ($Child in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        if (Test-ForeignItem $Child.FullName) { Remove-ItemSafely $Child.FullName }
        elseif ($Child.PSIsContainer) { Remove-ForeignItems $Child.FullName }
    }
}
function Protect-Folder([string]$Path) {
    # Owner SYSTEM, no inherited rights: SYSTEM and Administrators full control, Users read and execute.
    # A folder a user created before (e.g. to replace update.ps1, which runs as SYSTEM) is removed first.
    # SIDs, not names: the names are translated on non-English Windows.
    if (Test-ForeignItem $Path) { Remove-ItemSafely $Path }
    New-Item -Path $Path -ItemType Directory -Force | Out-Null
    $Acl = New-Object System.Security.AccessControl.DirectorySecurity
    $Acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier "S-1-5-18"))
    $Acl.SetAccessRuleProtection($true, $false)
    foreach ($Entry in @(@("S-1-5-18", "FullControl"), @("S-1-5-32-544", "FullControl"), @("S-1-5-32-545", "ReadAndExecute"))) {
        $Sid = New-Object System.Security.Principal.SecurityIdentifier $Entry[0]
        $Acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($Sid, $Entry[1], "ContainerInherit, ObjectInherit", "None", "Allow")))
    }
    [IO.Directory]::SetAccessControl($Path, $Acl)
    # Now nobody else can add anything; what is left from before and not ours goes
    Remove-ForeignItems $Path
}
function Write-ProtectedFile([string]$Path, [string]$Text) {
    # A new file instead of writing into an existing one (which could be a hard link)
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $Path -Value $Text -Encoding ASCII
}
'@
}#Lock and folder protection of the device scripts

function Get-UpdateNotifyScript {
    # The update prompt of Custom mode, for Chocolatey and winget apps (only the task folder differs)
    param([Parameter(Mandatory = $true)][string]$TaskPath)
    $Script = @'
# Shows the update prompt in the session of a signed-in user (scheduled task of the Users group, no admin rights).
# "Install now" starts the SYSTEM task "Update <package> now"; "Later" is respected for 4 hours, but not within the
# last hour before the update is installed anyway.
$StateFile = Join-Path $PSScriptRoot "state.json"
if (-not (Test-Path $StateFile)) { exit 0 }
try { $State = Get-Content -Path $StateFile -Raw | ConvertFrom-Json } catch { exit 0 }
$Deadline = [datetime]$State.Deadline
if ((Get-Date) -ge $Deadline) { exit 0 }

$SnoozeFolder = Join-Path $env:LOCALAPPDATA "IntuneChocoUpdates"
$SnoozeFile = Join-Path $SnoozeFolder "$($State.Package).snooze"
if (Test-Path $SnoozeFile) {
    try { $Until = [datetime](Get-Content -Path $SnoozeFile -Raw).Trim() } catch { $Until = Get-Date }
    if ((Get-Date) -lt $Until -and $Deadline -gt (Get-Date).AddHours(1)) { exit 0 }
}

Add-Type -AssemblyName System.Windows.Forms
$Name = if ($State.DisplayName) { $State.DisplayName } else { $State.Package }
# DefaultDesktopOnly: the prompt comes to the front without a window of its own
$Options = [System.Windows.Forms.MessageBoxOptions]::DefaultDesktopOnly
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
}#Script of the update prompt for the signed-in user

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
$TaskNames = @("Update $Package on startup", "Update $Package now", "Check $Package for updates", "Notify $Package update")
$Base = Join-Path $env:ProgramData "IntuneChocoUpdates"
$AppRoot = Join-Path $Base $Package
function Remove-UpdateTasks {
    foreach ($Name in $TaskNames) { Unregister-ScheduledTask -TaskName $Name -TaskPath $TaskPath -Confirm:$false -ErrorAction SilentlyContinue }
}
$SourceArguments = @()
if ($Source) { $SourceArguments = @("--source", $Source) }

__COMMON__
__CHOCOCOMMON__

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
    Protect-Folder $Base
    Protect-Folder $AppRoot
}
catch { Write-Output "The folder $AppRoot could not be protected: $($_.Exception.Message)"; exit 1 }

# A new installation always installs. When only the policy changed (released version, update mode), the device
# follows its update mode: Off installs a released version right away (latest + Off leaves the installed version
# alone), Startup at the next startup, Custom asks the user and installs at the latest when the grace period is over.
$Upgrade = (-not $Installed) -or ($Mode -eq "Off" -and $Version -and (Compare-PackageVersion $Version $Installed) -ne 0)
if (-not (Enter-DeploymentLock)) { Write-Output "Another choco or winget installation is still running after 30 minutes"; exit 1618 }
if (Test-ChocolateyUpdateDue) { Write-Output (Update-Chocolatey) }
$ExitCode = 0
if ($Upgrade) {
    & $Choco upgrade $Package -y --no-progress @VersionArguments @SourceArguments
    $ExitCode = $LASTEXITCODE
}
Exit-DeploymentLock
if ($ExitCode -notin 0, 1641, 3010) { exit $ExitCode }

# Settings for the update helpers; a new policy starts its own grace period
try {
    foreach ($File in "update.ps1", "notify.ps1") {
        Remove-Item -LiteralPath (Join-Path $AppRoot $File) -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $File) -Destination $AppRoot -Force -ErrorAction Stop
    }
    Write-ProtectedFile (Join-Path $AppRoot "config.json") (@{ Package = $Package; Source = $Source; Version = $Version; Mode = $Mode; GraceHours = $GraceHours; DisplayName = $DisplayName } | ConvertTo-Json)
    Remove-Item -Path (Join-Path $AppRoot "state.json") -Force -ErrorAction SilentlyContinue
}
catch { Write-Output "The update helpers could not be copied: $($_.Exception.Message)"; exit 1 }

Remove-UpdateTasks
try {
    $PowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $UpdateScript = Join-Path $AppRoot "update.ps1"
    $System = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
    $UpdateAction = { param($Step) New-ScheduledTaskAction -Execute $PowerShell -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$UpdateScript`" -Mode $Step" }

    if ($Mode -in "Startup", "Custom") {
        # Each device waits a random time, so a whole office behind one IP doesn't hit the Chocolatey rate limit at once
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
    Write-Output "Update mode $Mode applied for $Package"
}
catch {
    # Without its tasks the app is not set up: no marker, so detection fails and Intune runs install.ps1 again
    Write-Output "Update tasks could not be registered: $($_.Exception.Message)"
    exit 1
}

# The detection rule compares this marker with the policy in Intune
Write-ProtectedFile (Join-Path $AppRoot "policy.txt") $Policy
exit $ExitCode
'@

    $UpdateScript = @'
# Update helper of one Chocolatey app (scheduled tasks, SYSTEM). Settings come from config.json next to it.
#   Startup  update to the target version (startup task)
#   Check    update available? Remember since when; after the grace period install it
#   Now      install the update at once (started from the user prompt)
param([ValidateSet("Startup", "Check", "Now")][string]$Mode = "Check")

$Config = Get-Content -Path (Join-Path $PSScriptRoot "config.json") -Raw | ConvertFrom-Json
$Package = $Config.Package
$StateFile = Join-Path $PSScriptRoot "state.json"
$LogFile = Join-Path $PSScriptRoot "update.log"
function Write-Log([string]$Text) { Add-Content -Path $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $Mode, $Text) }

$ChocoRoot = $env:ChocolateyInstall
if (-not $ChocoRoot) { $ChocoRoot = Join-Path $env:ProgramData "chocolatey" }
$Choco = Join-Path $ChocoRoot "bin\choco.exe"
if (-not (Test-Path $Choco)) { Write-Log "choco.exe not found"; exit 1 }
$SourceArguments = @()
if ($Config.Source) { $SourceArguments = @("--source", $Config.Source) }

__COMMON__
__CHOCOCOMMON__

function Get-TargetVersion {
    # A released version is known; "latest" asks the source for the newest version of this one package
    # (choco 2 needs --exact to search for one id; the output is "id|version")
    if ($Config.Version) { return $Config.Version }
    $Line = & $Choco search $Package --exact --limit-output @SourceArguments 2>$null | Where-Object { $_ -like "$Package|*" } | Select-Object -First 1
    if ($Line) { return ($Line -split "\|")[1] }
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

# Chocolatey itself, at most once a day (no waiting when another installation runs, the next run does it)
if (Test-ChocolateyUpdateDue) {
    if (Enter-DeploymentLock) {
        try { Write-Log (Update-Chocolatey) } finally { Exit-DeploymentLock }
    }
}

switch ($Mode) {
    "Now" { exit (Invoke-Upgrade) }
    "Startup" { exit (Invoke-Upgrade) }
    "Check" {
        $Installed = Get-InstalledVersion
        $Target = Get-TargetVersion
        # "1.2.0" and "1.2" are the same version; latest: only something newer than the installed one counts
        $Pending = if (-not $Installed) { [bool]$Target }
        elseif ($Config.Version) { (Compare-PackageVersion $Target $Installed) -ne 0 }
        else { $Target -and (Compare-PackageVersion $Target $Installed) -gt 0 }
        if (-not $Pending) {
            Remove-Item -Path $StateFile -Force -ErrorAction SilentlyContinue
            exit 0
        }
        $State = $null
        if (Test-Path $StateFile) { try { $State = Get-Content -Path $StateFile -Raw | ConvertFrom-Json } catch { } }
        if (-not $State -or $State.Target -ne $Target) {
            $Now = Get-Date
            $State = [pscustomobject]@{
                Package     = $Package
                DisplayName = $Config.DisplayName
                Installed   = $Installed
                Target      = $Target
                FirstSeen   = $Now.ToString("o")
                Deadline    = $Now.AddHours([int]$Config.GraceHours).ToString("o")
            }
            $State | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
            Write-Log "update $Installed -> $Target available, installed automatically from $($State.Deadline)"
        }
        if ((Get-Date) -ge [datetime]$State.Deadline) {
            Write-Log "grace period is over"
            exit (Invoke-Upgrade)
        }
        exit 0
    }
}
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
$ChocoStamp = Join-Path $env:ProgramData "IntuneChocoUpdates\chocolatey-update.txt"
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
$Marker = Join-Path $env:ProgramData "IntuneChocoUpdates\$Package\policy.txt"
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
    $InstallScript = $InstallScript.Replace("__COMMON__", $Common).Replace("__CHOCOCOMMON__", $ChocoCommon)
    $UpdateScript = $UpdateScript.Replace("__COMMON__", $Common).Replace("__CHOCOCOMMON__", $ChocoCommon)
    $InstallScript = $InstallScript.Replace("__PACKAGE__", $ChocoName).Replace("__SOURCE__", (& $Quote $Policy.PackageSource))
    $InstallScript = $InstallScript.Replace("__VERSION__", (& $Quote $Policy.Version)).Replace("__MODE__", $Policy.UpdateMode).Replace("__GRACE__", [string][int]$Policy.GraceHours)
    $InstallScript = $InstallScript.Replace("__DISPLAYNAME__", (& $Quote $DisplayName)).Replace("__POLICY__", $Policy.Fingerprint)
    $InstallScript = $InstallScript.Replace("__DELAYMIN__", [string]$Policy.UpdateDelayMinMinutes).Replace("__DELAYMAX__", [string]$Policy.UpdateDelayMaxMinutes)
    $DetectionScript = $DetectionScript.Replace("__PACKAGE__", $ChocoName).Replace("__POLICY__", $Policy.Fingerprint)

    Set-Content -Path (Join-Path $SourcePath "install.ps1") -Value $InstallScript -Encoding ASCII
    Set-Content -Path (Join-Path $SourcePath "update.ps1") -Value $UpdateScript -Encoding ASCII
    Set-Content -Path (Join-Path $SourcePath "notify.ps1") -Value $NotifyScript -Encoding ASCII
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
                    -PackageSource $PackageSource -UpdateDelayMinMinutes $UpdateDelayMinMinutes -UpdateDelayMaxMinutes $UpdateDelayMaxMinutes
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

                Write-Host "Adding dependency for chocolatey to the created Application"
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
        "Startup" { "at every startup" }
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
        [ValidateRange(1, 2160)][int]$GraceHours
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

    $Policy = New-ChocoAppPolicy -Package $Package -Version $NewVersion -UpdateMode $NewMode -GraceHours $NewGrace -PackageSource $NewSource `
        -UpdateDelayMinMinutes $DelayMin -UpdateDelayMaxMinutes $DelayMax
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
        [ValidateSet("Chocolatey", "Winget")][string]$Source = "Chocolatey"
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
        -UpdateDelayMinMinutes $script:Settings.UpdateDelayMinMinutes -UpdateDelayMaxMinutes $script:Settings.UpdateDelayMaxMinutes

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
    Copy-Item -Path (Join-Path $SourcePath "install.ps1") -Destination (Join-Path $Project.SourcePath "choco-app.ps1") -Force
    foreach ($File in "update.ps1", "notify.ps1") { Copy-Item -Path (Join-Path $SourcePath $File) -Destination $Project.SourcePath -Force }

    Write-Host "Opening the Win32 Test Lab in Windows Sandbox for $($Info.Title): run Install, Detect, Uninstall there, then report the result"
    $Result = Start-Win32TestLab -Id $Id
    Write-Host "Test result: $($Result.Verdict). $($Result.Message)"
    [pscustomobject]@{ Package = $Package; Source = $Source; Verdict = $Result.Verdict; Message = $Result.Message; JobPath = $Result.JobPath }
}#Tests a package in Windows Sandbox (Win32 Test Lab of MSIX Sandbox Studio)

function install-chocolatey {

    Assert-IntuneChocoPrerequisites
    Assert-IntuneChocoConnection
    write-host "Starting Deploy Chocolatey as win32 app to intune"

    $Icon = "iVBORw0KGgoAAAANSUhEUgAAAOwAAADVCAMAAABjeOxDAAAAw1BMVEWAteP///+SRxaaxOlxmMpwl8mfUyZ5OBJ/uuuLu+WUwed5qNh2sOGTPQBmkcfq6uucTRu8jXaTQgC7oJNzKwCSRAp1odGBrdWBPRPx9fqtzuyEn72Glq+Mc3KLeX2IipuJhJGRTCGKf4jH3fJ5MwCDpMbR4/SNbGbo8fqPW0W1xtm41O6OYlKQVDaNaF+RUS2Otdlzf5+hSw
F4RDB2mMB2YWp1aHZ1cYaCMwB9ZGR4PBp3TUR3VFKvrra+h2nYxr27rKerWwlJAAAOuklEQVR4nOWdeXviyBGHm2u2YaTNRBlZa25sA2Ztw3rnSjbH5vt/quhA0EdVHyWBgNSTf/KsrOGlqqurq3/dsNb/kbHhcNX0ZzibsecgCAYvz01/jrMYaw0YYylw5/H2gVlrFbDcgoANV/dNf56TGkv/d7Qg6N9yRKewjwGTeNnNRnQK25JgbzmiM9gXjTYH
HvzqYP/+z18vyP60w95DsKl1hp2BaB3dBnz8e/zpMiyKPv/NDtsawrC/DYcAn2L95O3Th0uwdvsnJ9hn2LW/dToOtAO2/r1p0A85qxtsq4PBdlycy2eN07bbv/zkCgu7NoN1ou0vPzQbygWrI2yrj8I60Q7Ya5PO3bO6wq4g1xawTrQdPm2ONhuuPrAtgLWEdQzl8aeGQvnA6gz7CLj2AOsWys3MQWUI+8DqNaMI6xbK/QbmIJHVHXao0wqwKa1LKH
vNQXWEvcTqDgvUjEp92Gd9m/FRO267WRStx5HjswYTWd1hgZpRg7UbTzahw0eMw9084Xzm8uxJYPXCggCb4k6tBFG4HXGePTup7FsibN6Mqg7L+DgyhXLh1PLZTVVaKqxWWNBg01DeoQgHp5a2aAhWqxmJsKltwVCOw8XRqXtbVhy2ZFjVtXRYPtcZokhxavHkuBotGVatGemwjI/kgQs5df+kPaGdBlapGSvAZnPQceDCTi2ffK2SpOiwrfpgs3kl
tDi1tIVrIVIvrFxYVIPNhmOsp1/AkgqurQAr14wVYRlfLmxOLb+VJmDlFFUVNgdxeuiBTFsljGv1rLvxLTWS6bD3dSYoP9sRkxQdVumonhOWmqQuoILyN8ckFUfKKuMCamMKLVBhShZFYRhtJrONREuF1XpuZ4VlfI1EcpxhtjeT+Shd76cr/qgO2HoW7xXsTUtSce7N9XycMF6WJklYA2wtbZlKJiapzJ3Rbv0gYhbGpTimwQLbPeeG5aOwxHzbPo
yXKub+KSmOabBaU+b8sClHOji303E+ONGnpDgmwUKbPWeHTX2b5yDLQ2Ick2Cht54f1sn4PKoGC231XCqsFMcEWFhCcqmwYhwTYGEFycXCCnHsD4sISC4VVoxjf1hg2snsYmGFOPaGBTUG7JJhj3HsDYu982JhhTj2hQWli5ldLizfEWEx5eJFwz5ENFhY3ZbZ5cIe49gPFpl2MqsXlu+t2lvKl72RYJFpJ7PaYDlPluPZdDKZTKfzdE3DKiMf4tgP
FqyKC6sFNgUdT96yjkNpYbjYzpYVect9Xc8xi7+wBliezDYpZ1uxOAoX00q8ZT72hMVKihpg+WgdogKLKNyM6bRlHPvOs+iorbyLt9F9Kvk33NFx93HsC4vm40qwfLQJ7Vsa4dZhlw9+/4IEix0RqCQzSLYOqFkwt0c0Wj6NSLD3tcPymTmAJecSQ7mIY/8lHjL9UGEdNX0HWqJvdzRYZPqhir7MEjfd4oTCWsQxARaefohyPm+tT/RKcm3eUqd0F8
HVAA0WVrcZLRxTYHmbCAuu8yiwyRthVzneUFybxzGpSQ4IySmwCU3TFJJGbRbHtL2eOmB54iwkly2ak0btggoLTD++sHxpCuE4zpY88JcRb0lxPImo+7M6iy9sgoNGYbzZpqvZyfYNWAS12zsCax7HTcnmsfEah/G62FMuOhWjaVtL2DEJltFlBtr04wmrqwQK1O1Y6Uxwrp37CEmsaRxTYbXpxwsWEamF2yW0e66Obns6BvtX45AsDVIbyD6wsPww
2iF1r+rbyIaajB8m07EqheRkz1ZRksOarfAB/wPlUTPq+DVvYYXqFMUnfyfDrsjaRUiNF5uWqvKRHmMJlS2iynQQTuQHx3RYZfrxgAWSU7QxNSEkrUA7Whu+lpnYBlDL6AoS3GeaBBc6eRWa6wR50EYz9GElGcTyCon/44kMSxNXF/olxa8GX+V/I6mZ8GSsSRpDGfadDvtC86x+7Cqy1X/HranMdujREC3xKd/LVzIsTVwNBHFsLf8kWWb0gH412q
sV2I9/UGFp4mogiNv2GmGBAwhP6d+jHMbs7tsTDVatjt1gDxtqwgeyNwwlUSY68egzmpKg2N07EZYkrgZO/EYTK6uUn9CujDywi3crefuuR4Mliqv1GXZhQ5V1W/Ebmp422rvVuvKu+4UES1ri7RvznkEsnSTFn0/0oJkqz951hUHrIa4mweqfB3eU8BVtBcfipaKe+rSgueu+E2Bp4mooXTo4VvyKwiX6mAYbjnTYHgEW6Bw7wAILgIWDY4WvyJTN
1GPToV5V3vWEQXtacTUwYp0ahUJSM2UzLpdmIVB7pLDfn3xhIbc5eBZYADi0gIUaUA9MEVZcBMSAX3PYd19YmrhaXqcVH8mhuS/EA+Qs0Y77C+Eb1N/JYLufPWHBf8kOu1NZTWXu8c8Oudi+pfUaRnEcR+FuBv/3DPbLL16wRHE1UBW77FEdYO3rhXT5ON1utnNUWZPBHgbtKcXV0IGyyGHIllVgbF8vMKStKMG+e8FSxdVAo9hh4skmrOwvowifYZ
0tg+35wFLF1UBHUV2UILbchOFiWg2zsAy2+88nd1jsRRZYqPPksOAp/jZJtOPwJMFbDvvdHZYqruZAFGuFurPxZDYn7NLmsO/OsGRxtb4GcPesZpmYKCQoSXLYrjMsJvmywSqndvdj1tJUxKxQndhakoAVsPtBezpxNXhNF00dkdUORWB4/2EB+8MRliyuBnpPmRFg+Wix/978tRUF7LsjLJqerGMWZCVIQYRy37gsAK2A7TrCksXVUH4ybmQgqMmr
sAYCywzT2YI97L+e3GCp4mqoXewvBeHjWOyWA3HBk/F6s9tMwUVPCfvDERY/62KEBZMx8nlxVNGtbWgbhCeTbN2TSVDWBth3V1h0ojXD6mvZAtZhjXd4x0yWCuklSfqvHP4ZcP9oD9v9w7VcxHKUGVbvyOzHnatr+VJV6ur5SXI8lL5K2HzQOq16kE9jhsVuw3SsDHiy1rTmWhNWFkJC+aCE/eEMi+QoGqxTL5WzaQQ0YZWH1Ps2geZcCfvVGRZZ0B
Jh0wnEtjmbPOio2vJQ7w0AtXMJ26162zxtzKYWGWlhVD2PA3Ob/rIDbKY3cGy4QQpcC6y+wyZ8bjSSOR9tQVQt+rm+nw9srBxgf7jD+l/Kgc2z+08+ga6q4zyZ75AjMNq0o/dBoMXyAfarB6z/joD53umoPVNwU9LZK+zUNtBU5a/al2KaerrZLsjpLtKBy0Xh40eT0UGKmsnxNvi5vHasJVpg0x1aPh5hvz2dcBfPfsVcJjKePMzn88l2FxpI21CR
qX+XYEv6CPvuAeu/P+tyD3NcHJm1ien1c0y6ShcuVo6wX31g9RxlWbzrg4pqQBmiweqBrsCmg/Z0mgrj3OPHCu1yqmGMrKYE2G9PJ1TL2DKUMyu8TpJGSdxG6hQB9t0L1lMHxeuBVVW15dvFvdkQVbgKsL3PXgo3patqg93WMWjRRdJxGRAZdnEF2O6XU95cXfHudDNrXn1n+vFwMTUIl0XY736wj36q1OqsRlVyWonMHmZL4x3JIuz7KfXGpoWPI6
ttoW+9sUSE7fnBrvw8C3dTPVipO0MwbPeLF6z8IrumArvL1ZHVozfnBPvdB/bFV1xdybWg1KcS7LsHrNpTJYm+3Fkr3D+CwPY8YNXNSxehJhU1joh3GJhgf/6vM6y2yHMRahLn2mhHvXnEBNv71RlWg3HSG5NyVPhaC6kGe2f+GfcjrK7oc1OSEy7FryMNg7AfAyPtEVZ/kRts4gtLvk7GAZYZaQ+wwIaP4+kP40l3wK1bt9/IoMEaaUtYaCvP9RDT
MnZ3buy9W+0Ja6ItYaFNWuezeO43NoSvNWVhHJYF6A+3m36S1f1IaeL2k2/RopZCwgKL05p+bNfnZLTD7TnpGrzO0YrDorQFLHwhlNeZ99HOjBtFpjV4vbAYbQFbx+VXfIZt4xS/s1W/VzODYRm7R2HBPTzveyp4fh0fcB48zK+qqJFQMAwWpM1gMUWf/61BPJlvolzdUjg0vz5zcjJSZoCFaDNYTBtEuQ8q28Karze7dIzGu9fsJ0pqugoWMRwWoG
W4kJx+Yd2+c1TbnbcGM8DqtAwXkl/y/cYHu+uJJsP2dVj8Gtxrh9VoGTLtZHb1sCotw4XkNwDLBjIsfiX5LcDKtAw/D3ETsEFHGrNI+cRuA1aiveWppzCBlqF34N4KLBtK5SJGcRuwgRTGNS4Ezm/2Mfsow2IrgZuAFeuKHBaZfm4BVupZFJ0K+JTALcAOWxos8YD/BZgFNmgBsBVbqc2ZGVbMTkdY8JTA9cPK64ADLDT9XD2s2lE9bGwBS71rhw2G
LQQWmH6uHVbReIn7s/r0c+Ww+nYeXVx9GWaAHaisIqw2/Vw3LLDfI8a1Ov1cNayWnRRY2iWTzRruWZ21irj6IgyDBcUGVcTVl2CoZwHWauLqCzDUs49WWNplzk0anqCQLcujEa/pbtDI2VjNUFcNa5tnbypBMdYxwz7eFKyxNtYayFcOC21GH00tjq8dVpt+RFi1fXztsFplUdtP2DRk5rbMEIXVGjNXD6tWFlXvJG/aLH3jDgJLPSPQrNma5M8wrP
XX05KPF2i27Y8+CGu9uuFj7yKtK/4fYGNrBcHaLmCXdHMnNyIttBkNwFoORAy6Z2X1gRVpoc3oFx0W2rQ8wvZ752X1gu0dHwdlBvcaLPDUETY5M6on7JHWQUDSsmxZfjw7qyfsgRaEPU4/e1jwXrNBE6mJBFvSgrDHrQHrtWbnTk002D0tDHuYfmxX6/cbYfWHLZIyDHuoLCxqmX4jqCTYjBaBLRe2DJt3ctjzp+EKsD31jIBgAizyffTvfr4yu0O0
evuFLfY7AkEweLyX7S9XYKsOA3mLyoJB804QdFbg+a5rsOeXfqAD5wtbps07GWnTH7ii3T92VN68smDyvBOw4bWT7m01ZBJwNv0woR0TBLdCWtjz4+DIm1UWh0NMt+NTyQQHZ7D9zKVsiB4Uv3rbZ6x0YctWQdB/uV3SwtKMlXr0ng1vnnRvq+EQ1B7cqv0Pc9wIDT8ePVAAAAAASUVORK5CYII=" -replace "\s", ""

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
    $DetectionRule = Invoke-IntuneModule { New-IntuneWin32AppDetectionRuleFile -Existence -DetectionType exists -Path "C:\ProgramData\chocolatey" -FileOrFolder "choco.exe" }
    $RequirementRule = Invoke-IntuneModule { New-IntuneWin32AppRequirementRule -Architecture "AllWithARM64" -MinimumSupportedWindowsRelease W10_1607 }

    write-host "Starting uploading to intune"
    $APP = Invoke-IntuneModule { Add-IntuneWin32App -FilePath $AppPackage.Path -DisplayName "Chocolatey" -RequirementRule $RequirementRule -Notes $script:ChocoAppMarker -Description "Chocolatey Package Manager" -Publisher "www.linkedin.com/in/LuEd" -RestartBehavior suppress -InstallExperience system -Icon $Icon -InstallCommandLine "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1" -UninstallCommandLine "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1" -DetectionRule $DetectionRule }
    if ($null -eq $APP -or -not $APP.id) { throw "Chocolatey could not be created in Intune" }

    write-host "Make application installable for everyone in the company"
    Invoke-IntuneModule { Add-IntuneWin32AppAssignmentAllUsers -ID $APP.id -Intent available -Notification hideAll } | Out-Null

    write-host "chocolatey successfully deployed"
    return $APP.id

}# Deploys Chocolatey to Intune-Tenant

function get-ChocoWin32ID {

    $APP = Invoke-IntuneModule { Get-IntuneWin32App -DisplayName "Chocolatey" } | Where-Object { $_.displayName -eq "Chocolatey" -and $_.notes -like "*$($script:ChocoAppMarker)*" } | Select-Object -First 1
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
        }
    }

}#Lists the Win32 apps in the tenant that were created by this tool

function Remove-IntuneChocoApplication {
    param([Parameter(Mandatory = $true)][string]$Id)

    # Only apps this tool created (recognized by their notes) are removed, never anything else in the tenant
    $Apps = @(Get-IntuneChocoTenantApps)
    $App = $Apps | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $App) { throw "App $Id was not created by this tool or does not exist anymore, nothing was removed" }
    $Others = @($Apps | Where-Object { -not $_.IsChocolatey -and $_.Source -eq "Chocolatey" })
    if ($App.IsChocolatey -and $Others.Count -gt 0) {
        throw "Chocolatey is the dependency of $($Others.Count) app(s) created by this tool. Remove those first."
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
