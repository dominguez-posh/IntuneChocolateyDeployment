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
    if ($DisplayName) { $Apps = $Apps | Where-Object { $_.displayName -like "*$DisplayName*" } }
    $Apps
}
function Remove-IntuneWin32App { param([string]$DisplayName, [string]$ID)
    Test-FakeAccessToken
    Write-Store @(Read-Store | Where-Object { $_.id -ne $ID })
}
function New-IntuneWin32AppPackage { param($SourceFolder, $SetupFile, $OutputFolder, [switch]$Force)
    $Path = Join-Path $OutputFolder "install.intunewin"; Set-Content $Path "fake"; [pscustomobject]@{ Path = $Path }
}
function New-IntuneWin32AppDetectionRuleScript { param($ScriptFile) @{ "@odata.type" = "script"; scriptContent = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ScriptFile)) } }
function New-IntuneWin32AppDetectionRuleFile { param([switch]$Existence, $DetectionType, $Path, $FileOrFolder) @{ type = "file" } }
function New-IntuneWin32AppRequirementRule { param($Architecture, $MinimumSupportedWindowsRelease) @{ arch = $Architecture } }
function New-IntuneWin32AppDependency { param($ID, $DependencyType) [ordered]@{ targetId = $ID } }
function Add-IntuneWin32AppDependency { param($ID, $Dependency) Test-FakeAccessToken; $true }
function Add-IntuneWin32AppAssignmentAllUsers { param($ID, $Intent, $Notification)
    Test-FakeAccessToken
    $Apps = Read-Store; ($Apps | Where-Object id -eq $ID).assignment = $Intent; Write-Store $Apps; $true
}
function Add-IntuneWin32App {
    param($FilePath, $DisplayName, $Description, $Publisher, $Notes, $InstallExperience, $RestartBehavior, $DetectionRule,
        $RequirementRule, $InstallCommandLine, $UninstallCommandLine, $InformationURL, $Icon)
    Test-FakeAccessToken
    if (-not (Test-Path $FilePath)) { throw "intunewin missing" }
    $App = [pscustomobject]@{
        id = [guid]::NewGuid().ToString(); displayName = $DisplayName; notes = $Notes; createdDateTime = (Get-Date).ToString("o")
        hasIcon = [bool]$Icon; iconValid = $(if ($Icon) { $b = [Convert]::FromBase64String($Icon); ($b[0] -eq 0x89 -or $b[0] -eq 0xFF) } else { $false })
        arch = $RequirementRule.arch; publisher = $Publisher; assignment = $null; install = $InstallCommandLine
    }
    Write-Store (@(Read-Store) + $App)
    Start-Sleep -Milliseconds 500
    $App
}
Export-ModuleMember -Function Get-IntuneWin32App, Remove-IntuneWin32App, New-IntuneWin32AppPackage, New-IntuneWin32AppDetectionRuleScript, New-IntuneWin32AppDetectionRuleFile,
    New-IntuneWin32AppRequirementRule, New-IntuneWin32AppDependency, Add-IntuneWin32AppDependency, Add-IntuneWin32AppAssignmentAllUsers, Add-IntuneWin32App
