<#
    Release of a pinned version through supersedence (for apps that users install themselves).

    An app that is only Available in the Company Portal is not updated in place: devices that have it installed
    would see the new content only when someone reinstalls it. Instead the release creates a new Win32 app for the new
    version (same name, settings, icon, dependencies and assignments), lets it supersede the old app with the type
    "update" and switches on "auto-update superseded apps" in its Available assignments: devices with the old
    version get the new one. When no device reports the old app as installed any more, Remove-PackTuneSupersededApps
    removes it. Apps with a Required assignment keep the in-place update of Update-PackTuneApp.
    Loaded by PackTune-Main.ps1.
#>

function Get-PackTuneAppIntents {
    param([Parameter(Mandatory = $true)][string]$AppId)
    @(@(Invoke-IntuneModule { Get-IntuneWin32AppAssignment -ID $AppId }) | Where-Object { $_ } | ForEach-Object { [string]$_.Intent })
}#Intents (required, available, uninstall) of the assignments of an app

function Get-PackTuneReleasePath {
    <#
        Which way a release of this app takes: "Supersedence" for an app that is Available and not Required,
        "InPlace" otherwise (Required, or no assignment at all).
    #>
    param([Parameter(Mandatory = $true)][string]$AppId)
    $Intents = @(Get-PackTuneAppIntents -AppId $AppId)
    if ($Intents -contains "available" -and $Intents -notcontains "required") { return "Supersedence" }
    return "InPlace"
}#Supersedence for Available apps, in-place update for Required ones

function ConvertTo-PackTuneArchitecture {
    # The architecture of an existing app as the New-IntuneWin32AppRequirementRule value; $null when it cannot be told
    param($App)
    $Text = (@($App.allowedArchitectures, $App.applicableArchitectures) | Where-Object { $_ }) -join ","
    if (-not $Text) { return $null }
    if ($Text -in "x64", "x86", "arm64", "x64x86", "AllWithARM64") { return $Text }
    $Has = { param($Name) $Text -match "(^|[,\s])$Name($|[,\s])" }
    $X64 = & $Has "x64"; $X86 = & $Has "x86"; $Arm = & $Has "arm64"
    if ($X64 -and $X86 -and $Arm) { return "AllWithARM64" }
    if ($X64 -and $X86) { return "x64x86" }
    if ($Arm -and -not $X64 -and -not $X86) { return "arm64" }
    if ($X64) { return "x64" }
    if ($X86) { return "x86" }
    return $null
}

function Get-PackTuneMinimumWindows {
    # The minimum Windows release of an existing app as W10_<release>; $null when unknown
    param($App)
    $Release = [string]$App.minimumSupportedWindowsRelease
    if ($Release -match '^(\d{4})$') { return "W10_$($Matches[1])" }
    if ($Release -match '^(1[0-9]{3}|2[0-9]H[12])$') { return "W10_$($Matches[1])" }
    return $null
}

function Publish-PackTuneSupersedingApp {
    <#
        The supersedence path of a release: creates the app of the new version next to the old one and lets it
        supersede the old app (type update, auto-update). Returns the id of the new app. The assignment comes last:
        until then nobody sees the new app, and a failure before removes it again.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AppId,
        # Exact version, or "latest" to follow the newest version again
        [string]$Version,
        [ValidateSet("Off", "Startup", "Custom")][string]$UpdateMode,
        [ValidateRange(1, 2160)][int]$GraceHours
    )
    $Old = Invoke-IntuneModule { Get-IntuneWin32App -ID $AppId }
    if ($null -eq $Old) { throw "App $AppId was not found in Intune" }
    $IsWinget = (Get-PackTuneNotesSource ([string]$Old.notes)) -eq "Winget"
    $Current = ConvertFrom-PackTuneAppNotes $Old.notes
    if (-not $Current.Package) { throw "$($Old.displayName) has no package id in its notes (created by an older version of this tool). Remove it and deploy it again." }
    $Package = $Current.Package

    $NewVersion = if ($PSBoundParameters.ContainsKey("Version")) { $Version } else { $Current.Version }
    if ($NewVersion -eq "latest") { $NewVersion = "" }
    if ($NewVersion -and ($NewVersion -notin $(if ($IsWinget) { Get-WingetPackageVersions -WingetId $Package } else { Get-ChocoPackageVersions -ChocoName $Package }))) {
        throw "Version $NewVersion of $Package does not exist on $(if ($IsWinget) { 'the winget source' } else { $script:Settings.MetadataFeed })"
    }
    $NewMode = if ($UpdateMode) { $UpdateMode } else { $Current.UpdateMode }
    $NewGrace = if ($PSBoundParameters.ContainsKey("GraceHours")) { $GraceHours } else { $Current.GraceHours }
    $NewSource = if ($IsWinget) { "" } elseif ($null -ne $Current.PackageSource) { $Current.PackageSource } else { $script:Settings.PackageSource }
    $DelayMin = if ($null -ne $Current.UpdateDelayMinMinutes) { $Current.UpdateDelayMinMinutes } else { $script:Settings.UpdateDelayMinMinutes }
    $DelayMax = if ($null -ne $Current.UpdateDelayMaxMinutes) { $Current.UpdateDelayMaxMinutes } else { $script:Settings.UpdateDelayMaxMinutes }

    $Policy = New-PackTuneAppPolicy -Package $Package -Version $NewVersion -UpdateMode $NewMode -GraceHours $NewGrace -PackageSource $NewSource `
        -UpdateDelayMinMinutes $DelayMin -UpdateDelayMaxMinutes $DelayMax
    Write-Host ("{0}: new app for version {1}, updates {2}" -f $Old.displayName, $(if ($NewVersion) { $NewVersion } else { "always the latest" }), (Format-PackTuneUpdateMode $Policy))

    Write-Host "Building the package"
    $WorkPath = New-PackTuneWorkFolder -Name $(if ($IsWinget) { "winget-" + ($Package -replace '[^A-Za-z0-9._-]', '_') } else { $Package })
    $DetectionFile = if ($IsWinget) { New-WingetPackageScripts -WingetId $Package -SourcePath (Join-Path $WorkPath "source") -Policy $Policy -DisplayName $Old.displayName }
    else { New-ChocoPackageScripts -ChocoName $Package -SourcePath (Join-Path $WorkPath "source") -Policy $Policy -DisplayName $Old.displayName }
    $IntuneWinFile = New-PackTunePackage -WorkPath $WorkPath

    $DetectionRule = Invoke-IntuneModule { New-IntuneWin32AppDetectionRuleScript -ScriptFile $DetectionFile }
    $Architecture = ConvertTo-PackTuneArchitecture $Old
    if (-not $Architecture) { $Architecture = $script:Settings.Architecture }
    $Windows = Get-PackTuneMinimumWindows $Old
    if (-not $Windows) { $Windows = if ($IsWinget) { "W10_1809" } else { "W10_1607" } }
    $RequirementRule = Invoke-IntuneModule { New-IntuneWin32AppRequirementRule -Architecture $Architecture -MinimumSupportedWindowsRelease $Windows }

    $AppParams = @{
        FilePath             = $IntuneWinFile.Path
        DisplayName          = $Old.displayName
        Description          = $(if ($Old.description) { $Old.description } else { $Old.displayName })
        Publisher            = $(if ($Old.publisher) { $Old.publisher } else { "-" })
        AppVersion           = $(if ($NewVersion) { $NewVersion } else { "latest" })
        Notes                = ConvertTo-PackTuneAppNotes -Policy $Policy -Marker $(if ($IsWinget) { $script:WingetMarker } else { $script:AppMarker })
        InstallExperience    = "system"
        RestartBehavior      = "suppress"
        DetectionRule        = $DetectionRule
        RequirementRule      = $RequirementRule
        InstallCommandLine   = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1"
        UninstallCommandLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall"
    }
    if ($Old.informationUrl) { $AppParams.InformationURL = $Old.informationUrl }
    if ($Old.largeIcon -and $Old.largeIcon.value) { $AppParams.Icon = $Old.largeIcon.value }

    Write-Host "Creating and uploading the new app"
    $New = Invoke-IntuneModule { Add-IntuneWin32App @AppParams }
    if ($null -eq $New -or -not $New.id) { throw "Intune did not return the created app" }

    try {
        # Dependencies first, then supersedence: the module keeps both when it adds the other. An app that still
        # depends on the old Chocolatey or winget runtime app gets the PackTune Runtime instead.
        $Dependencies = @(Invoke-IntuneModule { Get-IntuneWin32AppDependency -ID $AppId } | Where-Object { $_ })
        $OldIds = @(Get-PackTuneOldDependencyApps | ForEach-Object { $_.Id })
        if (@($Dependencies | Where-Object { [string]$_.targetId -in $OldIds }).Count -gt 0) {
            $RuntimeId = Get-PackTuneRuntimeWin32ID
            $Dependencies = @(@($Dependencies | Where-Object { [string]$_.targetId -notin $OldIds -and [string]$_.targetId -ne $RuntimeId }) + [pscustomobject]@{ targetId = $RuntimeId; dependencyType = "autoInstall" })
        }
        if ($Dependencies.Count -gt 0) {
            Invoke-IntuneModule {
                $Copies = @(foreach ($Dependency in $Dependencies) {
                        $Type = if ([string]$Dependency.dependencyType -eq "detect") { "Detect" } else { "AutoInstall" }
                        New-IntuneWin32AppDependency -ID $Dependency.targetId -DependencyType $Type
                    })
                Add-IntuneWin32AppDependency -ID $New.id -Dependency $Copies
            } | Out-Null
        }
        else { Write-Warning "$($Old.displayName) has no dependency to copy" }

        Write-Host "Superseding the old app (update)"
        Invoke-IntuneModule {
            $Supersedence = New-IntuneWin32AppSupersedence -ID $AppId -SupersedenceType Update
            Add-IntuneWin32AppSupersedence -ID $New.id -Supersedence $Supersedence
        } | Out-Null

        # Same assignments as the old app. Available ones switch on auto-update of superseded apps (only possible now,
        # because the module needs the supersedence to exist).
        $Assignments = @(Invoke-IntuneModule { Get-IntuneWin32AppAssignment -ID $AppId } | Where-Object { $_ })
        foreach ($Assignment in $Assignments) {
            $Params = @{ ID = $New.id; Intent = [string]$Assignment.Intent; Notification = $(if ($Assignment.Notifications) { [string]$Assignment.Notifications } else { "showAll" }) }
            # The module only accepts the auto-update setting for Available assignments
            if ($Params.Intent -eq "available") { $Params.AutoUpdateSupersededApps = "enabled" }
            $Type = [string]$Assignment.Type
            Invoke-IntuneModule {
                if ($Type -like "*allLicensedUsersAssignmentTarget") { Add-IntuneWin32AppAssignmentAllUsers @Params }
                elseif ($Type -like "*allDevicesAssignmentTarget") { Add-IntuneWin32AppAssignmentAllDevices @Params }
                elseif ($Type -like "*exclusionGroupAssignmentTarget") { Add-IntuneWin32AppAssignmentGroup @Params -GroupID $Assignment.GroupID }
                elseif ($Type -like "*groupAssignmentTarget") { Add-IntuneWin32AppAssignmentGroup @Params -Include -GroupID $Assignment.GroupID }
                else { Write-Warning "Assignment type $Type was not copied" }
            } | Out-Null
        }
    }
    catch {
        $Message = $_.Exception.Message
        try { Invoke-IntuneModule { Remove-IntuneWin32App -ID $New.id } | Out-Null } catch { Write-Warning "The unfinished new app $($New.id) could not be removed: $($_.Exception.Message)" }
        throw "The release of $($Old.displayName) was not finished and the new app was removed again: $Message"
    }
    Write-Host "Done: devices with the old version get the new one through supersedence."
    return $New.id
}#Creates the new version of an Available app and supersedes the old one

function Publish-PackTuneRelease {
    <#
        Releases a version (or a changed update policy) the right way for the app: Available and not Required =
        new app with supersedence (the old app stays until Remove-PackTuneSupersededApps finds no device using
        it); otherwise the in-place update of Update-PackTuneApp. -Path forces one of the ways.
        Returns what happened: Path, AppId (the app to look at afterwards), OldAppId.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AppId,
        [string]$Version,
        [ValidateSet("Off", "Startup", "Custom")][string]$UpdateMode,
        [ValidateRange(1, 2160)][int]$GraceHours,
        [ValidateSet("Auto", "InPlace", "Supersedence")][string]$Path = "Auto"
    )
    Assert-PackTunePrerequisites
    Assert-PackTuneConnection
    Update-PackTuneToken
    $Way = if ($Path -eq "Auto") { Get-PackTuneReleasePath -AppId $AppId } else { $Path }
    $Arguments = @{ AppId = $AppId }
    foreach ($Name in "Version", "UpdateMode", "GraceHours") { if ($PSBoundParameters.ContainsKey($Name)) { $Arguments[$Name] = $PSBoundParameters[$Name] } }
    if ($Way -eq "Supersedence") {
        $NewId = Publish-PackTuneSupersedingApp @Arguments
        return [pscustomobject]@{ Path = "Supersedence"; AppId = $NewId; OldAppId = $AppId }
    }
    $Done = Update-PackTuneApp @Arguments
    return [pscustomobject]@{ Path = "InPlace"; AppId = @($Done)[-1]; OldAppId = $null }
}#Release: supersedence for Available apps, in-place update for Required apps

function Get-PackTuneAppInstalledCount {
    # Devices (and users) that report the app as installed, from the install summary of the app in Graph
    param([Parameter(Mandatory = $true)][string]$AppId)
    Assert-PackTuneConnection
    Update-PackTuneToken
    $Headers = @{ Authorization = "Bearer $($Global:AccessToken.access_token)" }
    $Summary = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/installSummary" -Headers $Headers -TimeoutSec 60 -ErrorAction Stop
    if ($null -eq $Summary -or $null -eq $Summary.installedDeviceCount) { throw "Intune returned no install summary for app $AppId" }
    return [int][Math]::Max([int]$Summary.installedDeviceCount, [int]$Summary.installedUserCount)
}#Number of devices that report the app as installed

function Get-PackTuneSupersededApps {
    # Apps this tool created that a newer app of this tool supersedes
    Assert-PackTunePrerequisites
    Assert-PackTuneConnection
    Update-PackTuneToken
    $Apps = @(Get-PackTuneTenantApps | Where-Object { -not $_.IsChocolatey })
    $ById = @{}; foreach ($App in $Apps) { $ById[$App.Id] = $App }
    foreach ($New in $Apps) {
        foreach ($Relation in @(Invoke-IntuneModule { Get-IntuneWin32AppSupersedence -ID $New.Id } | Where-Object { $_ })) {
            $Old = $ById[[string]$Relation.targetId]
            if (-not $Old) { continue }
            [pscustomobject]@{
                OldId = $Old.Id; OldName = $Old.DisplayName; OldVersion = $Old.AppVersion
                NewId = $New.Id; NewName = $New.DisplayName; NewVersion = $New.AppVersion
            }
        }
    }
}#Old apps that are superseded by a newer app of this tool

function Remove-PackTuneSupersededApps {
    <#
        Removes superseded apps when no device reports them installed any more. -InstallCount (script block, gets the
        app id, returns the number of devices) replaces the Graph query, e.g. for tests. -AppId limits it to
        one old app, -WhatIf only reports. When the number cannot be read the app stays.
    #>
    param([string[]]$AppId, [scriptblock]$InstallCount, [switch]$WhatIf)
    $Rows = @(Get-PackTuneSupersededApps)
    if ($AppId) { $Rows = @($Rows | Where-Object { $_.OldId -in $AppId }) }
    foreach ($Row in $Rows) {
        $Count = $null; $Removed = $false; $Reason = $null
        try { $Count = if ($InstallCount) { [int](& $InstallCount $Row.OldId) } else { Get-PackTuneAppInstalledCount -AppId $Row.OldId } }
        catch { $Reason = "install status not readable: $($_.Exception.Message)" }
        if ($null -ne $Count -and $Count -gt 0) { $Reason = "$Count device(s) still report it installed" }
        elseif ($null -ne $Count -and $WhatIf) { $Reason = "no device reports it installed, would be removed" }
        elseif ($null -ne $Count) {
            try {
                # The new app lets go of the old one first (Intune does not delete an app another app supersedes);
                # supersedence of other old apps stays
                $Others = @(Invoke-IntuneModule { Get-IntuneWin32AppSupersedence -ID $Row.NewId } | Where-Object { $_ -and [string]$_.targetId -ne $Row.OldId })
                Invoke-IntuneModule { Remove-IntuneWin32AppSupersedence -ID $Row.NewId } | Out-Null
                if ($Others.Count -gt 0) {
                    Invoke-IntuneModule {
                        $Again = @(foreach ($Other in $Others) { New-IntuneWin32AppSupersedence -ID $Other.targetId -SupersedenceType $(if ($Other.supersedenceType -eq "replace") { "Replace" } else { "Update" }) })
                        Add-IntuneWin32AppSupersedence -ID $Row.NewId -Supersedence $Again
                    } | Out-Null
                }
                Remove-PackTuneApp -Id $Row.OldId
                $Removed = $true; $Reason = "removed"
            }
            catch { $Reason = "not removed: $($_.Exception.Message)" }
        }
        [pscustomobject]@{ OldId = $Row.OldId; OldName = $Row.OldName; OldVersion = $Row.OldVersion; NewId = $Row.NewId; NewVersion = $Row.NewVersion; InstalledCount = $Count; Removed = $Removed; Reason = $Reason }
    }
}#Removes superseded apps nobody has installed any more
