# Tenant insight: import of existing Intune apps (#9) and install status / device logs (#10).
# Backend only. Everything is read from Intune (no local database). Every function takes a Graph context
# (New-InsightGraphContext), so another tenant can be read without touching the tool's own sign-in, and tests can
# hand in a fake. Notes are only read and written through the tool's own functions (Set-TenantInsightHooks).
#
# Graph endpoints (v1.0 where it exists, beta where needed):
#   beta  GET   /deviceAppManagement/mobileApps (win32LobApp, winGetApp)   list apps (winGetApp is beta only)
#   beta  PATCH /deviceAppManagement/mobileApps/{id}                        write notes (take over)
#   beta  GET   /deviceAppManagement/mobileApps/{id}/deviceStatuses         per device install status (not in v1.0)
#   beta  GET/POST/PATCH /deviceManagement/deviceHealthScripts (+ /assign, /deviceRunStates)   Remediations
#   v1.0  GET   /oauth2PermissionGrants                                      consent check (admin sign-in)

# Where the device scripts write the last result of one app (Save-LastResult in Get-DeviceScriptCommon of the core
# script), relative to %ProgramFiles%. {0} = package folder name. Chocolatey: package id, winget: id with every
# character outside A-Za-z0-9._- replaced by _. Fields: lastAttempt, action, status, exitCode, cause, installedVersion,
# targetVersion (Tests\Check-Insight.ps1 checks that the status script reads what Save-LastResult writes).
$script:LastResultFile = @{
    Chocolatey = 'IntuneChocoDeployment\Chocolatey\{0}\last-result.json'
    Winget     = 'IntuneChocoDeployment\Winget\{0}\last-result.json'
}
$script:StatusScriptName = 'IntuneChocoDeployment status'
$script:Hooks = @{}

# Delegated scopes per function (all Graph, least privileged; the tool's registration holds the ReadWrite variants)
$script:FunctionScopes = [ordered]@{
    'Get-InsightTenantApps'          = @('DeviceManagementApps.Read.All')
    'Set-InsightAppTakeOver'         = @('DeviceManagementApps.ReadWrite.All')
    'Get-InsightAppInstallStatus'    = @('DeviceManagementApps.Read.All')
    'Get-InsightStatusScriptState'   = @('DeviceManagementConfiguration.Read.All')
    'Set-InsightStatusScript'        = @('DeviceManagementConfiguration.ReadWrite.All')
    'Get-InsightDeviceRunStates'     = @('DeviceManagementConfiguration.Read.All', 'DeviceManagementManagedDevices.Read.All')
}

function Set-TenantInsightHooks {
    <# The tool's own functions (they live in the dot-sourced core script, not visible from this module). #>
    param(
        [Parameter(Mandatory)][hashtable]$Markers,   # Tool, Winget, ChocolateyApp
        [Parameter(Mandatory)][scriptblock]$ConvertFromNotes,
        [Parameter(Mandatory)][scriptblock]$ConvertToNotes,
        [Parameter(Mandatory)][scriptblock]$NewPolicy,
        [scriptblock]$NewChocoApp,
        [scriptblock]$NewWingetApp,
        [scriptblock]$SignIn
    )
    $script:Hooks = @{ Markers = $Markers; FromNotes = $ConvertFromNotes; ToNotes = $ConvertToNotes; NewPolicy = $NewPolicy
        NewChocoApp = $NewChocoApp; NewWingetApp = $NewWingetApp; SignIn = $SignIn }
}

# ---------------------------------------------------------------- Graph access

function New-InsightGraphContext {
    <# A Graph connection: from the tool's sign-in (default), an access token (other tenant) or a fake (tests). #>
    param([string]$AccessToken, [scriptblock]$Invoke, [scriptblock]$Download, [string]$Name = 'current tenant',
        [string]$GraphUrl = 'https://graph.microsoft.com')
    $Graph = $GraphUrl.TrimEnd('/')
    if (-not $Invoke) {
        $Invoke = {
            param([string]$Method, [string]$Path, $Body)
            $Token = if ($AccessToken) { $AccessToken } elseif ($Global:AccessToken) { [string]$Global:AccessToken.access_token } else { throw 'Not signed in.' }
            $Request = @{ Method = $Method; Uri = "$Graph$Path"; TimeoutSec = 120; ErrorAction = 'Stop'
                Headers = @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } }
            if ($null -ne $Body) { $Request.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 10 -Compress)) }
            for ($Try = 1; ; $Try++) {
                try { return Invoke-RestMethod @Request }
                catch {
                    $Code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
                    if (($Code -eq 429 -or $Code -eq 503) -and $Try -lt 5) { Start-Sleep -Seconds (5 * $Try); continue }
                    $Detail = try { ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch { $null }
                    throw "Graph $Method $Path failed ($Code): $(if ($Detail) { $Detail } else { $_.Exception.Message })"
                }
            }
        }.GetNewClosure()
    }
    if (-not $Download) { $Download = { param([string]$Url, [string]$OutFile) Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 600 } }
    [pscustomobject]@{ Name = $Name; Invoke = $Invoke; Download = $Download }
}

function Invoke-InsightGraph {
    <# One Graph call; -All follows @odata.nextLink and returns the items. Path starts with /v1.0 or /beta. #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Path, $Body, [switch]$All)
    $Result = & $Context.Invoke $Method $Path $Body
    if (-not $All) { return $Result }
    $Items = New-Object System.Collections.ArrayList
    for ($Page = 0; $Page -lt 200; $Page++) {
        foreach ($Item in @($Result.value)) { [void]$Items.Add($Item) }
        $Next = [string]$Result.'@odata.nextLink'
        if (-not $Next) { break }
        $Result = & $Context.Invoke 'GET' ($Next -replace '^https://[^/]+', '') $null
    }
    return $Items.ToArray()
}

# ---------------------------------------------------------------- Permissions

function Get-InsightRequiredScopes {
    <# Delegated scopes per function; without a name the list of all functions. #>
    param([string]$Function)
    if ($Function) { return @($script:FunctionScopes[$Function]) }
    $script:FunctionScopes.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Function = $_.Key; Scopes = $_.Value } }
}

function Get-InsightScopeSet {
    <# The scopes the tool's app registration should hold for insight (reading only). #>
    return @('DeviceManagementManagedDevices.Read.All')
}

function Get-InsightTokenScopes([string]$AccessToken) {
    # Scopes of a delegated token (claim scp), display only; Graph checks the signature
    $Part = $AccessToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
    while ($Part.Length % 4) { $Part += '=' }
    $Claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Part)) | ConvertFrom-Json
    return @([string]$Claims.scp -split ' ' | Where-Object { $_ })
}

function Test-InsightReadiness {
    <#
        Which functions work with the scopes in hand (token scopes, or the scopes of the admin consent grant) and
        which scope is missing. A scope counts as present when it or its ReadWrite variant is there.
        The UI offers "grant new permissions" (= run the app registration setup again, it updates registration
        and consent) when Missing is not empty.
    #>
    param([Parameter(Mandatory)][string[]]$GrantedScopes)
    $Have = @($GrantedScopes | ForEach-Object { $_.ToLower() -replace '^https://graph\.microsoft\.com/', '' })
    foreach ($Entry in $script:FunctionScopes.GetEnumerator()) {
        $Missing = @($Entry.Value | Where-Object {
                $Need = $_.ToLower()
                $Write = $Need -replace '\.read\.all$', '.readwrite.all'
                -not ($Have -contains $Need -or $Have -contains $Write)
            })
        [pscustomobject]@{ Function = $Entry.Key; Ready = ($Missing.Count -eq 0); Missing = $Missing }
    }
}

function Get-InsightGrantedScopes {
    <# Scopes of the admin consent of the tool's app registration (needs an admin sign-in, as in the setup). #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$ClientId)
    $Sp = (Invoke-InsightGraph $Context GET "/v1.0/servicePrincipals?`$filter=appId eq '$ClientId'&`$select=id").value | Select-Object -First 1
    if (-not $Sp) { return @() }
    $Grants = (Invoke-InsightGraph $Context GET "/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$($Sp.id)'").value
    return @($Grants | ForEach-Object { [string]$_.scope -split ' ' } | Where-Object { $_ } | Select-Object -Unique)
}

# ---------------------------------------------------------------- WP3: classification

function Get-InsightCommandInfo {
    <# Package manager, package id and pinned version from an install command line; $null for anything else. #>
    param([string]$CommandLine)
    if (-not $CommandLine) { return $null }
    $Version = if ($CommandLine -match '--version[=\s]+["'']?([0-9A-Za-z][0-9A-Za-z.+-]*)') { $Matches[1] } else { '' }
    if ($CommandLine -match '(?i)\bchoco(?:latey)?(?:\.exe)?["'']?\s+(?:install|upgrade)\s+((?:-\S+\s+)*)["'']?([A-Za-z0-9][A-Za-z0-9._+-]*)') {
        return [pscustomobject]@{ Source = 'Chocolatey'; Package = $Matches[2]; Version = $Version }
    }
    if ($CommandLine -match '(?i)\bwinget(?:\.exe)?["'']?\s+(?:install|upgrade)\b.*?(?:--id|-i)[=\s]+["'']?([A-Za-z0-9][A-Za-z0-9._+-]*)') {
        return [pscustomobject]@{ Source = 'Winget'; Package = $Matches[1]; Version = $Version }
    }
    return $null
}

function Get-InsightApps {
    # Raw Win32 and "Microsoft Store app (new)" objects of the tenant
    param([Parameter(Mandatory)]$Context)
    $Select = '$select=id,displayName,notes,installCommandLine,displayVersion,publisher,createdDateTime'
    $Win32 = Invoke-InsightGraph $Context GET "/beta/deviceAppManagement/mobileApps?`$filter=isof('microsoft.graph.win32LobApp')&$Select" -All
    $Store = @()
    try { $Store = Invoke-InsightGraph $Context GET "/beta/deviceAppManagement/mobileApps?`$filter=isof('microsoft.graph.winGetApp')&`$select=id,displayName,notes,packageIdentifier,createdDateTime" -All }
    catch { Write-Warning "Store apps (new) could not be read: $($_.Exception.Message)" }
    foreach ($App in @($Win32)) { $App | Add-Member -NotePropertyName AppType -NotePropertyValue 'Win32' -Force -PassThru }
    foreach ($App in @($Store)) { $App | Add-Member -NotePropertyName AppType -NotePropertyValue 'Store' -Force -PassThru }
}

function ConvertTo-InsightApp {
    # One raw app -> classified object (without the duplicate analysis)
    param($Raw, [string]$DefaultUpdateMode, [int]$DefaultGraceHours)
    $Markers = $script:Hooks.Markers
    $Notes = [string]$Raw.notes
    $Result = [ordered]@{
        Id = [string]$Raw.id; DisplayName = [string]$Raw.displayName; Kind = 'Other'; Source = ''; Package = $null; Version = ''
        UpdateMode = $DefaultUpdateMode; GraceHours = $DefaultGraceHours; PackageSource = ''; UseOfferedSource = $false; HasPolicy = $false
        Infrastructure = $false; Managed = $false; Created = $Raw.createdDateTime; AppVersion = $Raw.displayVersion
        Duplicate = $false; DuplicateOf = $null; ProposedAction = 'CannotManage'; Reason = ''
    }
    $IsInfra = $Notes -like "*$($Markers.ChocolateyApp)*" -and $Raw.displayName -eq 'Chocolatey'
    $IsWinget = $Notes -like "$($Markers.Winget)*"
    $IsChoco = $Notes -like "$($Markers.Tool)*"
    if ($IsInfra -or $IsWinget -or $IsChoco) {
        $Policy = & $script:Hooks.FromNotes $Notes
        $Result.Kind = if ($Raw.AppType -eq 'Store') { 'StoreApp' } else { 'ToolCreated' }
        $Result.Source = if ($IsWinget) { 'Winget' } else { 'Chocolatey' }
        $Result.Package = if ($IsInfra) { 'chocolatey' } else { $Policy.Package }
        $Result.Version = $Policy.Version; $Result.UpdateMode = $Policy.UpdateMode; $Result.GraceHours = $Policy.GraceHours
        $Result.PackageSource = [string]$Policy.PackageSource; $Result.HasPolicy = $Policy.HasPolicy
        $Result.Infrastructure = $IsInfra; $Result.Managed = $true; $Result.ProposedAction = 'Managed'
        $Result.Reason = if (-not $Result.Package) { 'created by this tool before the package id was stored in the notes' } else { 'created by this tool' }
        return [pscustomobject]$Result
    }
    if ($Raw.AppType -eq 'Store') {
        $Result.Kind = 'StoreApp'; $Result.Source = 'Store'; $Result.Package = [string]$Raw.packageIdentifier
        $Result.ProposedAction = 'KeepAsStoreApp'; $Result.Reason = 'Microsoft Store app (new): Intune keeps it up to date itself'
        return [pscustomobject]$Result
    }
    $Info = Get-InsightCommandInfo ([string]$Raw.installCommandLine)
    if ($Info) {
        $Result.Kind = if ($Info.Source -eq 'Chocolatey') { 'ChocolateyWin32' } else { 'WingetWin32' }
        $Result.Source = $Info.Source; $Result.Package = $Info.Package; $Result.Version = $Info.Version
        # A pinned version stays as it is; the others follow the default
        if ($Info.Version) { $Result.UpdateMode = 'Off' }
        $Result.ProposedAction = 'TakeOver'
        $Result.Reason = "Win32 app installing with $($Info.Source): the tool's notes are added, content and devices stay untouched"
    }
    else { $Result.Reason = 'installs with something else (own installer, MSI, script): cannot be managed by this tool' }
    return [pscustomobject]$Result
}

function Get-InsightClassification {
    <#
        Classifies the apps of a tenant (or fake input) and finds duplicates (same package of the same family,
        winget and Store count as one family). ProposedAction: Managed, TakeOver, KeepAsStoreApp, SkipDuplicate, CannotManage.
    #>
    param([Parameter(Mandatory)][object[]]$RawApps, [string]$DefaultUpdateMode = 'Startup', [int]$DefaultGraceHours = 48)
    $Apps = @($RawApps | ForEach-Object { ConvertTo-InsightApp -Raw $_ -DefaultUpdateMode $DefaultUpdateMode -DefaultGraceHours $DefaultGraceHours })
    $Groups = $Apps | Where-Object { $_.Package -and -not $_.Infrastructure } | Group-Object { "$(if ($_.Source -eq 'Chocolatey') { 'choco' } else { 'winget' }):$($_.Package.ToLower())" }
    foreach ($Group in @($Groups | Where-Object Count -gt 1)) {
        # Winner: the one this tool manages, then a Store app, then the oldest
        $Order = @($Group.Group | Sort-Object @{ Expression = { if ($_.Managed) { 0 } elseif ($_.Source -eq 'Store') { 1 } else { 2 } } }, { [string]$_.Created })
        foreach ($Other in $Order | Select-Object -Skip 1) {
            $Other.Duplicate = $true; $Other.DuplicateOf = $Order[0].Id
            if ($Other.ProposedAction -ne 'Managed') { $Other.ProposedAction = 'SkipDuplicate' }
            $Other.Reason = "same product as '$($Order[0].DisplayName)'"
        }
        if ($Order[0].ProposedAction -eq 'KeepAsStoreApp') { $Order[0].Reason += ' (also installed as Win32 app)' }
    }
    return , $Apps
}

function Get-InsightTenantApps {
    <# Reads and classifies the apps of a tenant. Scopes: DeviceManagementApps.Read.All. #>
    param([Parameter(Mandatory)]$Context, [string]$DefaultUpdateMode = 'Startup', [int]$DefaultGraceHours = 48)
    Get-InsightClassification -RawApps @(Get-InsightApps $Context) -DefaultUpdateMode $DefaultUpdateMode -DefaultGraceHours $DefaultGraceHours
}

function Set-InsightAppTakeOver {
    <#
        Take over: writes the tool's notes (and with them the package id) to the selected apps. Content, scripts,
        detection and assignments stay as they are; devices notice nothing. The new scripts follow at the next
        settings change of the app. Scopes: DeviceManagementApps.ReadWrite.All.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][object[]]$Apps)
    foreach ($App in $Apps) {
        if ($App.ProposedAction -ne 'TakeOver') { [pscustomobject]@{ Id = $App.Id; DisplayName = $App.DisplayName; Done = $false; Message = "not importable ($($App.ProposedAction))" }; continue }
        $Policy = & $script:Hooks.NewPolicy -Package $App.Package -Version $App.Version -UpdateMode $App.UpdateMode -GraceHours $App.GraceHours -PackageSource $App.PackageSource
        $Marker = if ($App.Source -eq 'Winget') { $script:Hooks.Markers.Winget } else { $script:Hooks.Markers.Tool }
        $Notes = & $script:Hooks.ToNotes -Policy $Policy -Marker $Marker
        if (-not $PSCmdlet.ShouldProcess($App.DisplayName, "write notes: $Notes")) { continue }
        try {
            Invoke-InsightGraph $Context PATCH "/beta/deviceAppManagement/mobileApps/$($App.Id)" @{ '@odata.type' = '#microsoft.graph.win32LobApp'; notes = $Notes } | Out-Null
            [pscustomobject]@{ Id = $App.Id; DisplayName = $App.DisplayName; Done = $true; Message = $Notes }
        }
        catch { [pscustomobject]@{ Id = $App.Id; DisplayName = $App.DisplayName; Done = $false; Message = $_.Exception.Message } }
    }
}

function Test-InsightFeedUrl {
    <#
        A package source offered by an import (export file, notes of another tenant) is only ever used as an absolute
        https URL without user info, query or fragment: no attacker feed with credentials, no UNC or file path.
    #>
    param([string]$Url)
    $Uri = $null
    return ([uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$Uri) -and $Uri.Scheme -eq 'https' -and -not $Uri.UserInfo -and -not $Uri.Query -and -not $Uri.Fragment)
}

function Remove-InsightUserInfo([string]$Url) {
    # No credentials or tokens in an export: drop user info, query and fragment of a feed URL
    if (-not $Url) { return '' }
    try { $Uri = [uri]$Url; return ('{0}://{1}{2}' -f $Uri.Scheme, $Uri.Authority, $Uri.AbsolutePath).TrimEnd('/') } catch { return '' }
}

function Export-InsightManagedApps {
    <# Writes the apps this tool manages with their policy to a JSON file: no secrets, no tenant or app ids. #>
    param([Parameter(Mandatory)][object[]]$Apps, [Parameter(Mandatory)][string]$Path)
    $Items = @($Apps | Where-Object { $_.Managed -and -not $_.Infrastructure -and $_.Package -and $_.Source -in 'Chocolatey', 'Winget' } | ForEach-Object {
            [ordered]@{ displayName = $_.DisplayName; source = $_.Source; package = $_.Package; version = $_.Version
                updateMode = $_.UpdateMode; graceHours = $_.GraceHours; packageSource = (Remove-InsightUserInfo $_.PackageSource) }
        })
    $Document = [ordered]@{ format = 'IntuneChocoDeployment.Export'; version = 1; exported = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd'); apps = $Items }
    $Json = $Document | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($Path, $Json, (New-Object Text.UTF8Encoding($false)))
    return $Items.Count
}

function Read-InsightExportFile {
    <#
        Reads an export file into candidates (ProposedAction Recreate). PackageSource is what the file offers; it is
        only used when UseOfferedSource is set after an explicit confirmation per app (see New-InsightRecreatedApps).
    #>
    param([Parameter(Mandatory)][string]$Path)
    $Document = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    if ($Document.format -ne 'IntuneChocoDeployment.Export' -or [int]$Document.version -gt 1) { throw 'This is not an export file of this tool (or from a newer version).' }
    foreach ($Item in @($Document.apps)) {
        if ($Item.source -notin 'Chocolatey', 'Winget' -or $Item.package -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') { throw "Invalid entry in the export file: $($Item.package)" }
        [pscustomobject]@{ Id = $null; DisplayName = [string]$Item.displayName; Kind = 'Export'; Source = [string]$Item.source; Package = [string]$Item.package
            Version = [string]$Item.version; UpdateMode = [string]$Item.updateMode; GraceHours = [int]$Item.graceHours; PackageSource = [string]$Item.packageSource
            UseOfferedSource = $false; Managed = $false; Infrastructure = $false; Duplicate = $false; ProposedAction = 'Recreate'; Reason = 'from export file' }
    }
}

function Get-InsightOtherTenantContext {
    <# Separate read-only sign-in to another tenant (own app registration there); the tool's sign-in stays untouched. #>
    param([Parameter(Mandatory)][string]$TenantID, [Parameter(Mandatory)][string]$ClientID, [string]$Authority = 'https://login.microsoftonline.com', [scriptblock]$UrlHandler, [scriptblock]$ShouldCancel)
    if (-not $script:Hooks.SignIn) { throw 'No sign-in function was handed to the insight module.' }
    $Scope = 'https://graph.microsoft.com/DeviceManagementApps.Read.All offline_access openid profile'
    $Token = & $script:Hooks.SignIn -TenantID $TenantID -ClientID $ClientID -Scope $Scope -Authority $Authority -UrlHandler $UrlHandler -ShouldCancel $ShouldCancel
    New-InsightGraphContext -AccessToken ([string]$Token.access_token) -Name $TenantID
}

function New-InsightRecreatedApps {
    <#
        Recreates selected apps (from another tenant or an export file) in the current tenant through the tool's
        deploy functions. Apps already managed here (same package) are skipped. Assignment defaults to None.
        Chocolatey apps use the package source of this tool's settings. The source the import offers (PackageSource)
        is used only when the caller set UseOfferedSource after asking for this app, and only when it is an https URL
        without user info and query (Test-InsightFeedUrl); otherwise the app is not created.
    #>
    param([Parameter(Mandatory)][object[]]$Candidates, [object[]]$ExistingApps = @(), [ValidateSet('Available', 'Required', 'None')][string]$Assignment = 'None')
    foreach ($App in $Candidates) {
        $Exists = @($ExistingApps | Where-Object { $_.Managed -and $_.Package -and $_.Package -eq $App.Package -and $_.Source -eq $App.Source }).Count -gt 0
        if ($Exists) { [pscustomobject]@{ Package = $App.Package; Done = $false; Message = 'already managed in this tenant' }; continue }
        $UseOffered = $App.Source -eq 'Chocolatey' -and [string]$App.PackageSource -and $App.PSObject.Properties['UseOfferedSource'] -and $App.UseOfferedSource -eq $true
        if ($UseOffered -and -not (Test-InsightFeedUrl ([string]$App.PackageSource))) {
            [pscustomobject]@{ Package = $App.Package; Done = $false; Message = 'package source refused: only https URLs without user name, password or query are taken from an import' }; continue
        }
        try {
            $Args = @{ Assignment = $Assignment; UpdateMode = $App.UpdateMode; GraceHours = $App.GraceHours; Version = $(if ($App.Version) { $App.Version } else { 'latest' }); NoIconPrompt = $true }
            if ($App.Source -eq 'Winget') { & $script:Hooks.NewWingetApp -WingetId $App.Package @Args | Out-Null }
            elseif ($UseOffered) { & $script:Hooks.NewChocoApp -ChocoName $App.Package -PackageSource ([string]$App.PackageSource) @Args | Out-Null }
            else { & $script:Hooks.NewChocoApp -ChocoName $App.Package @Args | Out-Null }
            [pscustomobject]@{ Package = $App.Package; Done = $true; Message = 'created' }
        }
        catch { [pscustomobject]@{ Package = $App.Package; Done = $false; Message = $_.Exception.Message } }
    }
}

# ---------------------------------------------------------------- WP4: error codes and install status

function ConvertTo-InsightHexCode($Code) {
    if ($null -eq $Code -or "$Code" -eq '') { return $null }
    try {
        $Number = if ("$Code" -match '^0x[0-9a-fA-F]+$') { [Convert]::ToInt64("$Code".Substring(2), 16) } else { [int64]$Code }
        if ($Number -lt 0) { $Number += 4294967296 }
        return $Number
    }
    catch { return $null }
}

function Get-InsightErrorCause {
    <#
        Short cause for an exit or error code (Intune/IME, Windows installer, Chocolatey, winget). Mapping from the
        documented Windows and winget return codes plus common Intune codes; unknown codes return the hex value only.
        Source: winget return codes (github.com/microsoft/winget-cli, doc/windows/package-manager/winget/returnCodes.md),
        Windows installer error codes (learn.microsoft.com, msi/error-codes). Not verified against a live tenant.
    #>
    param($Code)
    $Number = ConvertTo-InsightHexCode $Code
    if ($null -eq $Number) { return $null }
    $Hex = '0x{0:X8}' -f $Number
    $Table = @{
        '0' = 'success'
        '1' = 'the installer or choco reported a general error (see the device log)'
        '641' = 'fatal error during installation'
        '1601' = 'Windows Installer service not accessible'
        '1603' = 'fatal error during installation'
        '1618' = 'another installation is already running, retry later'
        '1619' = 'installer package could not be opened'
        '1625' = 'installation blocked by policy'
        '1638' = 'another version of the product is already installed'
        '1641' = 'success, the installer started a restart'
        '3010' = 'success, a restart is required'
        '80004005' = 'unspecified error (0x80004005)'
        '80070002' = 'file not found (0x80070002)'
        '80070005' = 'access denied (0x80070005)'
        '80070643' = 'fatal error during installation (0x80070643)'
        '80070652' = 'another installation is in progress (0x80070652)'
        '87D1041C' = 'installed, but the detection rule does not find the app (0x87D1041C)'
        '8A150001' = 'winget: internal error (0x8A150001)'
        '8A150002' = 'winget: invalid command line arguments (0x8A150002)'
        '8A150008' = 'winget: download of the installer failed (0x8A150008)'
        '8A150010' = 'winget: no applicable installer for this device (0x8A150010)'
        '8A150011' = 'winget: installer hash does not match (0x8A150011)'
        '8A150014' = 'winget: no package found (0x8A150014)'
    }
    $Table.Remove('641')
    $Known = @{}
    foreach ($Key in $Table.Keys) {
        # 0..3999 are decimal exit codes, the rest hexadecimal
        $Value = if ($Key.Length -le 4) { [int64]$Key } else { [Convert]::ToInt64($Key, 16) }
        $Known[$Value] = $Table[$Key]
    }
    if ($Known.ContainsKey([int64]$Number)) { return $Known[[int64]$Number] }
    if ($Hex -like '0x8A15*') { return "winget error $Hex (see the winget return codes)" }
    if ($Hex -like '0x87D*') { return "Intune Management Extension error $Hex" }
    if ($Number -eq 4294967295) { return 'the installer or choco failed (-1)' }
    return "error $Hex"
}

function Get-InsightAppInstallStatus {
    <#
        Device install status of one app (beta: GET /deviceAppManagement/mobileApps/{id}/deviceStatuses; the v1.0
        documentation has no such list). Counts and one row per device. Scopes: DeviceManagementApps.Read.All.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$AppId, [datetime]$Now = (Get-Date), [int]$StaleDays = 7)
    $Rows = @(Invoke-InsightGraph $Context GET "/beta/deviceAppManagement/mobileApps/$AppId/deviceStatuses" -All | ForEach-Object {
            $Last = try { [datetime]$_.lastSyncDateTime } catch { $null }
            $Stale = ($null -eq $Last) -or ($Last.ToUniversalTime() -lt $Now.ToUniversalTime().AddDays(-$StaleDays))
            $Code = ConvertTo-InsightHexCode $_.errorCode
            [pscustomobject]@{
                DeviceId = [string]$_.deviceId; DeviceName = [string]$_.deviceName
                User = $(if ($_.userPrincipalName) { [string]$_.userPrincipalName } else { [string]$_.userName })
                State = [string]$_.installState; StateDetail = [string]$_.installStateDetail; Version = [string]$_.displayVersion
                ErrorCode = $(if ($Code) { '0x{0:X8}' -f $Code } else { $null })
                Cause = $(if ($Code) { Get-InsightErrorCause $Code } else { $null })
                LastReport = $Last; NotReported = $Stale
                LastResult = $null
            }
        })
    [pscustomobject]@{
        AppId = $AppId; Endpoint = 'beta'
        Installed = @($Rows | Where-Object State -eq 'installed').Count
        Failed = @($Rows | Where-Object { $_.State -in 'failed', 'uninstallFailed' }).Count
        Pending = @($Rows | Where-Object State -eq 'pendingInstall').Count
        NotReported7Days = @($Rows | Where-Object NotReported).Count
        Devices = $Rows
    }
}

# ---------------------------------------------------------------- WP4: status script (Remediations)

function Get-InsightStatusScriptText {
    <#
        The detection-only device health script. It reads the last-result.json of all managed apps and prints one
        compact JSON line below Intune's output limit of 2,048 characters (Microsoft Learn, "Use Remediations to
        detect and fix support issues": "The maximum allowed output size limit is 2,048 characters"). The script keeps
        a margin (1,900); failed apps come first with details, the others as "package=version", the rest is counted
        in x. Always exit 0 (a detection that only reports). Plain ASCII, Windows PowerShell 5.1.
    #>
    $Choco = $script:LastResultFile.Chocolatey -replace '\\\{0\}\\last-result\.json$', ''
    $Winget = $script:LastResultFile.Winget -replace '\\\{0\}\\last-result\.json$', ''
    $Text = @'
# IntuneChocoDeployment status: detection only, reports the last result of every managed app (runs as SYSTEM).
param(
    [string]$ChocoRoot = (Join-Path $(if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }) '__CHOCO__'),
    [string]$WingetRoot = (Join-Path $(if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }) '__WINGET__'),
    [int]$Limit = 1900
)
$ErrorActionPreference = 'SilentlyContinue'
$Failed = New-Object System.Collections.ArrayList
$Good = New-Object System.Collections.ArrayList
$Count = 0
foreach ($Entry in @(@('c', $ChocoRoot), @('w', $WingetRoot))) {
    if (-not (Test-Path $Entry[1])) { continue }
    foreach ($Dir in @(Get-ChildItem -LiteralPath $Entry[1] -Directory | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })) {
        $File = Join-Path $Dir.FullName 'last-result.json'
        if (-not (Test-Path $File)) { continue }
        $Count++
        $R = $null
        try { $R = Get-Content $File -Raw | ConvertFrom-Json } catch { }
        if (-not $R) { [void]$Failed.Add([ordered]@{ p = $Dir.Name; s = $Entry[0]; c = 'unreadable result file' }); continue }
        $Time = ''
        try { $Time = ([datetime]$R.lastAttempt).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm') } catch { }
        $Cause = [string]$R.cause
        if ($Cause.Length -gt 48) { $Cause = $Cause.Substring(0, 48) }
        $Code = 0
        try { $Code = [int]$R.exitCode } catch { }
        if (($Code -eq 0 -or $Code -eq 3010 -or $Code -eq 1641) -and [string]$R.status -ne 'failed') { [void]$Good.Add(('{0}={1}' -f $Dir.Name, $R.installedVersion)) }
        else { [void]$Failed.Add([ordered]@{ p = $Dir.Name; s = $Entry[0]; t = $Time; a = [string]$R.action; e = $Code; c = $Cause; v = [string]$R.installedVersion; g = [string]$R.targetVersion }) }
    }
}
$F = New-Object System.Collections.ArrayList
$G = New-Object System.Collections.ArrayList
$Skipped = 0
$Json = ''
foreach ($Item in @($Failed.ToArray() + $Good.ToArray())) {
    $Trial = New-Object System.Collections.ArrayList
    $Trial.AddRange($F); $TrialG = New-Object System.Collections.ArrayList; $TrialG.AddRange($G)
    if ($Item -is [string]) { [void]$TrialG.Add($Item) } else { [void]$Trial.Add($Item) }
    $Candidate = ConvertTo-Json -Compress -Depth 4 ([ordered]@{ v = 1; n = $Count; f = @($Trial.ToArray()); o = @($TrialG.ToArray()); x = $Skipped })
    if ($Candidate.Length -le $Limit) { $F = $Trial; $G = $TrialG; $Json = $Candidate } else { $Skipped++ }
}
$Final = ConvertTo-Json -Compress -Depth 4 ([ordered]@{ v = 1; n = $Count; f = @($F.ToArray()); o = @($G.ToArray()); x = $Skipped })
Write-Output $Final
exit 0
'@
    return $Text.Replace('__CHOCO__', $Choco).Replace('__WINGET__', $Winget)
}

function Test-InsightRemediationsAvailable {
    <#
        Remediations need Windows Enterprise E3/E5 (Microsoft 365 F3/E3/E5), Education A3/A5 or Windows VDA per user
        (Microsoft Learn, "Use Remediations"). The licence is per user of the device, so only Graph's refusal can be
        detected here; the result says why. Scopes: DeviceManagementConfiguration.Read.All.
    #>
    param([Parameter(Mandatory)]$Context)
    try {
        Invoke-InsightGraph $Context GET '/beta/deviceManagement/deviceHealthScripts?$top=1&$select=id' | Out-Null
        [pscustomobject]@{ Available = $true; Reason = 'Graph accepts the request; devices still need Windows Enterprise E3/E5 (or A3/A5, VDA) licenses' }
    }
    catch {
        $Text = $_.Exception.Message
        $Reason = if ($Text -match '(?i)licen|subscription|not enabled|forbidden|\b403\b') { "Remediations are not available in this tenant ($Text)" } else { "Remediations could not be queried ($Text)" }
        [pscustomobject]@{ Available = $false; Reason = $Reason }
    }
}

function Get-InsightStatusScriptState {
    # The existing status script package of this tool, or $null
    param([Parameter(Mandatory)]$Context)
    $All = Invoke-InsightGraph $Context GET '/beta/deviceManagement/deviceHealthScripts?$select=id,displayName,version,lastModifiedDateTime' -All
    @($All | Where-Object { $_.displayName -eq $script:StatusScriptName }) | Select-Object -First 1
}

function Set-InsightStatusScript {
    <#
        Creates or updates the "IntuneChocoDeployment status" script package (detection only, system context,
        64 bit) and assigns it to all devices hourly (deviceHealthScriptHourlySchedule, interval 1).
        Scopes: DeviceManagementConfiguration.ReadWrite.All. Degrades to Created = $false when not available.
    #>
    param([Parameter(Mandatory)]$Context)
    $Availability = Test-InsightRemediationsAvailable $Context
    if (-not $Availability.Available) { return [pscustomobject]@{ Created = $false; Id = $null; Message = $Availability.Reason } }
    $Bytes = (New-Object Text.UTF8Encoding($false)).GetBytes((Get-InsightStatusScriptText))
    $Body = @{
        displayName = $script:StatusScriptName; description = 'Reports the last install and update result of the apps managed by IntuneChocoDeployment (detection only).'
        publisher = 'IntuneChocoDeployment'; runAs32Bit = $false; runAsAccount = 'system'; enforceSignatureCheck = $false
        detectionScriptContent = [Convert]::ToBase64String($Bytes)
    }
    $Existing = Get-InsightStatusScriptState $Context
    if ($Existing) { Invoke-InsightGraph $Context PATCH "/beta/deviceManagement/deviceHealthScripts/$($Existing.id)" $Body | Out-Null; $Id = $Existing.id }
    else { $Id = (Invoke-InsightGraph $Context POST '/beta/deviceManagement/deviceHealthScripts' $Body).id }
    $Assign = @{ deviceHealthScriptAssignments = @(@{
                target = @{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' }
                runRemediationScript = $false
                runSchedule = @{ '@odata.type' = '#microsoft.graph.deviceHealthScriptHourlySchedule'; interval = 1 }
            }) }
    Invoke-InsightGraph $Context POST "/beta/deviceManagement/deviceHealthScripts/$Id/assign" $Assign | Out-Null
    [pscustomobject]@{ Created = $true; Id = $Id; Message = $(if ($Existing) { 'updated' } else { 'created' }) + ', assigned to all devices, hourly' }
}

function Get-InsightDeviceRunStates {
    <#
        Reads what the devices reported (beta: deviceHealthScripts/{id}/deviceRunStates, with the managed device).
        Returns per device the parsed apps. Note: Intune clients report recurring scripts only when the output
        changed, otherwise every 7 days. Scopes: DeviceManagementConfiguration.Read.All, DeviceManagementManagedDevices.Read.All.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$ScriptId)
    $States = Invoke-InsightGraph $Context GET "/beta/deviceManagement/deviceHealthScripts/$ScriptId/deviceRunStates?`$expand=managedDevice(`$select=id,deviceName,userPrincipalName)" -All
    foreach ($State in $States) { ConvertFrom-InsightRunState $State }
}

function ConvertFrom-InsightRunState {
    param($State)
    $Report = $null
    try { $Report = [string]$State.preRemediationDetectionScriptOutput | ConvertFrom-Json } catch { }
    $Apps = New-Object System.Collections.ArrayList
    foreach ($F in @($Report.f)) {
        if (-not $F) { continue }
        [void]$Apps.Add([pscustomobject]@{ Package = [string]$F.p; Source = $(if ($F.s -eq 'w') { 'Winget' } else { 'Chocolatey' }); LastAttempt = [string]$F.t
                Action = [string]$F.a; ExitCode = $F.e; Cause = $(if ($F.c) { [string]$F.c } else { Get-InsightErrorCause $F.e }); InstalledVersion = [string]$F.v; TargetVersion = [string]$F.g; Ok = $false })
    }
    foreach ($O in @($Report.o)) {
        if (-not $O) { continue }
        $Name, $Version = ([string]$O -split '=', 2)
        [void]$Apps.Add([pscustomobject]@{ Package = $Name; Source = $null; LastAttempt = $null; Action = $null; ExitCode = 0; Cause = $null; InstalledVersion = $Version; TargetVersion = $null; Ok = $true })
    }
    [pscustomobject]@{
        DeviceName = [string]$State.managedDevice.deviceName; User = [string]$State.managedDevice.userPrincipalName
        ManagedDeviceId = [string]$State.managedDevice.id; DetectionState = [string]$State.detectionState
        Updated = $State.lastStateUpdateDateTime; Truncated = [int]$Report.x; Apps = @($Apps)
    }
}

function Merge-InsightStatus {
    <# Adds the device's last result (from the status script) to the install status rows of one package. #>
    param([Parameter(Mandatory)]$InstallStatus, [Parameter(Mandatory)][string]$Package, [object[]]$RunStates = @())
    foreach ($Row in $InstallStatus.Devices) {
        $Run = @($RunStates | Where-Object { $_.DeviceName -and $_.DeviceName -ieq $Row.DeviceName }) | Select-Object -First 1
        $Row.LastResult = $null
        if ($Run) {
            $Hit = @($Run.Apps | Where-Object { $_.Package -ieq $Package }) | Select-Object -First 1
            if ($Hit) { $Row.LastResult = $Hit }
        }
    }
    return $InstallStatus
}

# ---------------------------------------------------------------- WP4: diagnostics

function Get-InsightDiagnosticsInfo {
    <#
        Collect diagnostics cannot be done through Microsoft Graph (Microsoft Learn, "Device Action: Collect
        Diagnostics": "Diagnostics can't be collected or downloaded by calling Microsoft Graph directly. Use the
        Intune admin center"). So the tool only points the user to the device page; the collected set includes
        %ProgramData%\Microsoft\IntuneManagementExtension\Logs\*.* (same page). Expand-InsightLogs reads the zip.
    #>
    param([Parameter(Mandatory)][string]$ManagedDeviceId, [string]$Package)
    $Log = if ($Package) { "IntuneChocoDeployment-$($Package -replace '[^A-Za-z0-9._-]', '_').log" } else { 'IntuneChocoDeployment-<package>.log' }
    [pscustomobject]@{
        Url  = "https://intune.microsoft.com/#view/Microsoft_Intune_Devices/DeviceSettingsMenuBlade/~/overview/mdmDeviceId/$ManagedDeviceId"
        Hint = "Open the device, choose Collect diagnostics, then Monitor > Device diagnostics > Download. Our log is $Log in the folder IntuneManagementExtension\Logs of the package."
    }
}

function Expand-InsightLogs {
    <# For a downloaded diagnostics zip: extracts IntuneChocoDeployment-*.log (any folder level, flat by file name) and returns the paths. #>
    param([Parameter(Mandatory)][string]$ZipPath, [Parameter(Mandatory)][string]$OutDir)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $null = New-Item -ItemType Directory -Path $OutDir -Force
    $Archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($Entry in $Archive.Entries) {
            $Name = [IO.Path]::GetFileName($Entry.FullName)
            if ($Name -notlike 'IntuneChocoDeployment-*.log' -or $Name -notmatch '^[A-Za-z0-9._-]+$') { continue }
            $Target = Join-Path $OutDir $Name
            [IO.Compression.ZipFileExtensions]::ExtractToFile($Entry, $Target, $true)
            $Target
        }
    }
    finally { $Archive.Dispose() }
}

Export-ModuleMember -Function Set-TenantInsightHooks, New-InsightGraphContext, Invoke-InsightGraph, Get-InsightRequiredScopes, Get-InsightScopeSet,
Get-InsightTokenScopes, Test-InsightReadiness, Get-InsightGrantedScopes, Get-InsightCommandInfo, Get-InsightClassification, Get-InsightTenantApps,
Set-InsightAppTakeOver, Export-InsightManagedApps, Read-InsightExportFile, Test-InsightFeedUrl, Get-InsightOtherTenantContext, New-InsightRecreatedApps,
Get-InsightErrorCause, Get-InsightAppInstallStatus, Get-InsightStatusScriptText, Test-InsightRemediationsAvailable, Get-InsightStatusScriptState,
Set-InsightStatusScript, Get-InsightDeviceRunStates, ConvertFrom-InsightRunState, Merge-InsightStatus, Get-InsightDiagnosticsInfo, Expand-InsightLogs
