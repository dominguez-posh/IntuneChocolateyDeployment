<#
    Starts the graphical interface of the Intune Chocolatey deployment in the browser.

        .\Start-IntuneChocoGui.ps1

    The interface is served on http://localhost with a random port and is only reachable from this machine.
    Every API call needs the session token that is handed to the browser on start.
    Close it with the Quit button or Ctrl+C in this window.
#>
[CmdletBinding()]
param(
    [int]$Port = 0,
    [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"
$CorePath = Join-Path $PSScriptRoot "ChocoIntuneDeployment-Main.ps1"
$GuiRoot = Join-Path $PSScriptRoot "gui"
. $CorePath

$GuiVersion = "2.0.0"
$MetaCachePath = Join-Path $script:WorkRoot "feedcache.json"
$MetaCacheHours = 24

#region Shared state between the HTTP loop and the background runspaces

$Shared = [hashtable]::Synchronized(@{
    Auth       = $null
    Jobs       = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    Meta       = [hashtable]::Synchronized(@{})
    TenantApps = $null
})
$Tasks = @{}
$JobCounter = 0
$MetaDirty = $false

# Background work: up to 4 parallel helpers (sign-in, feed lookups), deployments strictly one after another
$Pool = [runspacefactory]::CreateRunspacePool(1, 4)
$Pool.Open()
$DeployPool = [runspacefactory]::CreateRunspacePool(1, 1)
$DeployPool.Open()

# Runs inside a pool runspace: loads the core script, takes over the sign-in, captures every stream into the job log
$TaskBody = {
    param($CorePath, $Shared, $Job, $Work, $WorkArguments)
    $ErrorActionPreference = "Stop"
    $ProgressPreference = "SilentlyContinue"
    $Job.Status = "running"
    $Job.Started = (Get-Date).ToString("o")
    $Output = New-Object System.Collections.ArrayList

    function Add-JobLog([string]$Level, [string]$Text) {
        if ($Text) { [void]$Job.Log.Add(@{ time = (Get-Date).ToString("HH:mm:ss"); level = $Level; text = $Text }) }
    }

    try {
        . $CorePath
        if ($Shared.Auth) { Set-IntuneChocoAuthState $Shared.Auth }
        $WorkScript = [scriptblock]::Create($Work)
        & $WorkScript @WorkArguments *>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { Add-JobLog "error" $_.Exception.Message; $Job.HadError = $true }
            elseif ($_ -is [System.Management.Automation.WarningRecord]) { Add-JobLog "warning" $_.Message }
            elseif ($_ -is [System.Management.Automation.InformationRecord]) { Add-JobLog "info" ([string]$_.MessageData) }
            elseif ($_ -is [System.Management.Automation.VerboseRecord] -or $_ -is [System.Management.Automation.DebugRecord]) { }
            else { [void]$Output.Add($_) }
        }
        # A token refreshed during a long run is handed back to everyone else
        if ($Shared.Auth -and $Global:AccessToken) { $Shared.Auth = Get-IntuneChocoAuthState }
    }
    catch {
        Add-JobLog "error" $_.Exception.Message
        $Job.HadError = $true
    }

    $Job.Result = @($Output)
    if ($Job.HadError) { $Job.Status = "failed" }
    elseif ($Job.Kind -eq "deploy" -and $Output.Count -eq 0) { $Job.Status = "skipped" }
    else { $Job.Status = "succeeded" }
    $Job.Finished = (Get-Date).ToString("o")
}.ToString()

function Start-GuiTask {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Work,
        [hashtable]$Arguments = @{},
        [string]$Package,
        $RunspacePool = $Pool,
        [switch]$Hidden
    )
    $script:JobCounter++
    $Job = [hashtable]::Synchronized(@{
        Id       = "job$($script:JobCounter)"
        Kind     = $Kind
        Title    = $Title
        Package  = $Package
        Hidden   = [bool]$Hidden
        Status   = "queued"
        HadError = $false
        Log      = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        Queued   = (Get-Date).ToString("o")
        Started  = $null
        Finished = $null
        Result   = $null
    })
    [void]$Shared.Jobs.Add($Job)

    # Work is passed as text: script blocks are bound to the runspace that created them
    $PowerShell = [powershell]::Create()
    $PowerShell.RunspacePool = $RunspacePool
    [void]$PowerShell.AddScript($TaskBody).AddArgument($CorePath).AddArgument($Shared).AddArgument($Job).AddArgument($Work).AddArgument($Arguments)
    $Tasks[$Job.Id] = @{ PowerShell = $PowerShell; Handle = $PowerShell.BeginInvoke(); Job = $Job }
    return $Job
}

function Complete-GuiTasks {
    foreach ($Id in @($Tasks.Keys)) {
        $Task = $Tasks[$Id]
        if (-not $Task.Handle.IsCompleted) { continue }
        try { [void]$Task.PowerShell.EndInvoke($Task.Handle) } catch { [void]$Task.Job.Log.Add(@{ time = (Get-Date).ToString("HH:mm:ss"); level = "error"; text = $_.Exception.Message }) }
        $Task.PowerShell.Dispose()
        $Tasks.Remove($Id)
        Complete-GuiJob $Task.Job
    }
}

function Complete-GuiJob($Job) {
    switch ($Job.Kind) {
        "connect" {
            if ($Job.Status -eq "succeeded" -and $Job.Result.Count -gt 0) {
                $Shared.Auth = $Job.Result[0]
                $Shared.TenantApps = $null
                Set-IntuneChocoAuthState $Shared.Auth
                $script:Settings = Get-IntuneChocoSettings
            }
        }
        "meta" { $script:MetaDirty = $true }
        "deploy" { $Shared.TenantApps = $null }
        "components" { Remove-Module IntuneWin32App -ErrorAction SilentlyContinue }
    }
}

#endregion

#region Package metadata cache

if (Test-Path $MetaCachePath) {
    try {
        $Cache = Get-Content -Path $MetaCachePath -Raw | ConvertFrom-Json
        foreach ($Property in $Cache.PSObject.Properties) {
            if (([datetime]$Property.Value.Fetched) -gt (Get-Date).AddHours(-$MetaCacheHours)) { $Shared.Meta[$Property.Name] = $Property.Value }
        }
    }
    catch { Write-Warning "Feed cache is unreadable and will be rebuilt" }
}

function Save-MetaCache {
    $Copy = @{}
    foreach ($Key in @($Shared.Meta.Keys)) { $Copy[$Key] = $Shared.Meta[$Key] }
    New-Item -Path $script:WorkRoot -ItemType Directory -Force | Out-Null
    $Copy | ConvertTo-Json -Depth 4 | Set-Content -Path $MetaCachePath -Encoding UTF8
    $script:MetaDirty = $false
}

function ConvertTo-MetaEntry($Info) {
    return [pscustomobject]@{
        Fetched     = (Get-Date).ToString("o")
        Found       = $true
        Name        = $Info.Name
        Title       = $Info.Title
        Version     = $Info.Version
        Summary     = $Info.Summary
        Authors     = $Info.Authors
        IconUrl     = $Info.IconUrl
        ProjectUrl  = $Info.SoftwareSite
        LicenseUrl  = $Info.SoftwareLicense
        Downloads   = $Info.Downloads
        LicenseNote = $Info.LicenseNote
    }
}

$MetaWork = @'
param($Ids)
foreach ($Id in $Ids) {
    try {
        $Info = Get-ChocoInfo -ChocoName $Id
        $Shared.Meta[$Id.ToLower()] = [pscustomobject]@{
            Fetched = (Get-Date).ToString("o"); Found = $true; Name = $Info.Name; Title = $Info.Title; Version = $Info.Version
            Summary = $Info.Summary; Authors = $Info.Authors; IconUrl = $Info.IconUrl; ProjectUrl = $Info.SoftwareSite
            LicenseUrl = $Info.SoftwareLicense; Downloads = $Info.Downloads; LicenseNote = $Info.LicenseNote
        }
    }
    catch {
        $Shared.Meta[$Id.ToLower()] = [pscustomobject]@{ Fetched = (Get-Date).ToString("o"); Found = $false; Name = $Id }
    }
}
'@

function Start-MetaPrefetch([string[]]$Ids) {
    $Running = @($Shared.Jobs | Where-Object { $_.Kind -eq "meta" -and $_.Status -in "queued", "running" })
    if ($Running.Count -gt 0) { return }
    $Missing = @($Ids | Where-Object { -not $Shared.Meta.ContainsKey($_.ToLower()) })
    if ($Missing.Count -eq 0) { return }
    # Four parallel lookups: the feed has no batch query, and politeness matters more than speed
    for ($i = 0; $i -lt 4; $i++) {
        $Chunk = @(for ($j = $i; $j -lt $Missing.Count; $j += 4) { $Missing[$j] })
        if ($Chunk.Count -gt 0) { [void](Start-GuiTask -Kind "meta" -Title "Feed lookup" -Work $MetaWork -Arguments @{ Ids = $Chunk } -Hidden) }
    }
}

#endregion

#region HTTP helpers

function Send-Response {
    param($Context, [int]$Status = 200, [byte[]]$Body = @(), [string]$ContentType = "application/json; charset=utf-8")
    $Response = $Context.Response
    $Response.StatusCode = $Status
    $Response.ContentType = $ContentType
    $Response.Headers["Cache-Control"] = "no-store"
    $Response.Headers["X-Content-Type-Options"] = "nosniff"
    $Response.Headers["Content-Security-Policy"] = "default-src 'self'; img-src * data: blob:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'"
    $Response.ContentLength64 = $Body.Length
    if ($Body.Length -gt 0) { $Response.OutputStream.Write($Body, 0, $Body.Length) }
}

function Send-Json($Context, $Data, [int]$Status = 200) {
    $Json = ConvertTo-Json -InputObject $Data -Depth 8 -Compress
    Send-Response -Context $Context -Status $Status -Body ([Text.Encoding]::UTF8.GetBytes($Json))
}

function Read-JsonBody($Context) {
    if ($Context.Request.ContentLength64 -gt 8MB) { throw "Request too large" }
    $Reader = New-Object IO.StreamReader($Context.Request.InputStream, [Text.Encoding]::UTF8)
    try { $Text = $Reader.ReadToEnd() } finally { $Reader.Dispose() }
    if ([string]::IsNullOrWhiteSpace($Text)) { return [pscustomobject]@{} }
    return $Text | ConvertFrom-Json
}

function Get-JobView($Job) {
    return [ordered]@{
        id       = $Job.Id
        kind     = $Job.Kind
        title    = $Job.Title
        package  = $Job.Package
        status   = $Job.Status
        queued   = $Job.Queued
        started  = $Job.Started
        finished = $Job.Finished
        log      = @($Job.Log.ToArray())
        result   = @($Job.Result | Where-Object { $_ -is [string] })
    }
}

function Get-TokenIdentity {
    # Reads name and account from the access token (display only, the signature is checked by Graph)
    try {
        $Payload = $Global:AccessToken.access_token.Split(".")[1].Replace("-", "+").Replace("_", "/")
        $Payload = $Payload.PadRight($Payload.Length + (4 - $Payload.Length % 4) % 4, "=")
        $Claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Payload)) | ConvertFrom-Json
        return [ordered]@{ name = $Claims.name; account = $Claims.upn; tenantId = $Claims.tid }
    }
    catch { return [ordered]@{ name = $null; account = $null; tenantId = $Global:AccessTokenTenantID } }
}

function Get-StateView {
    $Module = Get-Module -ListAvailable IntuneWin32App | Sort-Object Version -Descending | Select-Object -First 1
    $Connected = $null -ne $Shared.Auth
    $Expires = $null
    if ($Connected -and $Shared.Auth.AccessToken.ExpiresOn) { $Expires = ([datetime]$Shared.Auth.AccessToken.ExpiresOn).ToUniversalTime().ToString("o") }
    return [ordered]@{
        version       = $GuiVersion
        powershell    = $PSVersionTable.PSVersion.ToString()
        moduleVersion = $(if ($Module) { $Module.Version.ToString() } else { $null })
        moduleOk      = ($null -ne $Module -and $Module.Version -ge $script:MinimumModuleVersion)
        moduleMinimum = $script:MinimumModuleVersion.ToString()
        connected     = $Connected
        identity      = $(if ($Connected) { Get-TokenIdentity } else { $null })
        expires       = $Expires
        settings      = $script:Settings
        running       = @($Shared.Jobs | Where-Object { -not $_.Hidden -and $_.Status -in "queued", "running" }).Count
    }
}

function Assert-Connected {
    if ($null -eq $Shared.Auth) { throw [System.UnauthorizedAccessException]::new("Not connected to Intune, sign in first") }
    Set-IntuneChocoAuthState $Shared.Auth
}

function Get-TenantAppList([switch]$Force) {
    Assert-Connected
    if ($Force -or $null -eq $Shared.TenantApps) {
        $Shared.TenantApps = @(Get-IntuneChocoTenantApps 3>$null 6>$null)
        if ($Global:AccessToken) { $Shared.Auth = Get-IntuneChocoAuthState }
    }
    return $Shared.TenantApps
}

$StaticTypes = @{
    ".html" = "text/html; charset=utf-8"
    ".css"  = "text/css; charset=utf-8"
    ".js"   = "text/javascript; charset=utf-8"
    ".svg"  = "image/svg+xml"
    ".png"  = "image/png"
}

#endregion

#region Routes

function Invoke-Route($Context, [string]$Token, [int]$ListenPort) {
    $Request = $Context.Request
    $Path = $Request.Url.AbsolutePath
    $Method = $Request.HttpMethod

    # Only this machine, and no other web page may drive the API (DNS rebinding, cross-site requests)
    if ($Request.Url.Host -notin "localhost", "127.0.0.1") { Send-Json $Context @{ error = "Forbidden" } 403; return }
    $Origin = $Request.Headers["Origin"]
    if ($Origin -and $Origin -notin "http://localhost:$ListenPort", "http://127.0.0.1:$ListenPort") { Send-Json $Context @{ error = "Forbidden" } 403; return }

    if (-not $Path.StartsWith("/api/")) {
        if ($Method -ne "GET") { Send-Json $Context @{ error = "Not found" } 404; return }
        $File = if ($Path -eq "/") { "index.html" } else { $Path.TrimStart("/") }
        $Full = [IO.Path]::GetFullPath((Join-Path $GuiRoot $File))
        $Extension = [IO.Path]::GetExtension($Full).ToLower()
        if (-not $Full.StartsWith($GuiRoot + [IO.Path]::DirectorySeparatorChar) -or -not $StaticTypes.ContainsKey($Extension) -or -not (Test-Path $Full -PathType Leaf)) {
            Send-Json $Context @{ error = "Not found" } 404; return
        }
        Send-Response -Context $Context -Body ([IO.File]::ReadAllBytes($Full)) -ContentType $StaticTypes[$Extension]
        return
    }

    if ($Request.Headers["X-Session-Token"] -ne $Token) { Send-Json $Context @{ error = "Session token missing or wrong, restart Start-IntuneChocoGui.ps1" } 401; return }

    $Query = [System.Web.HttpUtility]::ParseQueryString($Request.Url.Query)
    switch -Regex ("$Method $Path") {
        '^GET /api/state$' {
            Send-Json $Context (Get-StateView)
        }
        '^POST /api/settings$' {
            $Body = Read-JsonBody $Context
            [void](Save-IntuneChocoSettings -Settings $Body)
            $script:Settings = Get-IntuneChocoSettings
            Send-Json $Context (Get-StateView)
        }
        '^POST /api/connect$' {
            $Body = Read-JsonBody $Context
            if (-not $Body.tenantId -or -not $Body.clientId) { throw [ArgumentException]::new("Tenant and client ID are required") }
            $Settings = Get-IntuneChocoSettings
            $Settings.TenantID = [string]$Body.tenantId
            $Settings.ClientID = [string]$Body.clientId
            [void](Save-IntuneChocoSettings -Settings $Settings)
            $script:Settings = Get-IntuneChocoSettings
            $Work = 'param($TenantID, $ClientID) Connect-IntuneChoco -TenantID $TenantID -ClientID $ClientID; Get-IntuneChocoAuthState'
            $Job = Start-GuiTask -Kind "connect" -Title "Sign in to $($Settings.TenantID)" -Work $Work -Arguments @{ TenantID = $Settings.TenantID; ClientID = $Settings.ClientID }
            Send-Json $Context (Get-JobView $Job)
        }
        '^POST /api/disconnect$' {
            $Shared.Auth = $null
            $Shared.TenantApps = $null
            Set-IntuneChocoAuthState @{}
            Send-Json $Context (Get-StateView)
        }
        '^POST /api/components$' {
            $Job = Start-GuiTask -Kind "components" -Title "Install IntuneWin32App module" -Work 'Install-IntunechocoComponents'
            Send-Json $Context (Get-JobView $Job)
        }
        '^GET /api/catalog$' {
            $Catalog = @(Get-IntuneChocoCatalog)
            Start-MetaPrefetch -Ids @($Catalog.Id)
            if ($script:MetaDirty -and @($Shared.Jobs | Where-Object { $_.Kind -eq "meta" -and $_.Status -in "queued", "running" }).Count -eq 0) { Save-MetaCache }
            $Items = foreach ($Entry in $Catalog) {
                [ordered]@{
                    id          = $Entry.Id
                    name        = $Entry.Name
                    category    = $Entry.Category
                    licenseNote = $Entry.LicenseNote
                    meta        = $Shared.Meta[$Entry.Id.ToLower()]
                }
            }
            $Loading = @($Shared.Jobs | Where-Object { $_.Kind -eq "meta" -and $_.Status -in "queued", "running" }).Count -gt 0
            Send-Json $Context ([ordered]@{ items = @($Items); loading = $Loading })
        }
        '^GET /api/search$' {
            $Term = [string]$Query["q"]
            if ($Term.Trim().Length -lt 2) { throw [ArgumentException]::new("Enter at least two characters") }
            $Results = @(Search-ChocoPackage -SearchPattern $Term.Trim() -Top 40)
            foreach ($Result in $Results) { $Shared.Meta[$Result.Name.ToLower()] = ConvertTo-MetaEntry $Result }
            $script:MetaDirty = $true
            Send-Json $Context @($Results | ForEach-Object { [ordered]@{ id = $_.Name; name = $_.Title; licenseNote = $_.LicenseNote; meta = $Shared.Meta[$_.Name.ToLower()] } })
        }
        '^GET /api/package$' {
            $Id = [string]$Query["id"]
            $Info = Get-ChocoInfo -ChocoName $Id
            $Shared.Meta[$Info.Name.ToLower()] = ConvertTo-MetaEntry $Info
            $script:MetaDirty = $true
            Send-Json $Context ([ordered]@{
                id = $Info.Name; title = $Info.Title; version = $Info.Version; authors = $Info.Authors; summary = $Info.Summary
                description = $Info.Description; projectUrl = $Info.SoftwareSite; licenseUrl = $Info.SoftwareLicense
                iconUrl = $Info.IconUrl; downloads = $Info.Downloads; licenseNote = $Info.LicenseNote
            })
        }
        '^GET /api/tenant$' {
            $Apps = Get-TenantAppList -Force:($Query["refresh"] -eq "1")
            Send-Json $Context @($Apps | ForEach-Object {
                $Meta = if ($_.Package) { $Shared.Meta[$_.Package.ToLower()] } else { $null }
                [ordered]@{ id = $_.Id; displayName = $_.DisplayName; package = $_.Package; isChocolatey = $_.IsChocolatey; created = $_.Created; iconUrl = $(if ($Meta) { $Meta.IconUrl } else { $null }) }
            })
        }
        '^POST /api/deploy$' {
            Assert-Connected
            $Body = Read-JsonBody $Context
            $Assignment = [string]$Body.assignment
            if ($Assignment -notin "Available", "Required", "None") { throw [ArgumentException]::new("Unknown assignment") }
            $Architecture = if ($Body.architecture) { [string]$Body.architecture } else { $script:Settings.Architecture }
            $Work = @'
param($Id, $Assignment, $Architecture, $IconBase64)
$Params = @{ ChocoName = $Id; Assignment = $Assignment; Architecture = $Architecture; NoIconPrompt = $true }
if ($IconBase64) { $Params.IconBase64 = $IconBase64 }
New-IntuneWin32ChocoApplication @Params
'@
            $Jobs = foreach ($Package in @($Body.packages)) {
                $Id = [string]$Package.id
                if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw [ArgumentException]::new("Invalid package id '$Id'") }
                $Icon = [string]$Package.iconBase64
                if ($Icon -and $Icon -notmatch '^(iVBORw0KGgo|/9j/)[A-Za-z0-9+/=]+$') { throw [ArgumentException]::new("The custom icon for $Id must be a PNG or JPEG") }
                $Title = if ($Package.name) { [string]$Package.name } else { $Id }
                Get-JobView (Start-GuiTask -Kind "deploy" -Title $Title -Package $Id -Work $Work -RunspacePool $DeployPool -Arguments @{
                    Id = $Id; Assignment = $Assignment; Architecture = $Architecture; IconBase64 = $Icon
                })
            }
            Send-Json $Context @($Jobs)
        }
        '^GET /api/jobs$' {
            Send-Json $Context @($Shared.Jobs.ToArray() | Where-Object { -not $_.Hidden } | ForEach-Object { Get-JobView $_ })
        }
        '^GET /api/jobs/(job\d+)$' {
            $Job = $Shared.Jobs.ToArray() | Where-Object { $_.Id -eq $Matches[1] } | Select-Object -First 1
            if (-not $Job) { Send-Json $Context @{ error = "Unknown job" } 404; return }
            Send-Json $Context (Get-JobView $Job)
        }
        '^POST /api/jobs/clear$' {
            foreach ($Job in @($Shared.Jobs.ToArray() | Where-Object { $_.Status -in "succeeded", "failed", "skipped" })) { $Shared.Jobs.Remove($Job) }
            Send-Json $Context @()
        }
        '^POST /api/quit$' {
            Send-Json $Context @{ ok = $true }
            $script:StopRequested = $true
        }
        default { Send-Json $Context @{ error = "Not found" } 404 }
    }
}

#endregion

#region Start

Add-Type -AssemblyName System.Web
if ($Port -eq 0) {
    $Probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $Probe.Start()
    $Port = $Probe.LocalEndpoint.Port
    $Probe.Stop()
}
$SessionToken = -join ((1..32) | ForEach-Object { "{0:x2}" -f (Get-Random -Maximum 256) })
$Listener = New-Object System.Net.HttpListener
$Listener.Prefixes.Add("http://localhost:$Port/")
$Listener.Start()
$script:StopRequested = $false

$Url = "http://localhost:$Port/#token=$SessionToken"
Write-Host "Intune Choco Deployment GUI is running on http://localhost:$Port/"
Write-Host "Press Ctrl+C or use Quit in the browser to stop."
if (-not $NoBrowser) { Start-Process $Url } else { Write-Host "Open: $Url" }

try {
    while ($Listener.IsListening -and -not $script:StopRequested) {
        $Pending = $Listener.GetContextAsync()
        while (-not $Pending.Wait(200)) { Complete-GuiTasks }
        $Context = $Pending.Result
        try {
            Complete-GuiTasks
            Invoke-Route -Context $Context -Token $SessionToken -ListenPort $Port
        }
        catch {
            $Status = if ($_.Exception -is [System.UnauthorizedAccessException]) { 409 } elseif ($_.Exception -is [ArgumentException]) { 400 } else { 500 }
            try { Send-Json $Context @{ error = $_.Exception.Message } $Status } catch { }
        }
        finally {
            try { $Context.Response.Close() } catch { }
        }
    }
}
finally {
    $Listener.Stop()
    $Listener.Close()
    if ($script:MetaDirty) { try { Save-MetaCache } catch { } }
    $Running = @($Shared.Jobs | Where-Object { -not $_.Hidden -and $_.Status -in "queued", "running" }).Count
    if ($Running -gt 0) { Write-Warning "$Running deployment(s) were still running and have been stopped" }
    $Pool.Close()
    $DeployPool.Close()
    Write-Host "GUI stopped"
}

#endregion
