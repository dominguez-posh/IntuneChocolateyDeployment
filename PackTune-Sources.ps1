<#
    One app list for both sources (Chocolatey and winget), (the runtime dependency app is in PackTune-Runtime.ps1).
    Loaded by PackTune-Main.ps1, uses its helpers (catalog, feeds, Invoke-IntuneModule, packaging).

    A "row" is one app as a person sees it: the same software, with the id it has in each source, the current
    version from each feed, the sources it is available from and the recommended source (the higher version).
    The package infos come from the same cache the interface keeps (feedcache.json, key "<chocolatey id>" and
    "winget:<id>", all lower case): pass it as -Cache (a hashtable of these entries) and nothing is asked twice;
    entries that are missing are read from the feeds and put into the cache.
#>

$script:Sources = "Chocolatey", "Winget"
$script:SourceFilters = "All", "Winget", "Chocolatey", "Both"

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

function Get-PackTuneDefaultSource {
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

function Resolve-PackTuneSourceInfo {
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

function New-PackTuneSourceRow {
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
    $Row.Source = Get-PackTuneDefaultSource -Row $Row
    return $Row
}#One app with the ids, versions and recommendation of both sources

function Get-PackTuneSourceApps {
    <#
        The curated catalog as one list: per app the sources it is available from, the current version of each
        (cache, then feed) and the recommended source. -NoFetch uses only what is in the cache.
    #>
    param([hashtable]$Cache, [switch]$NoFetch, [ValidateSet("All", "Winget", "Chocolatey", "Both")][string]$Filter = "All")
    $Rows = foreach ($Entry in @(Get-PackTuneCatalog)) {
        $Choco = if ($Entry.Id) { Resolve-PackTuneSourceInfo -Source Chocolatey -Id $Entry.Id -Cache $Cache -NoFetch:$NoFetch }
        $Winget = if ($Entry.WingetId) { Resolve-PackTuneSourceInfo -Source Winget -Id $Entry.WingetId -Cache $Cache -NoFetch:$NoFetch }
        New-PackTuneSourceRow -Name $Entry.Name -Category $Entry.Category -CatalogId $Entry.Id -ChocoId $Entry.Id -WingetId $Entry.WingetId `
            -ChocoVersion $(if ($Choco) { $Choco.Version }) -WingetVersion $(if ($Winget) { $Winget.Version }) `
            -ChocoAvailable $(if ($Choco) { $Choco.Available } else { $false }) -WingetAvailable $(if ($Winget) { $Winget.Available } else { $false })
    }
    return @(Select-PackTuneSourceApps -Apps @($Rows) -Filter $Filter)
}#The catalog with both sources per app

function Select-PackTuneSourceApps {
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

function Search-PackTuneApps {
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
    $Catalog = @(Get-PackTuneCatalog)
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
            $Info = Resolve-PackTuneSourceInfo -Source Chocolatey -Id $Slot.ChocoId -Cache $Cache -NoFetch:$NoFetch
            $Slot.ChocoVersion = $Info.Version; $ChocoAvailable = $Info.Available
        }
        if ($Slot.WingetId -and -not $Slot.WingetVersion) {
            $Info = Resolve-PackTuneSourceInfo -Source Winget -Id $Slot.WingetId -Cache $Cache -NoFetch:$NoFetch
            $Slot.WingetVersion = $Info.Version; $WingetAvailable = $Info.Available
        }
        $Name = if ($Slot.Entry) { $Slot.Entry.Name } elseif ($Slot.Title) { $Slot.Title } elseif ($Slot.ChocoId) { $Slot.ChocoId } else { $Slot.WingetId }
        New-PackTuneSourceRow -Name $Name -Category $(if ($Slot.Entry) { $Slot.Entry.Category }) -CatalogId $(if ($Slot.Entry) { $Slot.Entry.Id }) `
            -ChocoId $Slot.ChocoId -WingetId $Slot.WingetId -ChocoVersion $Slot.ChocoVersion -WingetVersion $Slot.WingetVersion `
            -ChocoAvailable $ChocoAvailable -WingetAvailable $WingetAvailable
    }
    return @(Select-PackTuneSourceApps -Apps @($Rows) -Filter $Filter)
}#Search in both repositories, one row per app

#endregion

#region deploy per source

function New-PackTuneSourceApplication {
    <#
        Deploys apps of the merged list, each from its own source: -Source (all apps), else the Source of the row
        (default = recommended source, else the preferred source of the settings). -Parameters are handed on to
        New-PackTuneChocolateyApp / New-PackTuneWingetApp (Assignment, UpdateMode, Version, ...).
        Returns the Intune app ids.
    #>
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]$App,
        [ValidateSet("Chocolatey", "Winget")][string]$Source,
        [hashtable]$Parameters = @{}
    )
    process {
        foreach ($Row in @($App)) {
            $Use = if ($Source) { $Source } elseif ($Row.Source) { $Row.Source } else { Get-PackTuneDefaultSource -Row $Row }
            if ($Use -eq "Winget") {
                if (-not $Row.WingetId) { Write-Error "$($Row.Name) is not available from winget"; continue }
                New-PackTuneWingetApp -WingetId $Row.WingetId @Parameters
            }
            elseif ($Use -eq "Chocolatey") {
                if (-not $Row.ChocoId) { Write-Error "$($Row.Name) is not available from Chocolatey"; continue }
                New-PackTuneChocolateyApp -ChocoName $Row.ChocoId @Parameters
            }
            else { Write-Error "$($Row.Name) has no source to deploy from" }
        }
    }
}#Deploys apps, each from the chosen source

#endregion

