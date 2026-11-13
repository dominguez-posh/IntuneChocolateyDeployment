# Sign-in with an account stored in Keevault (the user's password manager), through Keevault's MCP interface.
# Keevault comes to the front, the user picks the Microsoft account and Keevault hands over user name, password and
# the current one-time code (tool request_microsoft_login). An embedded browser (WebView2) runs the normal Microsoft
# sign-in and fills these in step by step; the user can type or choose another method at any time.
# The authorization code is redeemed here (public client with PKCE, the tool's own app registration).
# Same technique as in MSIX Sandbox Studio; the token goes to the IntuneWin32App module with Set-IntuneChocoToken.

$script:SignInRedirect = 'http://localhost'
$script:SignInHosts = @('login.microsoftonline.com', 'login.microsoft.com', 'login.live.com')
$script:DefaultScopes = @('DeviceManagementApps.ReadWrite.All', 'DeviceManagementConfiguration.ReadWrite.All', 'DeviceManagementRBAC.Read.All', 'Group.Read.All')
$script:Log = { param($Text, $Level) Write-Host $Text }

function Set-IntuneChocoSignInLog {
    <# Where the sign-in writes its progress: a script block taking (text, level). #>
    param([Parameter(Mandatory)][scriptblock]$Sink)
    $script:Log = $Sink
}
function Write-SignInLog([string]$Text, [string]$Level = 'Info') { & $script:Log $Text $Level }

# ---------------------------------------------------------------- Keevault MCP client (JSON-RPC over stdio)
function Find-KeevaultMcp {
    <# Where Keevault and its MCP host script are, and whether it is installed, MCP is switched on and the app runs. #>
    $running = Get-Process Keevault -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -First 1
    $exe = if ($running) { $running.Path } else { Join-Path $env:LOCALAPPDATA 'Programs\Keevault\Keevault.exe' }
    $script = Join-Path $env:APPDATA 'KeyVault PwSafe\mcp\keevault-mcp.cjs'
    [pscustomobject]@{
        Exe        = $exe
        Script     = $script
        Installed  = (Test-Path $exe)
        McpEnabled = (Test-Path $script)
        Running    = [bool]$running
    }
}

function Connect-KeevaultMcp {
    <# Starts Keevault's MCP host (Keevault.exe as Node) and runs the MCP handshake. $OnWait runs while waiting. #>
    param([scriptblock]$OnWait)
    $kv = Find-KeevaultMcp
    if (-not $kv.Installed) { throw 'Keevault is not installed on this computer.' }
    if (-not $kv.McpEnabled) { throw 'AI agents (MCP) are switched off in Keevault: Keevault > Settings > AI agents (MCP) > switch on and save.' }
    if (-not $kv.Running) { throw 'Keevault is not running. Start and unlock Keevault, then sign in again.' }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $kv.Exe
    $psi.Arguments = '"{0}"' -f $kv.Script
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
    $psi.EnvironmentVariables['ELECTRON_RUN_AS_NODE'] = '1'
    $process = [System.Diagnostics.Process]::Start($psi)
    [void]$process.StandardError.ReadToEndAsync()   # drained so the host never blocks on a full pipe

    $client = [pscustomobject]@{ Process = $process; NextId = 0; Pending = $null }
    try {
        [void](Invoke-KeevaultMcpRequest -Client $client -Method 'initialize' -TimeoutSeconds 20 -OnWait $OnWait -Params @{
            protocolVersion = '2025-06-18'
            capabilities    = @{}
            clientInfo      = @{ name = 'PackTune'; version = '2.1.0' }
        })
        Send-KeevaultMcpMessage -Client $client -Message @{ jsonrpc = '2.0'; method = 'notifications/initialized' }
    }
    catch { Close-KeevaultMcp $client; throw }
    $client
}

function Send-KeevaultMcpMessage {
    param([Parameter(Mandatory)]$Client, [Parameter(Mandatory)][hashtable]$Message)
    # UTF-8 without BOM, one JSON object per line (.NET Framework has no StandardInputEncoding)
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes(($Message | ConvertTo-Json -Depth 10 -Compress) + "`n")
    $stream = $Client.Process.StandardInput.BaseStream
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

function Invoke-KeevaultMcpRequest {
    param(
        [Parameter(Mandatory)]$Client,
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Params = @{},
        [int]$TimeoutSeconds = 300,
        [scriptblock]$OnWait
    )
    $Client.NextId++
    $id = $Client.NextId
    Send-KeevaultMcpMessage -Client $Client -Message @{ jsonrpc = '2.0'; id = $id; method = $Method; params = $Params }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        if (-not $Client.Pending) { $Client.Pending = $Client.Process.StandardOutput.ReadLineAsync() }
        while (-not $Client.Pending.Wait(50)) {
            if ($OnWait) { & $OnWait }
            if ($Client.Process.HasExited) { throw 'The connection to Keevault ended unexpectedly.' }
            if ((Get-Date) -gt $deadline) { throw "Keevault did not answer within $TimeoutSeconds seconds." }
        }
        $line = $Client.Pending.Result
        $Client.Pending = $null
        if ($null -eq $line) { throw 'The connection to Keevault ended unexpectedly.' }
        if (-not $line.Trim()) { continue }
        $msg = $line | ConvertFrom-Json
        if ($msg.id -ne $id) { continue }   # notifications or other replies
        if ($msg.error) { throw "Keevault: $($msg.error.message)" }
        return $msg.result
    }
}

function Invoke-KeevaultMcpTool {
    <# Calls a Keevault tool and returns its result object; a tool error (e.g. declined) becomes an exception. #>
    param(
        [Parameter(Mandatory)]$Client,
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Arguments = @{},
        [int]$TimeoutSeconds = 300,
        [scriptblock]$OnWait
    )
    $r = Invoke-KeevaultMcpRequest -Client $Client -Method 'tools/call' -Params @{ name = $Name; arguments = $Arguments } -TimeoutSeconds $TimeoutSeconds -OnWait $OnWait
    $text = @($r.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n"
    if ($r.isError) { throw "Keevault: $text" }
    if ($r.structuredContent) { return $r.structuredContent }
    $text | ConvertFrom-Json
}

function Close-KeevaultMcp {
    param($Client)
    if (-not $Client -or -not $Client.Process) { return }
    try { $Client.Process.StandardInput.Close() } catch { }
    if (-not $Client.Process.WaitForExit(2000)) { try { $Client.Process.Kill() } catch { } }
    $Client.Process.Dispose()
}

# ---------------------------------------------------------------- embedded browser (WebView2)
function Get-IntuneChocoWebView2 {
    <#
    Loads the WebView2 SDK (Core + WPF) for the embedded sign-in window. Downloaded once from NuGet into
    $CacheFolder; the DLLs must carry a valid Microsoft signature. Needs the WebView2 runtime (part of Windows 11,
    otherwise installed with Edge).
    #>
    param([Parameter(Mandatory)][string]$CacheFolder)
    $core = Join-Path $CacheFolder 'Microsoft.Web.WebView2.Core.dll'
    $wpf = Join-Path $CacheFolder 'Microsoft.Web.WebView2.Wpf.dll'
    $loader = Join-Path $CacheFolder 'WebView2Loader.dll'
    if (-not ((Test-Path $core) -and (Test-Path $wpf) -and (Test-Path $loader))) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $index = Invoke-RestMethod 'https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/index.json' -TimeoutSec 20
        $version = @($index.versions | Where-Object { $_ -notmatch '-' })[-1]
        Write-SignInLog "Downloading the WebView2 SDK $version for the embedded sign-in ..."
        $nupkg = Join-Path ([IO.Path]::GetTempPath()) "webview2-$version.zip"
        Invoke-WebRequest -Uri "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$version/microsoft.web.webview2.$version.nupkg" -OutFile $nupkg -UseBasicParsing -TimeoutSec 120
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        if (Test-Path $CacheFolder) { Remove-Item $CacheFolder -Recurse -Force }
        New-Item -ItemType Directory -Path $CacheFolder -Force | Out-Null
        $zip = [IO.Compression.ZipFile]::OpenRead($nupkg)
        try {
            $wanted = @{
                'lib/net462/Microsoft.Web.WebView2.Core.dll' = $core
                'lib/net462/Microsoft.Web.WebView2.Wpf.dll'  = $wpf
                'runtimes/win-x64/native/WebView2Loader.dll' = $loader
            }
            foreach ($e in $zip.Entries) {
                if ($wanted.ContainsKey($e.FullName)) { [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $wanted[$e.FullName], $true) }
            }
        }
        finally { $zip.Dispose(); Remove-Item $nupkg -Force -ErrorAction SilentlyContinue }
        foreach ($f in $core, $wpf, $loader) {
            $sig = if (Test-Path $f) { Get-AuthenticodeSignature -FilePath $f }
            if (-not $sig -or $sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
                Remove-Item $CacheFolder -Recurse -Force -ErrorAction SilentlyContinue
                throw "The WebView2 SDK file $(Split-Path $f -Leaf) is missing or not signed by Microsoft."
            }
        }
    }
    if (-not ('Microsoft.Web.WebView2.Wpf.WebView2' -as [type])) {
        Add-Type -Path $core
        Add-Type -Path $wpf
        [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::SetLoaderDllFolderPath($CacheFolder)
    }
    try { [void][Microsoft.Web.WebView2.Core.CoreWebView2Environment]::GetAvailableBrowserVersionString() }
    catch { throw 'The Microsoft Edge WebView2 runtime is not installed (https://go.microsoft.com/fwlink/p/?LinkId=2124703).' }
    $CacheFolder
}

function ConvertTo-Base64Url([byte[]]$Bytes) {
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-SignInScopeString([string[]]$Scopes) {
    if (-not $Scopes) { $Scopes = $script:DefaultScopes }
    (@($Scopes | ForEach-Object { if ($_ -match '^https?://') { $_ } else { "https://graph.microsoft.com/$_" } }) + 'offline_access', 'openid', 'profile') -join ' '
}

function Request-IntuneChocoToken {
    <# Redeems an authorization code or a refresh token at the tenant's token endpoint. #>
    param([Parameter(Mandatory)][string]$TenantID, [Parameter(Mandatory)][string]$ClientID, [Parameter(Mandatory)][hashtable]$Body, [string[]]$Scopes)
    $Body.client_id = $ClientID
    $Body.scope = Get-SignInScopeString $Scopes
    try { Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantID/oauth2/v2.0/token" -Body $Body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 30 }
    catch {
        $detail = try { ($_.ErrorDetails.Message | ConvertFrom-Json).error_description } catch { $null }
        throw "Token request failed: $(if ($detail) { $detail } else { $_.Exception.Message })"
    }
}

# Watches the Microsoft sign-in page and reports the current step to the host; the host answers with
# __kvFill / __kvClick. Runs after every navigation (the page switches steps without navigating).
$script:SignInPageScript = @'
(() => {
  if (window.__kvSignIn) return;
  window.__kvSignIn = true;
  const q = (s) => document.querySelector(s);
  const shown = (el) => !!el && !el.disabled && el.offsetParent !== null;
  const empty = (s) => shown(q(s)) && !q(s).value;
  // Link or tile "Face, fingerprint, PIN or security key" (only when Keevault signs the passkey and has not yet)
  const toPasskey = () => window.__kvPasskeyShim && !window.__kvPasskeyUsed && (
    [...document.querySelectorAll('a,button,div[role="button"],div[role="listitem"]')].find((el) => shown(el) && /fido|passkey/i.test(el.id || '') || shown(el) && (el.getAttribute('data-value') || '') === 'FidoKey')
    || [...document.querySelectorAll('a,button,div[role="button"],div[role="listitem"]')].find((el) => shown(el) && (el.innerText || '').length < 120 && /gesicht|fingerabdruck|sicherheitsschl|face, fingerprint|security key|passkey/i.test(el.innerText || '')));
  let last = '';
  setInterval(() => {
    let step = '';
    if (empty('input[name="otc"]')) step = 'otp';
    else if (toPasskey()) step = 'to-passkey';
    else if (empty('input[name="passwd"]')) step = 'password';
    else if (empty('input[name="loginfmt"]')) step = 'username';
    else if (shown(q('#KmsiCheckboxField')) && shown(q('#idBtn_Back'))) step = 'kmsi';
    else if (shown(q('[data-value="PhoneAppOTP"]'))) step = 'choose-otp';
    else if (shown(q('#signInAnotherWay'))) step = 'another-way';
    if (step !== last) { last = step; if (step) window.chrome.webview.postMessage(step); }
  }, 400);
  window.__kvFill = (selector, value, submit) => {
    const el = q(selector);
    if (!el) return;
    el.focus();
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, value);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    setTimeout(() => {
      const b = q(submit) || [...document.querySelectorAll('input[type="submit"],button[type="submit"]')].find(shown);
      if (b) b.click();
    }, 300);
  };
  window.__kvClick = (selector) => { const el = q(selector); if (el) el.click(); };
  window.__kvToPasskey = () => { const el = toPasskey(); if (el) el.click(); };
})();
'@

# Runs before the page's own scripts (only when the Keevault entry holds a passkey): the first passkey request of
# the page (navigator.credentials.get) goes to the host, which has Keevault sign it; the private key never leaves
# Keevault. Declined or failed: the browser's own passkey dialog (Windows Hello) as usual.
$script:PasskeyShimScript = @'
(() => {
  if (window.__kvPasskeyShim || !navigator.credentials || !window.chrome || !window.chrome.webview) return;
  window.__kvPasskeyShim = true;
  const original = navigator.credentials.get.bind(navigator.credentials);
  const b64u = (v) => {
    const b = v instanceof ArrayBuffer ? new Uint8Array(v) : new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
    let s = ''; for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
    return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  };
  const bytes = (s) => {
    s = String(s).replace(/-/g, '+').replace(/_/g, '/'); while (s.length % 4) s += '=';
    const bin = atob(s), a = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) a[i] = bin.charCodeAt(i);
    return a.buffer;
  };
  const pending = new Map();
  let next = 0;
  window.__kvPasskeyResult = (id, c) => {
    const p = pending.get(id);
    if (!p) return;
    pending.delete(id);
    if (!c) { p.fallback(); return; }
    const response = { clientDataJSON: bytes(c.response.clientDataJSON), authenticatorData: bytes(c.response.authenticatorData),
      signature: bytes(c.response.signature), userHandle: c.response.userHandle ? bytes(c.response.userHandle) : null };
    if (window.AuthenticatorAssertionResponse) Object.setPrototypeOf(response, window.AuthenticatorAssertionResponse.prototype);
    const cred = { id: c.id, rawId: bytes(c.rawId || c.id), type: 'public-key', authenticatorAttachment: c.authenticatorAttachment || 'platform',
      response, getClientExtensionResults: () => c.clientExtensionResults || {}, toJSON: () => c };
    if (window.PublicKeyCredential) Object.setPrototypeOf(cred, window.PublicKeyCredential.prototype);
    p.resolve(cred);
  };
  navigator.credentials.get = function (options) {
    const pk = options && options.publicKey;
    // Autofill requests (conditional) and every request after the first go to the browser as usual
    if (!pk || options.mediation === 'conditional' || window.__kvPasskeyUsed) return original(options);
    window.__kvPasskeyUsed = true;
    return new Promise((resolve, reject) => {
      const id = ++next;
      pending.set(id, { resolve, fallback: () => original(options).then(resolve, reject) });
      window.chrome.webview.postMessage('webauthn:' + JSON.stringify({
        id, challenge: b64u(pk.challenge), rpId: pk.rpId || location.hostname,
        allow: (pk.allowCredentials || []).map((x) => b64u(x.id))
      }));
    });
  };
})();
'@

function Invoke-IntuneChocoBrowserSignIn {
    <#
    Runs the Microsoft sign-in (authorization code + PKCE) in an embedded browser window and returns the token
    response (access_token, refresh_token, expires_in, scope). $Fill gets the step ('username', 'password', 'otp')
    and returns the value to fill in, or $null to leave it to the user. Each value is filled in once (the one-time
    code twice at most), so a rejected password is not retried. Cookies live in a temporary profile only.
    #>
    param(
        [Parameter(Mandatory)][string]$TenantID,
        [Parameter(Mandatory)][string]$ClientID,
        [Parameter(Mandatory)][string]$CacheFolder,
        [string[]]$Scopes,
        [string]$LoginHint,
        [scriptblock]$Fill,
        [switch]$HasOtp,
        # Signs a passkey request: gets (origin, challenge, rpId, allowed credential ids) and returns the
        # PublicKeyCredential as object, or $null for the browser's own passkey dialog
        [scriptblock]$Passkey,
        [string]$Title = 'Sign in to Microsoft Intune',
        [string]$Hint,
        # Profile folder kept after the window closes (shared session) and the prompt: login (always ask) or select_account
        [string]$UserDataFolder,
        [ValidateSet("login", "select_account", "none")][string]$Prompt = "login",
        [System.Windows.Window]$Owner,
        # Tests: gets ($win, $wv) before the window opens (e.g. to render it off-screen)
        [scriptblock]$Configure
    )
    [void](Get-IntuneChocoWebView2 -CacheFolder $CacheFolder)
    Add-Type -AssemblyName System.Web

    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 32
    $rng.GetBytes($bytes); $verifier = ConvertTo-Base64Url $bytes
    $rng.GetBytes($bytes); $state = ConvertTo-Base64Url $bytes
    $sha = [Security.Cryptography.SHA256]::Create()
    $challenge = ConvertTo-Base64Url $sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier))
    $query = [ordered]@{
        client_id             = $ClientID
        response_type         = 'code'
        redirect_uri          = $script:SignInRedirect
        response_mode         = 'query'
        scope                 = (Get-SignInScopeString $Scopes)
        state                 = $state
        code_challenge        = $challenge
        code_challenge_method = 'S256'
        prompt                = $Prompt
    }
    if ($LoginHint) { $query.login_hint = $LoginHint }
    $url = "https://login.microsoftonline.com/$TenantID/oauth2/v2.0/authorize?" + (($query.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, [Uri]::EscapeDataString($_.Value) }) -join '&')

    # Window in the Windows 11 look of the tool: hint on top, browser in the middle, Cancel below; modal to the owner
    $brush = New-Object System.Windows.Media.BrushConverter
    $win = New-Object System.Windows.Window
    $win.Title = $Title
    $win.Width = 500; $win.Height = 700
    $win.Background = $brush.ConvertFrom('#F3F3F3')
    $win.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI Variable Text, Segoe UI')
    $win.ResizeMode = 'CanResize'
    $win.ShowInTaskbar = $true
    if ($Owner) { $win.Owner = $Owner; $win.WindowStartupLocation = 'CenterOwner' } else { $win.WindowStartupLocation = 'CenterScreen' }
    $grid = New-Object System.Windows.Controls.DockPanel
    if ($Hint) {
        $head = New-Object System.Windows.Controls.Border
        $head.Padding = '16,10'
        [System.Windows.Controls.DockPanel]::SetDock($head, 'Top')
        $text = New-Object System.Windows.Controls.TextBlock
        $text.Text = $Hint
        $text.Foreground = $brush.ConvertFrom('#5F5F5F')
        $text.TextWrapping = 'Wrap'; $text.FontSize = 12
        $head.Child = $text
        [void]$grid.Children.Add($head)
    }
    $foot = New-Object System.Windows.Controls.Border
    $foot.Padding = '16,10'; $foot.Background = $brush.ConvertFrom('#F7F7F7'); $foot.BorderBrush = $brush.ConvertFrom('#E5E5E5'); $foot.BorderThickness = '0,1,0,0'
    [System.Windows.Controls.DockPanel]::SetDock($foot, 'Bottom')
    $cancel = New-Object System.Windows.Controls.Button
    $cancel.Content = 'Cancel'; $cancel.HorizontalAlignment = 'Right'; $cancel.Padding = '18,6'; $cancel.IsCancel = $true
    $cancel.Add_Click({ $win.Close() })
    $foot.Child = $cancel
    [void]$grid.Children.Add($foot)

    $persistent = [bool]$UserDataFolder   # a shared profile keeps the Microsoft session between sign-ins of the same run (no second password)
    $userData = if ($persistent) { $UserDataFolder } else { Join-Path ([IO.Path]::GetTempPath()) ('IntuneChocoSignIn-' + [guid]::NewGuid().ToString('N')) }
    $wv = New-Object Microsoft.Web.WebView2.Wpf.WebView2
    $props = New-Object Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties
    $props.UserDataFolder = $userData
    $wv.CreationProperties = $props
    [void]$grid.Children.Add($wv)
    $win.Content = $grid

    $ctx = @{ Redirect = $null; Done = @{}; Otp = 0; ToPasskey = 0; PasskeyBusy = $false; Error = $null }
    $wv.Add_CoreWebView2InitializationCompleted({
        param($s, $e)
        if (-not $e.IsSuccess) { $ctx.Error = "The embedded browser could not start: $($e.InitializationException.Message)"; $win.Close(); return }
        $s.CoreWebView2.Settings.AreDevToolsEnabled = $false
        $s.CoreWebView2.Settings.IsStatusBarEnabled = $false
        if ($Passkey) { [void]$s.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync($script:PasskeyShimScript) }
    })
    $wv.Add_NavigationStarting({
        param($s, $e)
        if ($e.Uri.StartsWith($script:SignInRedirect, [StringComparison]::OrdinalIgnoreCase)) {
            $e.Cancel = $true
            $ctx.Redirect = $e.Uri
            $win.Close()
        }
    })
    $wv.Add_NavigationCompleted({ param($s, $e) [void]$s.ExecuteScriptAsync($script:SignInPageScript) })
    $wv.Add_WebMessageReceived({
        param($s, $e)
        # Values only go to Microsoft's sign-in pages
        $origin = try { ([Uri]$e.Source).Host } catch { '' }
        if ($origin -notin $script:SignInHosts) { return }
        $step = $e.TryGetWebMessageAsString()
        $js = { param($f, [string[]]$a) [void]$s.ExecuteScriptAsync("window.$f(" + (($a | ForEach-Object { ConvertTo-Json $_ -Compress }) -join ',') + ')') }
        if ($step -and $step.StartsWith('webauthn:')) {
            # Passkey request of the page: Keevault signs it (the user confirms in Keevault), else the browser dialog
            $req = $step.Substring(9) | ConvertFrom-Json
            $cred = $null
            if ($Passkey -and -not $ctx.PasskeyBusy) {
                $ctx.PasskeyBusy = $true
                try { $cred = & $Passkey ([Uri]$e.Source).GetLeftPart([UriPartial]::Authority) ([string]$req.challenge) ([string]$req.rpId) @($req.allow) }
                catch { Write-SignInLog "Keevault: passkey not signed ($($_.Exception.Message)). Windows asks for the passkey instead." 'Warning' }
                finally { $ctx.PasskeyBusy = $false }
            }
            $answer = if ($cred) { ConvertTo-Json $cred -Depth 6 -Compress } else { 'null' }
            [void]$s.ExecuteScriptAsync("window.__kvPasskeyResult($([int]$req.id), $answer)")
            return
        }
        switch ($step) {
            'to-passkey' {
                # Keevault has the passkey: take "Face, fingerprint, PIN or security key" instead of the password
                if (-not $Passkey -or $ctx.ToPasskey -ge 2) { return }
                $ctx.ToPasskey++
                [void]$s.ExecuteScriptAsync('window.__kvToPasskey()')
            }
            'username' {
                if ($ctx.Done.username -or -not $Fill) { return }
                $ctx.Done.username = $true
                $v = & $Fill 'username'
                if ($v) { & $js '__kvFill' 'input[name="loginfmt"]', $v, '#idSIButton9' }
            }
            'password' {
                if ($ctx.Done.password -or -not $Fill) { return }
                $ctx.Done.password = $true
                $v = & $Fill 'password'
                if ($v) { & $js '__kvFill' 'input[name="passwd"]', $v, '#idSIButton9' }
            }
            'otp' {
                if ($ctx.Otp -ge 2 -or -not $Fill) { return }
                $ctx.Otp++
                $v = & $Fill 'otp'
                if ($v) { & $js '__kvFill' 'input[name="otc"]', $v, '#idSubmit_SAOTCC_Continue' }
            }
            'kmsi' { & $js '__kvClick' '#idBtn_Back' }   # "Stay signed in?" -> No (the profile is temporary anyway)
            'choose-otp' {
                if (-not $HasOtp -or $ctx.Done.chooseOtp) { return }
                $ctx.Done.chooseOtp = $true
                & $js '__kvClick' '[data-value="PhoneAppOTP"]'
            }
            'another-way' {
                if (-not $HasOtp -or $ctx.Done.anotherWay) { return }
                $ctx.Done.anotherWay = $true
                & $js '__kvClick' '#signInAnotherWay'
            }
        }
    })
    # Come to the front even if another app (Keevault) has the focus right now
    $win.Add_ContentRendered({ if ($win.ShowActivated) { $win.Topmost = $true; [void]$win.Activate(); $win.Topmost = $false } })
    if ($Configure) { & $Configure $win $wv }
    $wv.Source = [Uri]$url
    try { [void]$win.ShowDialog() }
    finally {
        $wv.Dispose()
        if (-not $persistent) { Start-Sleep -Milliseconds 300 }
        if (-not $persistent) { Remove-Item $userData -Recurse -Force -ErrorAction SilentlyContinue }
    }

    if ($ctx.Error) { throw $ctx.Error }
    if (-not $ctx.Redirect) { throw 'Sign-in cancelled.' }
    $result = [System.Web.HttpUtility]::ParseQueryString(([Uri]$ctx.Redirect).Query)
    if ($result['error']) { throw "Sign-in failed: $($result['error_description'])" }
    if ($result['state'] -ne $state) { throw 'Sign-in failed: the answer does not belong to this sign-in.' }
    Request-IntuneChocoToken -TenantID $TenantID -ClientID $ClientID -Scopes $Scopes -Body @{
        grant_type    = 'authorization_code'
        code          = $result['code']
        redirect_uri  = $script:SignInRedirect
        code_verifier = $verifier
    }
}

# ---------------------------------------------------------------- Keevault sign-in
function Connect-IntuneChocoWithKeevault {
    <#
    Signs in to Microsoft Graph with an account from Keevault and returns the token response. Keevault asks the
    user to approve and pick the account (only accounts released for AI agents); the embedded sign-in fills in
    user name, password and one-time code. A fresh one-time code is requested from Keevault when the first one
    has expired. The caller hands the token to the IntuneWin32App module (Set-IntuneChocoToken).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantID,
        [Parameter(Mandatory)][string]$ClientID,
        [Parameter(Mandatory)][string]$CacheFolder,
        [string[]]$Scopes,
        [System.Windows.Window]$Owner,
        [scriptblock]$OnWait,
        # Gets the chosen user name and returns @{ TenantID; ClientID } to sign in with (an account of another
        # tenant needs that tenant's app registration), or throws to stop
        [scriptblock]$OnAccount
    )
    $client = Connect-KeevaultMcp -OnWait $OnWait
    try {
        $request = @{ purpose = "PackTune: sign in to Microsoft Intune (Graph), tenant $TenantID" }
        # Keevault lists the accounts of this tenant first (older versions show only those)
        if ($TenantID -match '\.' -and $TenantID -notmatch '^[0-9a-f-]{36}$') { $request.tenant = $TenantID }
        Write-SignInLog 'Keevault: choose the Microsoft account in Keevault ...'
        $login = Invoke-KeevaultMcpTool -Client $client -Name 'request_microsoft_login' -Arguments $request -OnWait $OnWait
        Write-SignInLog "Keevault: signing in as $($login.username) ($($login.title))."
        if ($OnAccount) {
            $target = & $OnAccount ([string]$login.username)
            if ($target.TenantID) { $TenantID = $target.TenantID }
            if ($target.ClientID) { $ClientID = $target.ClientID }
        }
        $creds = @{
            Username = [string]$login.username
            Password = [string]$login.password
            Otp      = [string]$login.totp
            OtpUntil = if ($login.totp) { (Get-Date).AddSeconds([int]$login.totpValidForSeconds - 3) } else { [datetime]::MinValue }
            Used     = $false
        }
        $fill = {
            param($step)
            switch ($step) {
                'username' { $creds.Username }
                'password' { $creds.Password }
                'otp' {
                    if (-not $creds.Otp) { return $null }
                    if ($creds.Used -or (Get-Date) -gt $creds.OtpUntil) {
                        try { $creds.Otp = [string](Invoke-KeevaultMcpTool -Client $client -Name 'get_totp' -Arguments @{ vaultId = $login.vaultId; entryId = $login.entryId } -TimeoutSeconds 120 -OnWait $OnWait).code }
                        catch { Write-SignInLog "Keevault: no new one-time code ($($_.Exception.Message))." 'Warning'; return $null }
                    }
                    $creds.Used = $true
                    $creds.Otp
                }
            }
        }
        # Entry with a passkey (or without password): Keevault signs the passkey request, the user confirms in Keevault
        $passkey = $null
        if ($login.passkey -or -not $login.password) {
            $passkey = {
                param($origin, $challenge, $rpId, $allow)
                Write-SignInLog 'Keevault: confirm the passkey sign-in in Keevault ...'
                $a = @{ vaultId = $login.vaultId; entryId = $login.entryId; origin = $origin; challenge = $challenge }
                if ($rpId) { $a.rpId = $rpId.ToLower() }
                $r = Invoke-KeevaultMcpTool -Client $client -Name 'sign_in_with_passkey' -Arguments $a -TimeoutSeconds 180 -OnWait $OnWait
                Write-SignInLog 'Keevault: passkey signed.'
                $r.credential
            }
        }
        $hint = if ($passkey) { "Keevault signs in $($login.username) with the passkey; confirm it in Keevault. You can type yourself or choose another sign-in method at any time." }
        else { "Keevault fills in the account $($login.username). You can type yourself or choose another sign-in method (e.g. a passkey) at any time." }
        $token = Invoke-IntuneChocoBrowserSignIn -TenantID $TenantID -ClientID $ClientID -CacheFolder $CacheFolder -Scopes $Scopes -LoginHint $login.username `
            -Fill $fill -HasOtp:([bool]$login.totp) -Passkey $passkey -Hint $hint -Owner $Owner -Title 'Sign in to Microsoft Intune with Keevault'
    }
    finally {
        if ($creds) { $creds.Password = $null; $creds.Otp = $null }
        Close-KeevaultMcp $client
    }
    # Where the sign-in went (another tenant when the account belongs to one)
    $token | Add-Member -NotePropertyName SignInTenantID -NotePropertyValue $TenantID -Force
    $token | Add-Member -NotePropertyName SignInClientID -NotePropertyValue $ClientID -Force
    $token
}

Export-ModuleMember -Function Set-IntuneChocoSignInLog, Find-KeevaultMcp, Connect-KeevaultMcp, Invoke-KeevaultMcpRequest, Invoke-KeevaultMcpTool, Close-KeevaultMcp,
    Get-IntuneChocoWebView2, Request-IntuneChocoToken, Invoke-IntuneChocoBrowserSignIn, Connect-IntuneChocoWithKeevault
