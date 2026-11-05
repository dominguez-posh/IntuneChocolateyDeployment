# Fake IntuneWin32App for the GUI smoke test (Tests\Invoke-GuiSmoke.ps1): no network, apps are kept in a JSON file
$Store = Join-Path $env:LOCALAPPDATA "fake-intune.json"
function Read-Store { if (Test-Path $Store) { $Data = Get-Content $Store -Raw | ConvertFrom-Json; @(foreach ($Item in $Data) { $Item }) } else { @() } }
function Write-Store($Apps) { ConvertTo-Json -InputObject @($Apps) -Depth 6 | Set-Content $Store }

function Connect-MSIntuneGraph {
    param([string]$TenantID, [string]$ClientID, [switch]$Interactive, [switch]$Refresh)
    if ($ClientID -eq "fail") { throw "AADSTS700016: Application not found (fake)" }
    $Global:AccessToken = [pscustomobject]@{
        access_token = "x." + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"name":"Test Admin","upn":"admin@contoso.onmicrosoft.com","tid":"t-1"}')).TrimEnd("=") + ".y"
        ExpiresOn    = (Get-Date).AddHours(1).ToUniversalTime()
    }
    $Global:AuthenticationHeader = @{ Authorization = "Bearer fake" }
    $Global:AccessTokenTenantID = $TenantID
}
function Get-IntuneWin32App { param([string]$DisplayName, [string]$ID)
    $Apps = Read-Store
    if ($DisplayName) { $Apps = $Apps | Where-Object { $_.displayName -like "*$DisplayName*" } }
    $Apps
}
function Remove-IntuneWin32App { param([string]$DisplayName, [string]$ID)
    Write-Store @(Read-Store | Where-Object { $_.id -ne $ID })
}
function New-IntuneWin32AppPackage { param($SourceFolder, $SetupFile, $OutputFolder, [switch]$Force)
    $Path = Join-Path $OutputFolder "install.intunewin"; Set-Content $Path "fake"; [pscustomobject]@{ Path = $Path }
}
function New-IntuneWin32AppDetectionRuleScript { param($ScriptFile) @{ "@odata.type" = "script"; scriptContent = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ScriptFile)) } }
function New-IntuneWin32AppDetectionRuleFile { param([switch]$Existence, $DetectionType, $Path, $FileOrFolder) @{ type = "file" } }
function New-IntuneWin32AppRequirementRule { param($Architecture, $MinimumSupportedWindowsRelease) @{ arch = $Architecture } }
function New-IntuneWin32AppDependency { param($ID, $DependencyType) [ordered]@{ targetId = $ID } }
function Add-IntuneWin32AppDependency { param($ID, $Dependency) $true }
function Add-IntuneWin32AppAssignmentAllUsers { param($ID, $Intent, $Notification)
    $Apps = Read-Store; ($Apps | Where-Object id -eq $ID).assignment = $Intent; Write-Store $Apps; $true
}
function Add-IntuneWin32App {
    param($FilePath, $DisplayName, $Description, $Publisher, $Notes, $InstallExperience, $RestartBehavior, $DetectionRule,
        $RequirementRule, $InstallCommandLine, $UninstallCommandLine, $InformationURL, $Icon)
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
Export-ModuleMember -Function *
