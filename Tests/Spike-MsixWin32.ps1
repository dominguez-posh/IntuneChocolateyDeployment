<#
.SYNOPSIS
    Phase 0 device-side spike of docs\plans\custom-applications.md: "MSIX inside a Win32 app", run fully automated in
    Windows Sandbox. No tenant, no network inside the sandbox.
.DESCRIPTION
    On the host: builds two tiny MSIX packages of the same app (1.0.0.0 and 1.0.1.0, publisher CN=PackTune Spike Test),
    each signed with its OWN new self-signed certificate (key non-exportable, deleted right after signing; the only
    thing this script ever puts into a host certificate store is that temporary certificate in CurrentUser\My, and it is
    deleted again). Generates the PackTune-style install, uninstall and detection scripts, writes a .wsb (networking off,
    inputs mapped read-only, a separate writable results folder) and starts it.
    In the sandbox the sequence runs AS SYSTEM (scheduled task, 32-bit PowerShell like the Intune Management Extension):
    negative test, detect, install v1, detect, update without the certificate (must fail), install v2 over v1, detect,
    uninstall, detect, install with a wrong certificate file (must fail). results.json and logs land in the results
    folder; the sandbox closes itself. The device scripts are never run on the host.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Spike-MsixWin32.ps1
#>
[CmdletBinding()]
param(
    # MSIX Sandbox Studio toolchain (makeappx, signtool)
    [string]$Toolchain = 'C:\git\WindowsSandboxMSIXInstaller\Workspace\Toolchain',
    [int]$TimeoutMinutes = 15,
    # Build everything but do not start the sandbox
    [switch]$BuildOnly,
    [switch]$KeepWork
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$makeappx = Join-Path $Toolchain 'SdkTools\makeappx.exe'
$signtool = Join-Path $Toolchain 'SdkTools\signtool.exe'
foreach ($tool in $makeappx, $signtool) { if (-not (Test-Path -LiteralPath $tool)) { throw "Not found: $tool (run Update-MsixToolchain of MSIX Sandbox Studio)" } }
if (-not $BuildOnly) {
    if (-not (Test-Path "$env:SystemRoot\System32\WindowsSandbox.exe")) { throw 'Windows Sandbox is not available on this machine (WindowsSandbox.exe missing). Stopping.' }
    if (Get-Process -Name WindowsSandbox, WindowsSandboxClient, WindowsSandboxRemoteSession -ErrorAction SilentlyContinue) { throw 'A Windows Sandbox is already running; Windows allows only one. Close it first.' }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneSpike-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$in = Join-Path $work 'in'
$out = Join-Path $work 'out'
New-Item -ItemType Directory -Path $in, $out -Force | Out-Null
Write-Host "Work folder: $work"

# The shared device script text (lock, protected folders, device log) comes from the real tool
$env:LOCALAPPDATA = Join-Path $work 'localappdata'
New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
. (Join-Path $repo 'ChocoIntuneDeployment-Main.ps1')

$Subject = 'CN=PackTune Spike Test'
$Identity = 'PackTune.SpikeTest'
$AppId = 'spiketest'

#region packages
function New-SpikeAssets([string]$Folder) {
    Add-Type -AssemblyName System.Drawing
    New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    foreach ($item in @(@('Store.png', 50), @('Square44.png', 44), @('Square150.png', 150))) {
        $bitmap = New-Object System.Drawing.Bitmap $item[1], $item[1]
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([System.Drawing.Color]::FromArgb(51, 102, 153))
        $graphics.Dispose()
        $bitmap.Save((Join-Path $Folder $item[0]), [System.Drawing.Imaging.ImageFormat]::Png)
        $bitmap.Dispose()
    }
}

function New-SpikeMsix {
    # Builds, signs (own certificate, key deleted right after) and returns path, public .cer and thumbprint
    param([string]$Version, [string]$Folder)
    $content = Join-Path $Folder 'content'
    New-Item -ItemType Directory -Path (Join-Path $content 'App') -Force | Out-Null
    New-SpikeAssets (Join-Path $content 'Assets')
    # A signed Microsoft program as the app's executable (the spike tests deployment, not the app)
    Copy-Item -LiteralPath "$env:SystemRoot\System32\whoami.exe" -Destination (Join-Path $content 'App\spike.exe')
    Set-Content -Path (Join-Path $content 'App\version.txt') -Value $Version -Encoding ASCII
    $manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10" xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities" IgnorableNamespaces="uap rescap">
  <Identity Name="$Identity" Publisher="$Subject" Version="$Version" ProcessorArchitecture="x64" />
  <Properties>
    <DisplayName>PackTune Spike Test</DisplayName>
    <PublisherDisplayName>PackTune</PublisherDisplayName>
    <Logo>Assets\Store.png</Logo>
  </Properties>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.17763.0" MaxVersionTested="10.0.22621.0" />
  </Dependencies>
  <Resources><Resource Language="en-us" /></Resources>
  <Applications>
    <Application Id="App" Executable="App\spike.exe" EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements DisplayName="PackTune Spike Test" Description="Spike" BackgroundColor="#336699" Square150x150Logo="Assets\Square150.png" Square44x44Logo="Assets\Square44.png" />
    </Application>
  </Applications>
  <Capabilities><rescap:Capability Name="runFullTrust" /></Capabilities>
</Package>
"@
    [IO.File]::WriteAllText((Join-Path $content 'AppxManifest.xml'), $manifest, (New-Object Text.UTF8Encoding $false))
    $msix = Join-Path $Folder 'package.msix'
    $log = & $makeappx pack /d $content /p $msix /o 2>&1
    if ($LASTEXITCODE -ne 0) { throw "makeappx failed: $($log | Out-String)" }

    # Own certificate per version: non-exportable key, deleted right after signing (also when anything fails)
    $cert = $null
    try {
        $cert = New-SelfSignedCertificate -Type Custom -Subject $Subject -KeyUsage DigitalSignature -KeyExportPolicy NonExportable `
            -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 -CertStoreLocation 'Cert:\CurrentUser\My' -NotAfter (Get-Date).AddYears(1) `
            -FriendlyName "PackTune spike $Version" -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
        [IO.File]::WriteAllBytes((Join-Path $Folder 'signing.cer'), $cert.Export('Cert'))
        # No timestamp: the spike has no network need; the plan requires one for the real feature
        $signLog = & $signtool sign /fd SHA256 /sha1 $cert.Thumbprint /s My $msix 2>&1
        if ($LASTEXITCODE -ne 0) { throw "signtool failed: $($signLog | Out-String)" }
        $thumbprint = $cert.Thumbprint
    }
    finally {
        if ($cert) { Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($cert.Thumbprint)" -DeleteKey -ErrorAction SilentlyContinue }
    }
    if ($cert -and (Test-Path -LiteralPath "Cert:\CurrentUser\My\$($cert.Thumbprint)")) { throw "The temporary signing certificate $($cert.Thumbprint) is still in CurrentUser\My" }
    Remove-Item -LiteralPath $content -Recurse -Force
    [pscustomobject]@{ Version = $Version; Msix = $msix; Cer = (Join-Path $Folder 'signing.cer'); Thumbprint = $thumbprint }
}
#endregion

#region device scripts (PackTune style, "MSIX inside a Win32 app")
function Get-CustomMsixScripts {
    param([string]$AppId, [string]$Identity, [string]$Version, [string]$Thumbprint)
    $Install = @'
# Installs or removes a custom MSIX delivered as a Win32 app (runs as SYSTEM through Intune): the public certificate
# of this version goes into LocalMachine\TrustedPeople, the package is provisioned for all users.
param([switch]$Uninstall)

# The Intune Management Extension starts 32-bit PowerShell; provisioning needs the 64-bit DISM cmdlets
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $Arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    if ($Uninstall) { $Arguments += "-Uninstall" }
    & "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe" @Arguments
    exit $LASTEXITCODE
}

$AppId = '__APPID__'
$Identity = '__IDENTITY__'
$Version = '__VERSION__'
$Thumbprint = '__THUMBPRINT__'
$LogId = "custom-$AppId"
$LogTag = if ($Uninstall) { "uninstall" } else { "install" }

__COMMON__

$CustomRoot = Join-Path $ToolRoot "Custom"
$AppRoot = Join-Path $CustomRoot $AppId
$Marker = Join-Path $AppRoot "version.txt"
try {
    Protect-Folder $ToolRoot
    Protect-Folder $CustomRoot
    Protect-Folder $AppRoot
}
catch { Write-Output "The folder $AppRoot could not be protected: $($_.Exception.Message)"; exit 1 }

function Test-TrustedCert([string]$Thumb) {
    $Store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPeople", "LocalMachine")
    $Store.Open("ReadOnly")
    try { return @($Store.Certificates | Where-Object { $_.Thumbprint -eq $Thumb }).Count -gt 0 } finally { $Store.Close() }
}
function Remove-TrustedCert([string]$Thumb) {
    $Store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPeople", "LocalMachine")
    $Store.Open("ReadWrite")
    try { foreach ($Found in @($Store.Certificates | Where-Object { $_.Thumbprint -eq $Thumb })) { $Store.Remove($Found) } } finally { $Store.Close() }
}
function Get-CertReferences([string]$Thumb) {
    # Other custom apps of this tool whose marker names the certificate (it stays while one still needs it)
    $Count = 0
    foreach ($Folder in @(Get-ChildItem -LiteralPath $CustomRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $AppId })) {
        $Other = Join-Path $Folder.FullName "version.txt"
        if (Test-Path -LiteralPath $Other) { if ((Get-Content -LiteralPath $Other -Raw).Trim().Split("|")[2] -eq $Thumb) { $Count++ } }
    }
    return $Count
}
function Get-Provisioned { @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $Identity }) }

if (-not (Enter-DeploymentLock)) { Write-Output "Another installation is still running"; Write-DeviceLog "another installation is still running, Intune tries again"; exit 1618 }
try {
    $OldThumb = $null
    if (Test-Path -LiteralPath $Marker) { $OldThumb = (Get-Content -LiteralPath $Marker -Raw).Trim().Split("|")[2] }

    if ($Uninstall) {
        foreach ($Package in @(Get-Provisioned)) { Remove-AppxProvisionedPackage -Online -PackageName $Package.PackageName -ErrorAction Stop | Out-Null }
        foreach ($Package in @(Get-AppxPackage -AllUsers -Name $Identity -ErrorAction SilentlyContinue)) { Remove-AppxPackage -Package $Package.PackageFullName -AllUsers -ErrorAction SilentlyContinue }
        if (@(Get-Provisioned).Count -gt 0) { Write-DeviceLog "uninstall: package is still provisioned"; exit 1 }
        # Only this version's certificate, and only when no other custom app of the tool still needs it
        $Own = if ($OldThumb) { $OldThumb } else { $Thumbprint }
        if ((Get-CertReferences $Own) -eq 0) { Remove-TrustedCert $Own; Write-DeviceLog "certificate $Own removed" } else { Write-DeviceLog "certificate $Own is still used by another app, kept" }
        Remove-Item -LiteralPath $Marker -Force -ErrorAction SilentlyContinue
        Write-DeviceLog "uninstalled $Identity"
        exit 0
    }

    # Copy next to the protected folder first: the Intune cache folder is not ours
    $Staging = Join-Path $AppRoot "staging"
    Protect-Folder $Staging
    foreach ($Name in "package.msix", "signing.cer") { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $Name) -Destination $Staging -Force }
    $Msix = Join-Path $Staging "package.msix"
    $Cer = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (Join-Path $Staging "signing.cer")
    if ($Cer.Thumbprint -ne $Thumbprint) { Write-Output "signing.cer is not the certificate of this version"; Write-DeviceLog "certificate file does not match the version, nothing installed"; exit 1 }
    $Signature = Get-AuthenticodeSignature -LiteralPath $Msix
    if (-not $Signature.SignerCertificate -or $Signature.SignerCertificate.Thumbprint -ne $Thumbprint -or [string]$Signature.Status -in "HashMismatch", "NotSigned") {
        Write-Output "The package is not signed by the certificate of this version (status $($Signature.Status))"
        Write-DeviceLog "package signature does not match the version certificate, nothing installed"
        exit 1
    }

    $Had = Test-TrustedCert $Thumbprint
    if (-not $Had) {
        $Store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPeople", "LocalMachine")
        $Store.Open("ReadWrite"); $Store.Add($Cer); $Store.Close()
        Write-DeviceLog "certificate $Thumbprint added to TrustedPeople"
    }
    try {
        try { Add-AppxProvisionedPackage -Online -PackagePath $Msix -SkipLicense -ErrorAction Stop | Out-Null }
        catch {
            # A lower version may have to go first
            Write-DeviceLog "provisioning failed ($($_.Exception.Message)), removing the provisioned version and trying again"
            foreach ($Package in @(Get-Provisioned)) { Remove-AppxProvisionedPackage -Online -PackageName $Package.PackageName -ErrorAction Stop | Out-Null }
            Add-AppxProvisionedPackage -Online -PackagePath $Msix -SkipLicense -ErrorAction Stop | Out-Null
            Write-Output "NEEDED-REMOVE-FIRST"
        }
    }
    catch {
        Write-Output "Provisioning failed: $($_.Exception.Message)"
        Write-DeviceLog "provisioning failed: $($_.Exception.Message)"
        if (-not $Had -and (Get-CertReferences $Thumbprint) -eq 0 -and $OldThumb -ne $Thumbprint) { Remove-TrustedCert $Thumbprint }
        exit 1
    }
    Write-ProtectedFile $Marker "$Identity|$Version|$Thumbprint"
    # An update leaves the earlier version's certificate behind: remove it when nothing needs it any more
    if ($OldThumb -and $OldThumb -ne $Thumbprint -and (Get-CertReferences $OldThumb) -eq 0) { Remove-TrustedCert $OldThumb; Write-DeviceLog "certificate $OldThumb of the earlier version removed" }
    Remove-Item -LiteralPath $Staging -Recurse -Force -ErrorAction SilentlyContinue
    Write-DeviceLog "installed $Identity $Version"
    exit 0
}
finally { Exit-DeploymentLock }
'@
    $Detect = @'
# Detection: the package is provisioned with this version or newer (no time dependency)
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    & "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$PSCommandPath"
    exit $LASTEXITCODE
}
$Identity = '__IDENTITY__'
$Version = '__VERSION__'
$Found = @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $Identity }) | Select-Object -First 1
if (-not $Found) { exit 1 }
try { if ([version]$Found.Version -ge [version]$Version) { Write-Output "$Identity $($Found.Version) is provisioned"; exit 0 } } catch { }
exit 1
'@
    $Common = Get-DeviceScriptCommon
    $Fill = { param($Text) $Text.Replace('__COMMON__', $Common).Replace('__APPID__', $AppId).Replace('__IDENTITY__', $Identity).Replace('__VERSION__', $Version).Replace('__THUMBPRINT__', $Thumbprint) }
    [pscustomobject]@{ Install = (& $Fill $Install); Detect = (& $Fill $Detect) }
}
#endregion

#region sandbox side
$Inner = @'
# Runs inside the sandbox AS SYSTEM (scheduled task): the whole sequence, results to C:\Spike\Out
$ErrorActionPreference = 'Continue'
$Out = 'C:\Spike\Out'
$Work = 'C:\Spike\Work'
$Plan = Get-Content (Join-Path $Work 'plan.json') -Raw | ConvertFrom-Json
Start-Transcript -Path (Join-Path $Out 'inner-transcript.txt') -Force | Out-Null
$Results = New-Object System.Collections.ArrayList
$Info = [ordered]@{}
$Ps32 = "$env:SystemRoot\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
$StepNo = 0
function Add-Result([string]$Name, [bool]$Ok, [string]$Detail) {
    [void]$Results.Add([ordered]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
    Write-Host ("{0}  {1}  {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail)
}
function Invoke-Device([string]$Folder, [string]$Script, [string[]]$ScriptArgs = @()) {
    # Like the Intune Management Extension: 32-bit Windows PowerShell, the package folder as current directory
    $script:StepNo++
    $Log = Join-Path $Out ("step{0:00}-{1}-{2}.log" -f $script:StepNo, (Split-Path $Folder -Leaf), $Script)
    Push-Location (Join-Path $Work $Folder)
    $Text = & $Ps32 -NoProfile -ExecutionPolicy Bypass -File (Join-Path (Join-Path $Work $Folder) $Script) @ScriptArgs 2>&1 | Out-String
    $Code = $LASTEXITCODE
    Pop-Location
    Set-Content -Path $Log -Value $Text
    [pscustomobject]@{ Code = $Code; Output = $Text.Trim() }
}
function Get-Certs { @(Get-ChildItem Cert:\LocalMachine\TrustedPeople | Where-Object { $_.Subject -eq $Plan.Subject } | ForEach-Object { $_.Thumbprint }) }
function Get-Prov { @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $Plan.Identity }) }
function Get-ProvVersion { $p = Get-Prov | Select-Object -First 1; if ($p) { [string]$p.Version } else { '' } }
function Try-Add([string]$Msix) { try { Add-AppxProvisionedPackage -Online -PackagePath $Msix -SkipLicense -ErrorAction Stop | Out-Null; $true } catch { $script:LastError = $_.Exception.Message; $false } }
$A = $Plan.V1.Thumbprint; $B = $Plan.V2.Thumbprint
$Info.Windows = (Get-CimInstance Win32_OperatingSystem).Caption + ' ' + (Get-CimInstance Win32_OperatingSystem).BuildNumber
$Info.User = whoami

try {
    # 0 start state
    Add-Result 'start: no certificate of the subject in TrustedPeople, nothing provisioned' ((Get-Certs).Count -eq 0 -and (Get-Prov).Count -eq 0) "certs=$((Get-Certs) -join ',')"

    # N1 v1 without any trust must not install
    $ok = Try-Add (Join-Path $Work 'v1\package.msix')
    Add-Result 'negative: provisioning v1 without its certificate fails' (-not $ok -and (Get-Prov).Count -eq 0) "ok=$ok error=$script:LastError"
    $Info.N1Error = $script:LastError

    # detect before install
    $r = Invoke-Device 'v1' 'detect.ps1'
    Add-Result 'detect before install: not installed (exit 1)' ($r.Code -eq 1) "exit=$($r.Code)"

    # install v1
    $r = Invoke-Device 'v1' 'install.ps1'
    Add-Result 'install v1: exit 0' ($r.Code -eq 0) "exit=$($r.Code) $($r.Output)"
    Add-Result 'install v1: provisioned with 1.0.0.0' ((Get-ProvVersion) -eq '1.0.0.0') "version=$(Get-ProvVersion)"
    Add-Result 'install v1: certificate A in TrustedPeople' ((Get-Certs) -contains $A) "certs=$((Get-Certs) -join ',')"
    $r = Invoke-Device 'v1' 'detect.ps1'
    Add-Result 'detect v1 after install (exit 0)' ($r.Code -eq 0) "exit=$($r.Code) $($r.Output)"
    $Info.AfterV1_AllUsers = @(Get-AppxPackage -AllUsers -Name $Plan.Identity -ErrorAction SilentlyContinue | ForEach-Object { "$($_.PackageFullName) status=$($_.Status)" })
    $Info.AfterV1_Users = @(Get-AppxPackage -AllUsers -Name $Plan.Identity -ErrorAction SilentlyContinue | ForEach-Object { $_.PackageUserInformation | ForEach-Object { "$($_.UserSecurityId.Sid) $($_.InstallState)" } })

    # N3 update without its certificate must fail, v1 stays
    $ok = Try-Add (Join-Path $Work 'v2\package.msix')
    Add-Result 'negative: update to v2 without certificate B fails, v2 not provisioned' (-not $ok -and (Get-ProvVersion) -ne '1.0.1.0') "ok=$ok version=$(Get-ProvVersion) error=$script:LastError"
    $Info.N3Error = $script:LastError
    $Info.AfterN3_Provisioned = @(Get-Prov | ForEach-Object { "$($_.PackageName) v=$($_.Version)" })
    $Info.AfterN3_AllUsers = @(Get-AppxPackage -AllUsers -Name $Plan.Identity -ErrorAction SilentlyContinue | ForEach-Object { "$($_.PackageFullName) status=$($_.Status)" })
    $r = Invoke-Device 'v1' 'detect.ps1'
    $Info.FindingFailedUpdate = "detect v1 after the failed update: exit $($r.Code) (provisioned list empty = $((Get-Prov).Count -eq 0)); the installed package for the existing user stays"

    # install v2 over v1 through the script
    $r = Invoke-Device 'v2' 'install.ps1'
    Add-Result 'update: install v2 over v1, exit 0' ($r.Code -eq 0) "exit=$($r.Code) $($r.Output)"
    $Info.UpdateNeededRemoveFirst = ($r.Output -match 'NEEDED-REMOVE-FIRST')
    Add-Result 'update: provisioned with 1.0.1.0' ((Get-ProvVersion) -eq '1.0.1.0') "version=$(Get-ProvVersion)"
    Add-Result 'update: certificate B present, certificate A of the old version removed' ((Get-Certs) -contains $B -and -not ((Get-Certs) -contains $A)) "certs=$((Get-Certs) -join ',')"
    $r = Invoke-Device 'v2' 'detect.ps1'
    Add-Result 'detect v2 after update (exit 0)' ($r.Code -eq 0) "exit=$($r.Code) $($r.Output)"
    $Info.AfterV2_AllUsers = @(Get-AppxPackage -AllUsers -Name $Plan.Identity -ErrorAction SilentlyContinue | ForEach-Object { "$($_.PackageFullName) status=$($_.Status)" })

    # uninstall
    $r = Invoke-Device 'v2' 'install.ps1' @('-Uninstall')
    Add-Result 'uninstall: exit 0' ($r.Code -eq 0) "exit=$($r.Code) $($r.Output)"
    $r = Invoke-Device 'v2' 'detect.ps1'
    Add-Result 'detect after uninstall: not installed (exit 1)' ($r.Code -eq 1) "exit=$($r.Code)"
    Add-Result 'uninstall: nothing provisioned, no certificate of the subject left' ((Get-Prov).Count -eq 0 -and (Get-Certs).Count -eq 0) "prov=$((Get-Prov).Count) certs=$((Get-Certs) -join ',')"
    Add-Result 'uninstall: marker removed' (-not (Test-Path (Join-Path $env:ProgramFiles 'IntuneChocoDeployment\Custom\spiketest\version.txt'))) ''

    # N2 v2 package with the certificate file of v1 must be refused by the script
    Copy-Item (Join-Path $Work 'v1\signing.cer') (Join-Path $Work 'v2\signing.cer') -Force
    $r = Invoke-Device 'v2' 'install.ps1'
    Add-Result 'negative: wrong certificate file is refused, nothing provisioned, no certificate added' ($r.Code -ne 0 -and (Get-Prov).Count -eq 0 -and (Get-Certs).Count -eq 0) "exit=$($r.Code) $($r.Output)"
}
catch { Add-Result 'sequence ran without an unexpected error' $false $_.Exception.Message }

$failed = @($Results | Where-Object { -not $_.Ok }).Count
$Final = [ordered]@{ Passed = ($failed -eq 0); Failed = $failed; Total = $Results.Count; Results = $Results; Info = $Info }
Stop-Transcript | Out-Null
($Final | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $Out 'results.tmp')
Move-Item (Join-Path $Out 'results.tmp') (Join-Path $Out 'results.json') -Force
'@

$Bootstrap = @'
# Logon command of the sandbox (user WDAGUtilityAccount): copy the inputs to a local folder (services cannot read mapped
# folders), run the sequence as SYSTEM through a scheduled task, wait for the result, close the sandbox.
$In = 'C:\Spike\In'; $Work = 'C:\Spike\Work'; $Out = 'C:\Spike\Out'
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Copy-Item -Path (Join-Path $In '*') -Destination $Work -Recurse -Force
try {
    $Action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File $Work\inner.ps1"
    $Principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'PackTuneSpike' -Action $Action -Principal $Principal -Force | Out-Null
    Start-ScheduledTask -TaskName 'PackTuneSpike'
}
catch { Set-Content (Join-Path $Out 'bootstrap-error.txt') $_.Exception.Message }
for ($i = 0; $i -lt 600 -and -not (Test-Path (Join-Path $Out 'results.json')); $i++) { Start-Sleep -Seconds 2 }
if (-not (Test-Path (Join-Path $Out 'results.json'))) { Set-Content (Join-Path $Out 'results.json') '{"Passed":false,"Failed":1,"Total":0,"Results":[],"Info":{"Error":"no result from the sequence"}}' }
Start-Sleep -Seconds 3
shutdown.exe /s /t 0
'@
#endregion

$cleanup = { if (-not $KeepWork) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } else { Write-Host "Kept: $work" } }
try {
    Write-Host 'Building the two test packages (own certificate each, keys deleted after signing) ...'
    $v1 = New-SpikeMsix -Version '1.0.0.0' -Folder (Join-Path $in 'v1')
    $v2 = New-SpikeMsix -Version '1.0.1.0' -Folder (Join-Path $in 'v2')
    if ($v1.Thumbprint -eq $v2.Thumbprint) { throw 'Both versions got the same certificate' }
    foreach ($v in $v1, $v2) {
        $scripts = Get-CustomMsixScripts -AppId $AppId -Identity $Identity -Version $v.Version -Thumbprint $v.Thumbprint
        $folder = Split-Path $v.Msix -Parent
        Set-Content -Path (Join-Path $folder 'install.ps1') -Value $scripts.Install -Encoding ASCII
        Set-Content -Path (Join-Path $folder 'detect.ps1') -Value $scripts.Detect -Encoding ASCII
        foreach ($name in 'install.ps1', 'detect.ps1') {
            $path = Join-Path $folder $name
            $errors = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
            $text = Get-Content $path -Raw
            if ($errors.Count -gt 0 -or $text -match '[^\x00-\x7F]' -or $text -match '__[A-Z]+__') { throw "Generated $name of $($v.Version) is invalid (parse errors: $($errors.Count))" }
        }
    }
    @{ Subject = $Subject; Identity = $Identity; V1 = @{ Thumbprint = $v1.Thumbprint }; V2 = @{ Thumbprint = $v2.Thumbprint } } | ConvertTo-Json | Set-Content (Join-Path $in 'plan.json') -Encoding ASCII
    Set-Content -Path (Join-Path $in 'inner.ps1') -Value $Inner -Encoding ASCII
    Set-Content -Path (Join-Path $in 'bootstrap.ps1') -Value $Bootstrap -Encoding ASCII
    $esc = { param($s) [Security.SecurityElement]::Escape($s) }
    $wsb = @"
<Configuration>
  <vGPU>Disable</vGPU>
  <Networking>Disable</Networking>
  <MemoryInMB>4096</MemoryInMB>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$(& $esc $in)</HostFolder>
      <SandboxFolder>C:\Spike\In</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$(& $esc $out)</HostFolder>
      <SandboxFolder>C:\Spike\Out</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Spike\In\bootstrap.ps1</Command>
  </LogonCommand>
</Configuration>
"@
    $wsbPath = Join-Path $work 'spike.wsb'
    Set-Content -Path $wsbPath -Value $wsb -Encoding UTF8
    Write-Host "Built. v1 certificate $($v1.Thumbprint), v2 certificate $($v2.Thumbprint) (private keys already deleted)."
    if ($BuildOnly) { Write-Host "BuildOnly: $wsbPath"; $KeepWork = $true; return }

    Write-Host 'Starting Windows Sandbox (no network; the sequence runs as SYSTEM) ...'
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsSandbox.exe" -ArgumentList "`"$wsbPath`""
    $resultFile = Join-Path $out 'results.json'
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while (-not (Test-Path $resultFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 3 }
    if (-not (Test-Path $resultFile)) {
        $KeepWork = $true
        throw "No results.json within $TimeoutMinutes minutes. Look at $out (inner-transcript.txt, step logs) and close the sandbox by hand."
    }
    Start-Sleep -Seconds 2
    $result = Get-Content $resultFile -Raw | ConvertFrom-Json
    Write-Host ''
    foreach ($r in @($result.Results)) { Write-Host ('{0}  {1}' -f $(if ($r.Ok) { 'PASS' } else { 'FAIL' }), $r.Name); if (-not $r.Ok -or $VerbosePreference -eq 'Continue') { Write-Host "      $($r.Detail)" } }
    Write-Host ''
    Write-Host 'Observed in the sandbox:'
    $result.Info | ConvertTo-Json -Depth 5 | Write-Host
    Write-Host ''
    if ($result.Passed) { Write-Host "SPIKE PASSED: $($result.Total) checks" -ForegroundColor Green } else { Write-Host "SPIKE FAILED: $($result.Failed) of $($result.Total) checks failed (logs: $out)" -ForegroundColor Red; $KeepWork = $true }
    # The sandbox closes itself; wait a moment
    for ($i = 0; $i -lt 30 -and (Get-Process -Name WindowsSandbox, WindowsSandboxClient, WindowsSandboxRemoteSession -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 2 }
    if (-not $result.Passed) { exit 1 }
}
finally { & $cleanup }
