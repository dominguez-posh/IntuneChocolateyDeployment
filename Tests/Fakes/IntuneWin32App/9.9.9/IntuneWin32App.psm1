# Fake IntuneWin32App for the GUI smoke test (Tests\Invoke-GuiSmoke.ps1): no network, apps are kept in a JSON file
$Store = Join-Path $env:LOCALAPPDATA "fake-intune.json"
function Read-Store { if (Test-Path $Store) { $Data = Get-Content $Store -Raw | ConvertFrom-Json; @(foreach ($Item in $Data) { $Item }) } else { @() } }
function Write-Store($Apps) { ConvertTo-Json -InputObject @($Apps) -Depth 6 | Set-Content $Store }

function Test-FakeAccessToken {
    # Behaves like the real module 1.5.0 where it hurts: the expiry check only works with an invariant date format
    # (it writes the date in the current culture and reads it back as en-US), and a failed check ends the calling
    # function with "break". Callers that do not go through Invoke-IntuneModule get the same silent stop here,
    # on every machine and every day of the month.
    if ($null -eq $Global:AccessToken -or $null -eq $Global:AuthenticationHeader) {
        Write-Warning "Unable to find authentication header, use Connect-MSIntuneGraph function before running this function (fake)"; break
    }
    if ([System.Threading.Thread]::CurrentThread.CurrentCulture.Name -ne "") {
        Write-Warning "Silent token refresh failed (fake): the module was called outside Invoke-IntuneModule"; break
    }
    $Expires = [DateTimeOffset]::Parse($Global:AccessToken.ExpiresOn.ToString(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)
    if ($Expires -le [DateTimeOffset]::UtcNow.AddMinutes(5)) { Write-Warning "Access token has expired (fake)"; break }
}

function Get-IntuneWin32App { param([string]$DisplayName, [string]$ID)
    Test-FakeAccessToken
    $Apps = Read-Store
    if ($ID) { $Apps = $Apps | Where-Object { $_.id -eq $ID } }
    if ($DisplayName) { $Apps = $Apps | Where-Object { $_.displayName -like "*$DisplayName*" } }
    $Apps
}
function Update-IntuneWin32AppPackageFile { param([string]$ID, [string]$FilePath)
    Test-FakeAccessToken
    if (-not (Test-Path $FilePath)) { throw "intunewin missing" }
    $Apps = Read-Store; ($Apps | Where-Object id -eq $ID).uploads++; Write-Store $Apps
}
function Set-IntuneWin32App {
    # Same types as the real module: a detection rule of the wrong type fails here too
    param([string]$ID, [string]$Notes, [string]$AppVersion, [System.Collections.Specialized.OrderedDictionary[]]$DetectionRule)
    Test-FakeAccessToken
    $Apps = Read-Store
    $App = $Apps | Where-Object id -eq $ID
    if (-not $App) { throw "App $ID not found (fake)" }
    if ($Notes) { $App.notes = $Notes }
    if ($AppVersion) { $App.displayVersion = $AppVersion }
    if ($DetectionRule) { $App.detection = $DetectionRule[0].scriptContent }
    Write-Store $Apps
}
function Remove-IntuneWin32App { param([string]$DisplayName, [string]$ID)
    Test-FakeAccessToken
    $Blocker = @(Read-Store | Where-Object { @($_.supersedence).targetId -contains $ID })
    if ($Blocker.Count -gt 0) { throw "App $ID is still superseded by $($Blocker[0].displayName) (fake)" }
    Write-Store @(Read-Store | Where-Object { $_.id -ne $ID })
}
function New-IntuneWin32AppPackage { param($SourceFolder, $SetupFile, $OutputFolder, [switch]$Force)
    $Path = Join-Path $OutputFolder "install.intunewin"; Set-Content $Path "fake"; [pscustomobject]@{ Path = $Path }
}
function New-IntuneWin32AppDetectionRuleScript { param($ScriptFile) [ordered]@{ "@odata.type" = "script"; scriptContent = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ScriptFile)) } }
function New-IntuneWin32AppDetectionRuleFile { param([switch]$Existence, $DetectionType, $Path, $FileOrFolder) @{ type = "file" } }
function New-IntuneWin32AppRequirementRule { param($Architecture, $MinimumSupportedWindowsRelease) @{ arch = $Architecture; release = [string]$MinimumSupportedWindowsRelease } }

function New-IntuneWin32AppDependency { param($ID, $DependencyType) [ordered]@{ "@odata.type" = "#microsoft.graph.mobileAppDependency"; targetId = $ID; dependencyType = ([string]$DependencyType).ToLower().Replace("autoinstall", "autoInstall") } }
function Add-IntuneWin32AppDependency {
    # Like the real module: replaces the dependencies of the app and keeps its supersedence
    param($ID, [System.Collections.Specialized.OrderedDictionary[]]$Dependency)
    Test-FakeAccessToken
    $Apps = Read-Store; $App = $Apps | Where-Object id -eq $ID
    if (-not $App) { throw "App $ID not found (fake)" }
    # The real module replaces the whole dependency list (supersedence stays)
    $App.dependencies = @(@($Dependency | ForEach-Object { [pscustomobject]@{ targetId = $_.targetId; dependencyType = $_.dependencyType } }) | Where-Object { $_ })
    Write-Store $Apps; $true
}
function Get-IntuneWin32AppDependency { param([string]$ID)
    Test-FakeAccessToken
    $App = Read-Store | Where-Object id -eq $ID
    @(@($App.dependencies) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ "@odata.type" = "#microsoft.graph.mobileAppDependency"; targetId = $_.targetId; dependencyType = $_.dependencyType } })
}
function New-IntuneWin32AppSupersedence { param([string]$ID, [ValidateSet("Replace", "Update")][string]$SupersedenceType)
    Test-FakeAccessToken
    if (-not (Read-Store | Where-Object id -eq $ID)) { Write-Warning "no app $ID (fake)"; return }
    [ordered]@{ "@odata.type" = "#microsoft.graph.mobileAppSupersedence"; supersedenceType = $SupersedenceType.ToLower(); targetId = $ID }
}
function Add-IntuneWin32AppSupersedence { param([string]$ID, [System.Collections.Specialized.OrderedDictionary[]]$Supersedence)
    Test-FakeAccessToken
    $Apps = Read-Store; $App = $Apps | Where-Object id -eq $ID
    if (-not $App) { throw "App $ID not found (fake)" }
    if ($ID -in $Supersedence.targetId) { throw "An app cannot supersede itself (fake)" }
    $App.supersedence = @(@($App.supersedence) + @($Supersedence | ForEach-Object { [pscustomobject]@{ targetId = $_.targetId; supersedenceType = $_.supersedenceType } }) | Where-Object { $_ })
    Write-Store $Apps; $true
}
function Get-IntuneWin32AppSupersedence { param([string]$ID)
    Test-FakeAccessToken
    $App = Read-Store | Where-Object id -eq $ID
    @(@($App.supersedence) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ "@odata.type" = "#microsoft.graph.mobileAppSupersedence"; targetId = $_.targetId; supersedenceType = $_.supersedenceType } })
}
function Remove-IntuneWin32AppSupersedence { param([string]$ID)
    Test-FakeAccessToken
    $Apps = Read-Store; ($Apps | Where-Object id -eq $ID).supersedence = @(); Write-Store $Apps; $true
}
function Add-FakeAssignment($ID, $Type, $Intent, $GroupID, $AutoUpdate, $Notification) {
    $Apps = Read-Store; $App = $Apps | Where-Object id -eq $ID
    if (-not $App) { throw "App $ID not found (fake)" }
    $Record = [pscustomobject]@{ Type = $Type; Intent = $Intent; GroupID = $GroupID; AutoUpdateSupersededApps = $AutoUpdate; Notifications = $Notification }
    $App.assignments = @(@($App.assignments) + $Record | Where-Object { $_ })
    $App.assignment = $Intent
    Write-Store $Apps; $true
}
function Add-IntuneWin32AppAssignmentAllUsers { param($ID, $Intent, $Notification = "showAll", $AutoUpdateSupersededApps = "notConfigured")
    Test-FakeAccessToken
    if ($AutoUpdateSupersededApps -eq "enabled" -and $Intent -ne "available") { Write-Warning "AutoUpdateSupersededApps is only allowed with Intent available (fake)"; break }
    Add-FakeAssignment $ID "#microsoft.graph.allLicensedUsersAssignmentTarget" $Intent $null $AutoUpdateSupersededApps $Notification
}
function Add-IntuneWin32AppAssignmentAllDevices { param($ID, $Intent, $Notification = "showAll", $AutoUpdateSupersededApps = "notConfigured")
    Test-FakeAccessToken
    Add-FakeAssignment $ID "#microsoft.graph.allDevicesAssignmentTarget" $Intent $null $AutoUpdateSupersededApps $Notification
}
function Add-IntuneWin32AppAssignmentGroup { param([switch]$Include, $ID, $GroupID, $Intent, $Notification = "showAll", $AutoUpdateSupersededApps = "notConfigured")
    Test-FakeAccessToken
    Add-FakeAssignment $ID $(if ($Include) { "#microsoft.graph.groupAssignmentTarget" } else { "#microsoft.graph.exclusionGroupAssignmentTarget" }) $Intent $GroupID $AutoUpdateSupersededApps $Notification
}
function Get-IntuneWin32AppAssignment { param([string]$ID)
    Test-FakeAccessToken
    $App = Read-Store | Where-Object id -eq $ID
    @(@($App.assignments) | Where-Object { $_ })
}
function Add-IntuneWin32App {
    param($FilePath, $DisplayName, $Description, $Publisher, $AppVersion, $Notes, $InstallExperience, $RestartBehavior, $DetectionRule,
        $RequirementRule, $InstallCommandLine, $UninstallCommandLine, $InformationURL, $Icon)
    Test-FakeAccessToken
    if (-not (Test-Path $FilePath)) { throw "intunewin missing" }
    $App = [pscustomobject]@{
        id = [guid]::NewGuid().ToString(); displayName = $DisplayName; notes = $Notes; createdDateTime = (Get-Date).ToString("o")
        hasIcon = [bool]$Icon; iconValid = $(if ($Icon) { $b = [Convert]::FromBase64String($Icon); ($b[0] -eq 0x89 -or $b[0] -eq 0xFF) } else { $false })
        arch = $RequirementRule.arch; publisher = $Publisher; assignment = $null; install = $InstallCommandLine
        displayVersion = $AppVersion; detection = $DetectionRule.scriptContent; uploads = 1
        description = $Description; informationUrl = $InformationURL; largeIcon = $(if ($Icon) { [pscustomobject]@{ type = "image/png"; value = $Icon } } else { $null })
        applicableArchitectures = $RequirementRule.arch; minimumSupportedWindowsRelease = $RequirementRule.release
        dependencies = @(); supersedence = @(); assignments = @()
    }
    Write-Store (@(Read-Store) + $App)
    Start-Sleep -Milliseconds 500
    $App
}
Export-ModuleMember -Function Get-IntuneWin32App, Remove-IntuneWin32App, New-IntuneWin32AppPackage, New-IntuneWin32AppDetectionRuleScript, New-IntuneWin32AppDetectionRuleFile,
    New-IntuneWin32AppRequirementRule, New-IntuneWin32AppDependency, Add-IntuneWin32AppDependency, Get-IntuneWin32AppDependency,
    New-IntuneWin32AppSupersedence, Add-IntuneWin32AppSupersedence, Get-IntuneWin32AppSupersedence, Remove-IntuneWin32AppSupersedence,
    Add-IntuneWin32AppAssignmentAllUsers, Add-IntuneWin32AppAssignmentAllDevices, Add-IntuneWin32AppAssignmentGroup, Get-IntuneWin32AppAssignment,
    Add-IntuneWin32App, Update-IntuneWin32AppPackageFile, Set-IntuneWin32App
