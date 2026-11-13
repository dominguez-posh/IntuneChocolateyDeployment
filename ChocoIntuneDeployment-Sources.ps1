<#
    One app list for both sources (Chocolatey and winget), and the winget runtime dependency app.
    Loaded by ChocoIntuneDeployment-Main.ps1, uses its helpers (catalog, feeds, Invoke-IntuneModule, packaging).

    A "row" is one app as a person sees it: the same software, with the id it has in each source, the current
    version from each feed, the sources it is available from and the recommended source (the higher version).
    The package infos come from the same cache the interface keeps (feedcache.json, key "<chocolatey id>" and
    "winget:<id>", all lower case): pass it as -Cache (a hashtable of these entries) and nothing is asked twice;
    entries that are missing are read from the feeds and put into the cache.
#>

$script:Sources = "Chocolatey", "Winget"
$script:SourceFilters = "All", "Winget", "Chocolatey", "Both"
$script:WingetRuntimeMarker = "WingetRuntimeApp"
$script:WingetRuntimeName = "winget runtime"
# Raised when the install or detection script of the runtime app changes (part of its detection)
$script:WingetRuntimeRevision = 1

#region versions and recommendation

function ConvertTo-SourceVersionParts {
    param([string]$Text)
    # "1.2.3", "v1.2.3-beta", "26.05" -> numbers; anything that does not start with numbers is unknown ($null)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $Core = (($Text.Trim() -replace '^[vV]', '') -split '[-+\s]')[0]
    if ($Core -notmatch '^\d+(\.\d+)*$') { return $null }
    return @($Core.Split('.') | ForEach-Object { [decimal]$_ })
}

function Compare-SourceVersion {
    # Part by part as numbers (1.10 > 1.9, 1.2 = 1.2.0). Returns 1, 0, -1, or $null when one of them is unknown.
    param([string]$A, [string]$B)
    $PartsA = ConvertTo-SourceVersionParts $A
    $PartsB = ConvertTo-SourceVersionParts $B
    if ($null -eq $PartsA -or $null -eq $PartsB) { return $null }
    $Length = [Math]::Max($PartsA.Count, $PartsB.Count)
    for ($i = 0; $i -lt $Length; $i++) {
        $X = if ($i -lt $PartsA.Count) { $PartsA[$i] } else { 0 }
        $Y = if ($i -lt $PartsB.Count) { $PartsB[$i] } else { 0 }
        if ($X -gt $Y) { return 1 }
        if ($X -lt $Y) { return -1 }
    }
    return 0
}

function Get-RecommendedSource {
    <#
        Two sources: the one with the higher version is recommended and marked; equal or unknown versions give no
        recommendation. One source only: that source, but not marked (there is nothing to compare).
    #>
    param([bool]$HasChocolatey, [bool]$HasWinget, [string]$ChocolateyVersion, [string]$WingetVersion)
    if ($HasChocolatey -and -not $HasWinget) { return [pscustomobject]@{ Source = "Chocolatey"; Marked = $false } }
    if ($HasWinget -and -not $HasChocolatey) { return [pscustomobject]@{ Source = "Winget"; Marked = $false } }
    if (-not $HasChocolatey -and -not $HasWinget) { return [pscustomobject]@{ Source = $null; Marked = $false } }
    $Compare = Compare-SourceVersion -A $ChocolateyVersion -B $WingetVersion
    if ($Compare -eq 1) { return [pscustomobject]@{ Source = "Chocolatey"; Marked = $true } }
    if ($Compare -eq -1) { return [pscustomobject]@{ Source = "Winget"; Marked = $true } }
    return [pscustomobject]@{ Source = $null; Marked = $false }
}#Which source to recommend for an app

function Get-IntuneChocoDefaultSource {
    # What a deployment uses when nobody chose: the recommended source, else the preferred source of the settings
    # (when the app has it), else the one source the app has
    param([Parameter(Mandatory = $true)]$Row, [string]$Preferred = $script:Settings.Source)
    if ($Row.Recommended) { return $Row.Recommended }
    $Available = @($Row.Sources)
    if ($Preferred -and $Preferred -in $Available) { return $Preferred }
    return ($Available | Select-Object -First 1)
}#Source a deployment uses by default

#endregion

#region package infos from cache or feed

function Get-SourceCacheKey([string]$Source, [string]$Id) {
    if ($Source -eq "Winget") { return "winget:$($Id.ToLower())" }
    return $Id.ToLower()
}

function Resolve-IntuneChocoSourceInfo {
    <#
        Version of one package in one source: from the cache, otherwise from the feed (and into the cache).
        Available = $false only when the source says it has no such package; an unreachable feed leaves the package
        available with an unknown version.
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet("Chocolatey", "Winget")][string]$Source,
        [Parameter(Mandatory = $true)][string]$Id,
        [hashtable]$Cache,
        [switch]$NoFetch
    )
    $Key = Get-SourceCacheKey $Source $Id
    $Entry = if ($Cache) { $Cache[$Key] } else { $null }
    if ($Entry -and ($Entry.Found -or $Entry.NotFound)) {
        return [pscustomobject]@{ Source = $Source; Id = $Id; Available = [bool]$Entry.Found; Version = $(if ($Entry.Found) { [string]$Entry.Version } else { $null }); Title = $Entry.Title; FromCache = $true }
    }
    if ($NoFetch) { return [pscustomobject]@{ Source = $Source; Id = $Id; Available = $true; Version = $null; Title = $null; FromCache = $false } }
    try {
        $Info = if ($Source -eq "Winget") { Get-WingetInfo -WingetId $Id } else { Get-ChocoInfo -ChocoName $Id }
        if ($Cache) {
            $Cache[$Key] = [pscustomobject]@{
                Fetched = (Get-Date).ToString("o"); Found = $true; Name = $Info.Name; Title = $Info.Title; Version = $Info.Version
                Summary = $Info.Summary; Description = $Info.Description; Authors = $Info.Authors; IconUrl = $Info.IconUrl
                ProjectUrl = $Info.SoftwareSite; LicenseUrl = $Info.SoftwareLicense; Downloads = $Info.Downloads; LicenseNote = $Info.LicenseNote
                License = $Info.License; Partial = $false
            }
        }
        return [pscustomobject]@{ Source = $Source; Id = $Id; Available = $true; Version = [string]$Info.Version; Title = $Info.Title; FromCache = $false }
    }
    catch {
        $NotFound = $_.Exception.Message -like "*was not found*"
        if ($Cache -and $NotFound) { $Cache[$Key] = [pscustomobject]@{ Fetched = (Get-Date).ToString("o"); Found = $false; NotFound = $true; Name = $Id; Error = $_.Exception.Message } }
        return [pscustomobject]@{ Source = $Source; Id = $Id; Available = (-not $NotFound); Version = $null; Title = $null; FromCache = $false }
    }
}#Version of a package from the cache or the feed

function New-IntuneChocoSourceRow {
    # Builds the row of one app from what is known; only the ids that exist count as sources
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Category,
        [string]$CatalogId,
        [string]$ChocoId,
        [string]$WingetId,
        [string]$ChocoVersion,
        [string]$WingetVersion,
        [bool]$ChocoAvailable = $true,
        [bool]$WingetAvailable = $true
    )
    $HasChoco = [bool]$ChocoId -and $ChocoAvailable
    $HasWinget = [bool]$WingetId -and $WingetAvailable
    $Recommendation = Get-RecommendedSource -HasChocolatey $HasChoco -HasWinget $HasWinget -ChocolateyVersion $ChocoVersion -WingetVersion $WingetVersion
    $Row = [pscustomobject]@{
        Name              = $Name
        Category          = $Category
        CatalogId         = $CatalogId
        ChocoId           = $(if ($HasChoco) { $ChocoId } else { $null })
        WingetId          = $(if ($HasWinget) { $WingetId } else { $null })
        ChocoVersion      = $(if ($HasChoco) { $ChocoVersion } else { $null })
        WingetVersion     = $(if ($HasWinget) { $WingetVersion } else { $null })
        Sources           = @(@($(if ($HasChoco) { "Chocolatey" }), $(if ($HasWinget) { "Winget" })) | Where-Object { $_ })
        Recommended       = $Recommendation.Source
        RecommendedMarked = $Recommendation.Marked
        Source            = $null
    }
    # Source = what a deployment of this row uses (the person can change it per app)
    $Row.Source = Get-IntuneChocoDefaultSource -Row $Row
    return $Row
}#One app with the ids, versions and recommendation of both sources

function Get-IntuneChocoSourceApps {
    <#
        The curated catalog as one list: per app the sources it is available from, the current version of each
        (cache, then feed) and the recommended source. -NoFetch uses only what is in the cache.
    #>
    param([hashtable]$Cache, [switch]$NoFetch, [ValidateSet("All", "Winget", "Chocolatey", "Both")][string]$Filter = "All")
    $Rows = foreach ($Entry in @(Get-IntuneChocoCatalog)) {
        $Choco = if ($Entry.Id) { Resolve-IntuneChocoSourceInfo -Source Chocolatey -Id $Entry.Id -Cache $Cache -NoFetch:$NoFetch }
        $Winget = if ($Entry.WingetId) { Resolve-IntuneChocoSourceInfo -Source Winget -Id $Entry.WingetId -Cache $Cache -NoFetch:$NoFetch }
        New-IntuneChocoSourceRow -Name $Entry.Name -Category $Entry.Category -CatalogId $Entry.Id -ChocoId $Entry.Id -WingetId $Entry.WingetId `
            -ChocoVersion $(if ($Choco) { $Choco.Version }) -WingetVersion $(if ($Winget) { $Winget.Version }) `
            -ChocoAvailable $(if ($Choco) { $Choco.Available } else { $false }) -WingetAvailable $(if ($Winget) { $Winget.Available } else { $false })
    }
    return @(Select-IntuneChocoSourceApps -Apps @($Rows) -Filter $Filter)
}#The catalog with both sources per app

function Select-IntuneChocoSourceApps {
    <#
        Filter of the app list: All, Winget (apps only winget has), Chocolatey (apps only Chocolatey has),
        Both (apps available from both sources).
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()]$Apps, [ValidateSet("All", "Winget", "Chocolatey", "Both")][string]$Filter = "All")
    $Apps = @($Apps)
    switch ($Filter) {
        "Winget" { return @($Apps | Where-Object { @($_.Sources).Count -eq 1 -and $_.Sources -contains "Winget" }) }
        "Chocolatey" { return @($Apps | Where-Object { @($_.Sources).Count -eq 1 -and $_.Sources -contains "Chocolatey" }) }
        "Both" { return @($Apps | Where-Object { @($_.Sources).Count -eq 2 }) }
        default { return $Apps }
    }
}#All / winget only / Chocolatey only / both

#endregion

#region search across both sources

function Search-IntuneChocoApps {
    <#
        Searches Chocolatey and winget and merges the hits per app: hits that belong to the same catalog entry (its
        Chocolatey id and its winget id) become one row, everything else stays a row of its own. The other source of a
        catalog app is looked up for its version even when the search did not return it. A source that cannot be
        reached gives a warning; the other one still answers.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SearchPattern,
        [int]$Top = 30,
        [hashtable]$Cache,
        [switch]$NoFetch,
        [ValidateSet("All", "Winget", "Chocolatey", "Both")][string]$Filter = "All"
    )
    $Catalog = @(Get-IntuneChocoCatalog)
    $ByChoco = @{}; $ByWinget = @{}
    foreach ($Entry in $Catalog) {
        if ($Entry.Id) { $ByChoco[$Entry.Id.ToLower()] = $Entry }
        if ($Entry.WingetId) { $ByWinget[$Entry.WingetId.ToLower()] = $Entry }
    }
    $ChocoHits = @(); $WingetHits = @()
    try { $ChocoHits = @(Search-ChocoPackage -SearchPattern $SearchPattern -Top $Top) } catch { Write-Warning "Chocolatey search failed: $($_.Exception.Message)" }
    try { $WingetHits = @(Search-WingetPackage -SearchPattern $SearchPattern -Top $Top) } catch { Write-Warning "winget search failed: $($_.Exception.Message)" }

    # Merge: key = catalog entry, or the package of its own source
    $Merged = [ordered]@{}
    $Get = {
        param($Key)
        if (-not $Merged.Contains($Key)) { $Merged[$Key] = @{ Entry = $null; ChocoId = $null; ChocoVersion = $null; WingetId = $null; WingetVersion = $null; Title = $null } }
        $Merged[$Key]
    }
    foreach ($Hit in $ChocoHits) {
        $Entry = $ByChoco[([string]$Hit.Name).ToLower()]
        $Slot = & $Get $(if ($Entry) { "catalog:$($Entry.Id.ToLower())" } else { "chocolatey:$(([string]$Hit.Name).ToLower())" })
        $Slot.Entry = $Entry; $Slot.ChocoId = $Hit.Name; $Slot.ChocoVersion = $Hit.Version; if (-not $Slot.Title) { $Slot.Title = $Hit.Title }
        if ($Entry) { $Slot.WingetId = $Entry.WingetId }
    }
    foreach ($Hit in $WingetHits) {
        $Entry = $ByWinget[([string]$Hit.Name).ToLower()]
        $Slot = & $Get $(if ($Entry) { "catalog:$($Entry.Id.ToLower())" } else { "winget:$(([string]$Hit.Name).ToLower())" })
        $Slot.Entry = $Entry; $Slot.WingetId = $Hit.Name; $Slot.WingetVersion = $Hit.Version; if (-not $Slot.Title) { $Slot.Title = $Hit.Title }
        if ($Entry) { $Slot.ChocoId = $Entry.Id }
    }

    $Rows = foreach ($Slot in $Merged.Values) {
        # The other source of a catalog app: its version from cache or feed
        $ChocoAvailable = $true; $WingetAvailable = $true
        if ($Slot.ChocoId -and -not $Slot.ChocoVersion) {
            $Info = Resolve-IntuneChocoSourceInfo -Source Chocolatey -Id $Slot.ChocoId -Cache $Cache -NoFetch:$NoFetch
            $Slot.ChocoVersion = $Info.Version; $ChocoAvailable = $Info.Available
        }
        if ($Slot.WingetId -and -not $Slot.WingetVersion) {
            $Info = Resolve-IntuneChocoSourceInfo -Source Winget -Id $Slot.WingetId -Cache $Cache -NoFetch:$NoFetch
            $Slot.WingetVersion = $Info.Version; $WingetAvailable = $Info.Available
        }
        $Name = if ($Slot.Entry) { $Slot.Entry.Name } elseif ($Slot.Title) { $Slot.Title } elseif ($Slot.ChocoId) { $Slot.ChocoId } else { $Slot.WingetId }
        New-IntuneChocoSourceRow -Name $Name -Category $(if ($Slot.Entry) { $Slot.Entry.Category }) -CatalogId $(if ($Slot.Entry) { $Slot.Entry.Id }) `
            -ChocoId $Slot.ChocoId -WingetId $Slot.WingetId -ChocoVersion $Slot.ChocoVersion -WingetVersion $Slot.WingetVersion `
            -ChocoAvailable $ChocoAvailable -WingetAvailable $WingetAvailable
    }
    return @(Select-IntuneChocoSourceApps -Apps @($Rows) -Filter $Filter)
}#Search in both repositories, one row per app

#endregion

#region deploy per source

function New-IntuneChocoSourceApplication {
    <#
        Deploys apps of the merged list, each from its own source: -Source (all apps), else the Source of the row
        (default = recommended source, else the preferred source of the settings). -Parameters are handed on to
        New-IntuneWin32ChocoApplication / New-IntuneWin32WingetApplication (Assignment, UpdateMode, Version, ...).
        Returns the Intune app ids.
    #>
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]$App,
        [ValidateSet("Chocolatey", "Winget")][string]$Source,
        [hashtable]$Parameters = @{}
    )
    process {
        foreach ($Row in @($App)) {
            $Use = if ($Source) { $Source } elseif ($Row.Source) { $Row.Source } else { Get-IntuneChocoDefaultSource -Row $Row }
            if ($Use -eq "Winget") {
                if (-not $Row.WingetId) { Write-Error "$($Row.Name) is not available from winget"; continue }
                New-IntuneWin32WingetApplication -WingetId $Row.WingetId @Parameters
            }
            elseif ($Use -eq "Chocolatey") {
                if (-not $Row.ChocoId) { Write-Error "$($Row.Name) is not available from Chocolatey"; continue }
                New-IntuneWin32ChocoApplication -ChocoName $Row.ChocoId @Parameters
            }
            else { Write-Error "$($Row.Name) has no source to deploy from" }
        }
    }
}#Deploys apps, each from the chosen source

#endregion

#region winget runtime dependency app

function Get-WingetRuntimeScripts {
    # Install, uninstall and detection script of the runtime app (plain ASCII, Windows PowerShell 5.1, runs as SYSTEM)
    $GetWinget = @'
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
'@

    $Install = @'
# Makes winget usable for SYSTEM: App Installer (winget) provisioned and registered with its VCLibs and UI.Xaml
# dependencies, and updated at most once a day (runs as SYSTEM through Intune).
param([switch]$Uninstall)

# The Intune Management Extension starts 32-bit PowerShell; the App Installer lives in the 64-bit WindowsApps folder
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $Arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    if ($Uninstall) { $Arguments += "-Uninstall" }
    & "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe" @Arguments
    exit $LASTEXITCODE
}

$Root = Join-Path $env:ProgramData "IntuneWingetDeployment"
$RuntimeRoot = Join-Path $Root "Runtime"
$Revision = '__REVISION__'

__COMMON__

# The folders hold what runs as SYSTEM: users must not be able to write there
try {
    Protect-Folder $Root
    Protect-Folder (Join-Path $Root "Logs")
    Protect-Folder $RuntimeRoot
}
catch { Write-Output "The folder $Root could not be protected: $($_.Exception.Message)"; exit 1 }
Start-Transcript -Path (Join-Path $Root "Logs\_runtime.log") -Append | Out-Null

__GETWINGET__

if ($Uninstall) {
    # winget belongs to Windows: nothing to remove, only the marker of this app goes (detection fails again)
    Remove-Item -LiteralPath (Join-Path $RuntimeRoot "checked.txt") -Force -ErrorAction SilentlyContinue
    Write-Output "winget is part of Windows and stays installed"
    Stop-Transcript | Out-Null
    exit 0
}

# One choco or winget operation at a time on the device
if (-not (Enter-DeploymentLock)) { Write-Output "Another choco or winget installation is still running"; Stop-Transcript | Out-Null; exit 1618 }
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    $Arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
    $Release = "https://github.com/microsoft/winget-cli/releases/latest/download"

    function Install-AppInstaller {
        # Provisions App Installer for all users with its dependencies (the packages are checked by Windows)
        $Work = Join-Path $RuntimeRoot "download"
        if (Test-Path -LiteralPath $Work) { Remove-ItemSafely $Work }
        Protect-Folder $Work
        $Bundle = Join-Path $Work "AppInstaller.msixbundle"
        $Zip = Join-Path $Work "dependencies.zip"
        Invoke-WebRequest -Uri "$Release/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle" -OutFile $Bundle -UseBasicParsing
        Invoke-WebRequest -Uri "$Release/DesktopAppInstaller_Dependencies.zip" -OutFile $Zip -UseBasicParsing
        Expand-Archive -LiteralPath $Zip -DestinationPath (Join-Path $Work "dependencies") -Force
        $Dependencies = @(Get-ChildItem -Path (Join-Path $Work "dependencies\$Arch") -Filter "*.appx" -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
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
    if (-not $Winget) { Write-Output "winget.exe not found (App Installer is missing)"; Stop-Transcript | Out-Null; exit 1 }
    Write-Output "Using $Winget"

    # winget must start for SYSTEM; if not, dependencies are missing
    & $Winget --version | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Output "winget does not start (exit code $LASTEXITCODE), installing App Installer and its dependencies again"
        try { Install-AppInstaller } catch { Write-Output "App Installer could not be provisioned: $($_.Exception.Message)" }
        $Winget = Get-Winget
        & $Winget --version | Out-Host
        if ($LASTEXITCODE -ne 0) { Write-Output "winget still does not start"; Stop-Transcript | Out-Null; exit 1 }
    }

    # App Installer updates itself at most once a day (the detection rule asks for the daily stamp)
    $Stamp = Join-Path $RuntimeRoot "checked.txt"
    $Due = $true
    if (Test-Path -LiteralPath $Stamp) {
        try {
            $Parts = (Get-Content -LiteralPath $Stamp -Raw).Trim().Split("|")
            $Last = [datetime]::Parse($Parts[1], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
            if ($Parts[0] -eq $Revision -and ([datetime]::UtcNow - $Last.ToUniversalTime()).TotalHours -lt 24) { $Due = $false }
        }
        catch { $Due = $true }
    }
    if ($Due) {
        & $Winget upgrade --id Microsoft.AppInstaller --exact --source winget --silent --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Host
        # No newer version or a failed update must not fail the dependency: winget itself works
        Write-Output "App Installer update check exit code $LASTEXITCODE"
        Write-ProtectedFile $Stamp ("{0}|{1}" -f $Revision, [datetime]::UtcNow.ToString("o"))
    }
}
finally { Exit-DeploymentLock }
Stop-Transcript | Out-Null
exit 0
'@

    $Detection = @'
# winget (App Installer) is there, and checked in the last 24 hours (otherwise Intune runs install.ps1, which updates it)
$Revision = '__REVISION__'
$Stamp = Join-Path $env:ProgramData "IntuneWingetDeployment\Runtime\checked.txt"
__GETWINGET__
$Winget = Get-Winget
if (-not $Winget) { exit 1 }
if (-not (Test-Path -LiteralPath $Stamp)) { exit 1 }
try {
    $Parts = (Get-Content -LiteralPath $Stamp -Raw).Trim().Split("|")
    $Last = [datetime]::Parse($Parts[1], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
}
catch { exit 1 }
if ($Parts[0] -ne $Revision -or ([datetime]::UtcNow - $Last.ToUniversalTime()).TotalHours -ge 24) { exit 1 }
Write-Output "winget runtime is ready: $Winget"
exit 0
'@

    $Revision = [string]$script:WingetRuntimeRevision
    return [pscustomobject]@{
        Install   = $Install.Replace("__COMMON__", (Get-DeviceScriptCommon)).Replace("__GETWINGET__", $GetWinget).Replace("__REVISION__", $Revision)
        Detection = $Detection.Replace("__GETWINGET__", $GetWinget).Replace("__REVISION__", $Revision)
    }
}#Scripts of the winget runtime app

function Install-IntuneWingetRuntime {
    # Creates the "winget runtime" Win32 app in the tenant (once; see Get-WingetRuntimeWin32ID)
    Assert-IntuneChocoPrerequisites
    Assert-IntuneChocoConnection
    Write-Host "Starting to deploy the winget runtime as win32 app to Intune"

    $WorkPath = New-IntuneChocoWorkFolder -Name "_winget-runtime"
    $SourcePath = Join-Path $WorkPath "source"
    $Scripts = Get-WingetRuntimeScripts
    Set-Content -Path (Join-Path $SourcePath "install.ps1") -Value $Scripts.Install -Encoding ASCII
    $DetectionFile = Join-Path $WorkPath "detection.ps1"
    Set-Content -Path $DetectionFile -Value $Scripts.Detection -Encoding ASCII

    $Package = New-IntuneChocoPackage -WorkPath $WorkPath
    $DetectionRule = Invoke-IntuneModule { New-IntuneWin32AppDetectionRuleScript -ScriptFile $DetectionFile }
    $RequirementRule = Invoke-IntuneModule { New-IntuneWin32AppRequirementRule -Architecture "AllWithARM64" -MinimumSupportedWindowsRelease W10_1809 }

    $App = Invoke-IntuneModule {
        Add-IntuneWin32App -FilePath $Package.Path -DisplayName $script:WingetRuntimeName -RequirementRule $RequirementRule -Notes $script:WingetRuntimeMarker `
            -Description "Makes winget usable on the device (App Installer with its dependencies). Dependency of the winget apps deployed with IntuneChocoDeployment." `
            -Publisher "IntuneChocoDeployment" -RestartBehavior suppress -InstallExperience system `
            -InstallCommandLine "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1" `
            -UninstallCommandLine "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall" -DetectionRule $DetectionRule
    }
    if ($null -eq $App -or -not $App.id) { throw "The winget runtime could not be created in Intune" }
    Invoke-IntuneModule { Add-IntuneWin32AppAssignmentAllUsers -ID $App.id -Intent available -Notification hideAll } | Out-Null
    Write-Host "winget runtime successfully deployed"
    return $App.id
}#Deploys the winget runtime app to the tenant

function Get-WingetRuntimeWin32ID {
    # Like get-ChocoWin32ID: the runtime app of the tenant, created once when it does not exist
    param([switch]$NoCreate)
    $App = @(Invoke-IntuneModule { Get-IntuneWin32App -DisplayName $script:WingetRuntimeName } | Where-Object { $_.displayName -eq $script:WingetRuntimeName -and [string]$_.notes -like "*$($script:WingetRuntimeMarker)*" }) | Select-Object -First 1
    if ($App) { return $App.id }
    if ($NoCreate) { return $null }
    Write-Host "The winget runtime is not in Intune, it will be deployed now"
    return Install-IntuneWingetRuntime
}#Returns the Intune ID of the winget runtime app

function Add-IntuneWingetRuntimeDependency {
    <#
        Adds the winget runtime as AutoInstall dependency to winget apps that do not have it yet (apps created
        before the runtime app existed). Without -AppId all winget apps created by this tool are checked. Not run
        automatically; returns one row per app (Added, AlreadyThere).
    #>
    param([string[]]$AppId)
    Assert-IntuneChocoPrerequisites
    Assert-IntuneChocoConnection
    Update-IntuneChocoToken
    $Targets = @(Get-IntuneChocoTenantApps | Where-Object { $_.Source -eq "Winget" -and -not $_.IsChocolatey })
    if ($AppId) { $Targets = @($Targets | Where-Object { $_.Id -in $AppId }) }
    if ($Targets.Count -eq 0) { return @() }
    $RuntimeId = Get-WingetRuntimeWin32ID
    foreach ($App in $Targets) {
        $Has = @(Invoke-IntuneModule { Get-IntuneWin32AppDependency -ID $App.Id } | Where-Object { $_.targetId -eq $RuntimeId }).Count -gt 0
        if (-not $Has) {
            Invoke-IntuneModule {
                $Dependency = New-IntuneWin32AppDependency -ID $RuntimeId -DependencyType AutoInstall
                Add-IntuneWin32AppDependency -ID $App.Id -Dependency $Dependency
            } | Out-Null
        }
        [pscustomobject]@{ Id = $App.Id; DisplayName = $App.DisplayName; Added = (-not $Has); AlreadyThere = $Has }
    }
}#Gives existing winget apps the runtime dependency

function Get-IntuneWingetAppsWithoutRuntime {
    # Winget apps of the tool without the runtime dependency (what the interface can offer to fix)
    Assert-IntuneChocoPrerequisites
    Assert-IntuneChocoConnection
    Update-IntuneChocoToken
    $RuntimeId = Get-WingetRuntimeWin32ID -NoCreate
    foreach ($App in @(Get-IntuneChocoTenantApps | Where-Object { $_.Source -eq "Winget" -and -not $_.IsChocolatey })) {
        $Has = $RuntimeId -and @(Invoke-IntuneModule { Get-IntuneWin32AppDependency -ID $App.Id } | Where-Object { $_.targetId -eq $RuntimeId }).Count -gt 0
        if (-not $Has) { $App }
    }
}#Winget apps that have no runtime dependency yet

#endregion
