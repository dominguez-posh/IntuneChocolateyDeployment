<#
.SYNOPSIS
    Smoke test of the graphical interface: starts Start-IntuneChocoTool.ps1 off-screen with a fake IntuneWin32App
    module and a stand-in for the Microsoft sign-in, drives every page (sign-in with cancel and token renewal,
    catalog, search, custom icon, deployments, tenant with removal, settings, sign-out) and checks the results.
    No window, browser or dialog shows up on the desktop, nothing is sent to a tenant.
.DESCRIPTION
    Runs in a separate Windows PowerShell 5.1 process with its own %LOCALAPPDATA% (settings, work folder, fake tenant).
    Package infos are read from the real Chocolatey feed; an existing feed cache of this user is copied in first so
    the feed is asked as little as possible. Screenshots of every page land in -OutDir.
.EXAMPLE
    .\Tests\Invoke-GuiSmoke.ps1
#>
[CmdletBinding()]
param([string]$OutDir = (Join-Path ([IO.Path]::GetTempPath()) 'IntuneChocoSmoke'))

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
$appData = Join-Path $OutDir 'appdata'
New-Item -ItemType Directory -Path (Join-Path $appData 'IntuneChocoDeployment') -Force | Out-Null
@{ TenantID = 'contoso.onmicrosoft.com'; ClientID = '11111111-2222-3333-4444-555555555555' } | ConvertTo-Json |
    Set-Content (Join-Path $appData 'IntuneChocoDeployment\settings.json')
$cache = Join-Path $env:LOCALAPPDATA 'IntuneChocoDeployment\feedcache.json'
if (Test-Path $cache) { Copy-Item $cache (Join-Path $appData 'IntuneChocoDeployment\feedcache.json') }

# Stand-in for the Microsoft sign-in: /authorize redirects straight back with a code, /token hands out tokens
# (name "Test Admin", after a renewal "Test Admin renewed"). Runs in its own runspace while the GUI process works.
$probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$probe.Start(); $authorityPort = $probe.LocalEndpoint.Port; $probe.Stop()
$authorityState = [hashtable]::Synchronized(@{})
$authority = [powershell]::Create()
[void]$authority.AddScript({
    param($Port, $State)
    Add-Type -AssemblyName System.Web
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$Port/")
    $listener.Start()
    $State.Listener = $listener
    $token = {
        param($Name)
        $claims = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("{`"name`":`"$Name`",`"upn`":`"admin@contoso.onmicrosoft.com`",`"tid`":`"t-1`"}")).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        "{`"token_type`":`"Bearer`",`"scope`":`"https://graph.microsoft.com/DeviceManagementApps.ReadWrite.All`",`"expires_in`":3600,`"access_token`":`"x.$claims.y`",`"refresh_token`":`"refresh-$Name`"}"
    }
    while ($listener.IsListening) {
        try { $context = $listener.GetContext() } catch { break }
        $request = $context.Request
        if ($request.Url.AbsolutePath -like '*/authorize') {
            $context.Response.StatusCode = 302
            $context.Response.RedirectLocation = $request.QueryString['redirect_uri'] + '/?code=fake-code&state=' + [uri]::EscapeDataString($request.QueryString['state'])
        }
        elseif ($request.Url.AbsolutePath -like '*/token') {
            $body = [System.Web.HttpUtility]::ParseQueryString((New-Object IO.StreamReader($request.InputStream)).ReadToEnd())
            $ok = ($body['grant_type'] -eq 'authorization_code' -and $body['code'] -eq 'fake-code' -and $body['code_verifier']) -or ($body['grant_type'] -eq 'refresh_token' -and $body['refresh_token'] -like 'refresh-*')
            $json = if (-not $ok) { $context.Response.StatusCode = 400; '{"error":"invalid_grant","error_description":"Fake authority: unexpected token request"}' }
                    elseif ($body['grant_type'] -eq 'refresh_token') { & $token 'Test Admin renewed' } else { & $token 'Test Admin' }
            $bytes = [Text.Encoding]::UTF8.GetBytes($json)
            $context.Response.ContentType = 'application/json'
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        else { $context.Response.StatusCode = 404 }
        $context.Response.Close()
    }
}.ToString()).AddArgument($authorityPort).AddArgument($authorityState)
[void]$authority.BeginInvoke()

$results = Join-Path $OutDir 'results.txt'
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$psi.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $repo 'Start-IntuneChocoTool.ps1')
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.EnvironmentVariables['LOCALAPPDATA'] = $appData
$psi.EnvironmentVariables['PSModulePath'] = (Join-Path $PSScriptRoot 'Fakes') + ';' + "$env:USERPROFILE\Documents\WindowsPowerShell\Modules;$env:ProgramFiles\WindowsPowerShell\Modules;$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules"
$psi.EnvironmentVariables['INTUNECHOCO_SMOKE'] = Join-Path $PSScriptRoot 'GuiSmokeDriver.ps1'
$psi.EnvironmentVariables['INTUNECHOCO_SMOKE_OUT'] = $OutDir
$psi.EnvironmentVariables['INTUNECHOCO_SMOKE_AUTHORITY'] = "http://localhost:$authorityPort"
$process = [System.Diagnostics.Process]::Start($psi)
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
$finished = $process.WaitForExit(15 * 60 * 1000)
if ($authorityState.Listener) { $authorityState.Listener.Stop() }
if (-not $finished) { $process.Kill(); throw 'The GUI smoke test did not finish within 15 minutes.' }
if ($stderr.Result.Trim()) { "--- stderr ---"; $stderr.Result }
if (-not (Test-Path $results)) { "--- stdout ---"; $stdout.Result; throw 'The GUI smoke test wrote no results.' }
Get-Content $results
$failed = @(Get-Content $results | Where-Object { $_ -like 'FAIL*' }).Count
"Screenshots: $OutDir"
if ($failed -gt 0) { throw "$failed check(s) failed." }
'All checks passed.'
