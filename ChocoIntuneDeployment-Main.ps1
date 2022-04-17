##Before you can use, you need to Connect to Intune API to the right tenant with following Command:
#Connect-MSIntuneGraph -TenantID <tenant-ID>
#Sample : Connect-MSIntuneGraph -TenantID "contoso.com"
#If you using the first time, you need to run Install-IntunechocoComponents with elevated rights to install the required Components

##After connecting, you are able to Start die deployment process

#SAMPLE: New-IntuneWin32ChocoApplication -choconame "googlechrome" -> Deploys GoogleChrome to Intune

function Install-IntunechocoComponents {


Install-Module IntuneWin32App -Force
Import-Module IntuneWin32App
Install-Module Microsoft.Graph.Intune -Force
Import-Module Microsoft.Graph.Intune
Install-Module -Name chocolatey
Import-Module -Name chocolatey
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
choco install inkscape -y
}#Installing all required Script Components including chocolatey and PNG Converter

function New-IntuneWin32ChocoApplication{
param(
    [String[]]$ChocoName = (Get-ChocoPackageBySearch),
    [Switch]$Required = $false
  )

#Connect-MSIntuneGraph -TenantID $TenantName.ToString() -Refresh
$WorkPath = $env:TEMP

if($ChocoName -eq $Null){return "No software selected, repeat it"}

### Get Informations of Software
        Write-Host "Getting Infos from Chocolatey"
        $Infos = Get-ChocoInfo $ChocoName
###

        $AppName = $Infos.Title.Split("|")[0]

        $intuneApps = Get-IntuneWin32App
        foreach($IntuneAPP in $intuneApps)
        {
            if (($IntuneAPP.displayName).ToLower() -eq $AppName.ToLower()){write-host "app is already deployed, please update or remove first !";return $Null}
        }

### Icon Creation
        write-host "Getting Icon from chocolatey library"
        $Icon = Get-ChocoIconBase64 -ChocoName $ChocoName
        
###

###Install And Detection Script Creation
        write-host "Creating the install and detection script in Temp Folder"
        try{$Output = New-Item -Path $WorkPath -Name "intunedeployment" -ItemType Directory -Force}catch{"Some Error 55"}
        try{$Output = New-Item -Path ($WorkPath+"\intunedeployment") -Name "source" -ItemType Directory -Force}catch{"Some Error 56"}

        $WorkPath =  ($WorkPath+"\intunedeployment")
        $SourcePath = ($WorkPath + "\source")

        try{$Output = New-Item ($SourcePath + "\install.ps1") -Force}catch{"Some Error 61"}
        try{$Output = Set-Content ($SourcePath + "\install.ps1") ('
        
        param(
            [string]$package = "",
            [switch]$uninstall = $false
        )

        $ChocoName = "' + $ChocoName + '"

        if ($uninstall) {
            choco uninstall $package -y
            Unregister-ScheduledTask -TaskName ("Update "+"$ChocoName+" on startup") -Confirm:$false
        } else {
            choco upgrade $package -y

        # Creating Update Task for Start-Up
        $chocoCmd = Get-Command –Name "choco" –ErrorAction SilentlyContinue –WarningAction SilentlyContinue | Select-Object –ExpandProperty Source

        $taskAction = New-ScheduledTaskAction –Execute $chocoCmd –Argument ("upgrade " +$ChocoName+ " -y")
        $taskTrigger = New-ScheduledTaskTrigger –AtStartup
        $taskUserPrincipal = New-ScheduledTaskPrincipal –UserId "SYSTEM"
        $taskSettings = New-ScheduledTaskSettingsSet –Compatibility Win8

        $task = New-ScheduledTask –Action $taskAction –Principal $taskUserPrincipal –Trigger $taskTrigger –Settings $taskSettings
        Register-ScheduledTask –TaskName ("Update " + $ChocoName + " on startup")  –InputObject $task -TaskPath "Intune-Choco-Updates" –Force
        }

        ')}catch{"Some Error 62"}

        try{$Output = New-Item ($SourcePath + "\detection.ps1") -Force}catch{"Some Error 90"}
        
        
        $DetectionContent = ('
        choco feature enable --name="useEnhancedExitCodes" -y
        $PackageName = "'+$ChocoName+'"
        choco list -e $PackageName --local-only
        write-host "FOUND IT MAYBE!"
        exit $LastExitCode
        ')

        try{Set-Content  ($Sourcepath + "\detection.ps1") $DetectionContent}catch{"Some Error 101"}

        try{Remove-Item ($WorkPath + "\install.intunewin")}catch{}

        try{$IntuneWinFile = New-IntuneWin32AppPackage -SourceFolder $SourcePath -SetupFile "install.ps1" -OutputFolder $WorkPath}catch{"Some Error 105"}
###

### Detection Script
        try{$DetectionScript =  New-IntuneWin32AppDetectionRule -PowerShellScript -ScriptFile ($Workpath + "\source\detection.ps1")}catch{"Some Error 109"}

###

        $InstallCommandLine = ("powershell.exe -executionpolicy bypass .\install.ps1 " + $ChocoName)
        $UnInstallCommandLine = ("powershell.exe -executionpolicy bypass .\install.ps1 " +$ChocoName +  " -uninstall")


### Create custom requirement rule
        try{$RequirementRule = New-IntuneWin32AppRequirementRule -Architecture All -MinimumSupportedOperatingSystem 1607}catch{"Some Error 118"}
###

### Chocolatey Dependency
        write-host "Checking if Chocolatey is installed"
        $ChocoID = get-ChocoWin32ID

        $Dependency = New-IntuneWin32AppDependency -ID $ChocoID -DependencyType AutoInstall
###


### Deploy Application
        $DisplayName = $ChocoName
        Write-Host ("Creating and Uploading " + $ChocoName + " as win32 App to Intune")
        try{$IntuneApp = Add-IntuneWin32App  -FilePath $IntuneWinFile.Path -DisplayName $AppName -Description $Infos.Description -Notes "PoweredByChocolatey" -Publisher "-" -InformationURL $Infos.SoftwareSite -PrivacyURL $Infos.SoftwareLicense -InstallExperience system -RestartBehavior suppress -DetectionRule $DetectionScript -RequirementRule $RequirementRule -InstallCommandLine $InstallCommandLine -UninstallCommandLine $UninstallCommandLine -Icon $Icon }catch{"Some Error 131"}
        Write-Host "Adding dependency for chocolatey to the created Application"
        try{Add-IntuneWin32AppDependency -ID $IntuneApp.ID -Dependency $Dependency}catch{"Some Error 132"}
        if($Required -eq $true){
            write-host "Enable autodeployment for all users"
            try{
            Add-IntuneWin32AppAssignmentAllUsers -ID $intuneApp.id -Intent required -Notification showReboot 
            }
            catch{"Some Error 135"}
        }
        if($Required -eq $false){
            write-host "Making application available in companyportal for all users"
            try{$Output = Add-IntuneWin32AppAssignmentAllUsers -ID $intuneApp.id -Intent available -Notification showReboot }
            catch{"Some Error 137 "+$Output}
        }
        
###
        if($IntuneApp.id -ne $Null){write-host "Deoloyment was Successfull!"
        return $intuneApp.id}
        else{
        return "Some Error uccured, please check and try again"
        }
        


}#Main function for deploying The Applications

function Get-ChocoInfo ()  {
param(
$ChocoName
)

    $Infos = choco search --exact $ChocoName --detail


foreach ($Info in $Infos){

if($info -like "*Title: *"){$Title =  $Info.Replace(" Title: ","") }
#if($info -like "*Summary: *"){$Summary =  $Info.Replace(" Summary: ","")}
if($info -like "*Description: *"){$Description =  $Info.Replace(" Description: ","")}
if($info -like "*Software Site: *"){$SoftwareSite =  $Info.Replace(" Software Site: ","")}
if($info -like "*Software License: *"){$SoftwareLicense =  $Info.Replace(" Software License: ","")}

}

$returnObject = New-Object -TypeName psobject 

$returnObject | Add-Member -MemberType NoteProperty -Name Name -Value $ChocoName
$returnObject | Add-Member -MemberType NoteProperty -Name Title -Value $Title.toString()
#$returnObject | Add-Member -MemberType NoteProperty -Name Summary -Value $Summary.toString()
$returnObject | Add-Member -MemberType NoteProperty -Name Description -Value $Description.toString()
$returnObject | Add-Member -MemberType NoteProperty -Name SoftwareSite -Value $SoftwareSite.toString()
$returnObject | Add-Member -MemberType NoteProperty -Name SoftwareLicense -Value $SoftwareLicense.toString()

return $returnObject

}#Returns The Infos of Choco Repository

function install-chocolatey{

write-host "Starting Deploy Chocolatey as win32 app to intune"
$WorkPath = $ENV:temp

$Icon = "iVBORw0KGgoAAAANSUhEUgAAAOwAAADVCAMAAABjeOxDAAAAw1BMVEWAteP///+SRxaaxOlxmMpwl8mfUyZ5OBJ/uuuLu+WUwed5qNh2sOGTPQBmkcfq6uucTRu8jXaTQgC7oJNzKwCSRAp1odGBrdWBPRPx9fqtzuyEn72Glq+Mc3KLeX2IipuJhJGRTCGKf4jH3fJ5MwCDpMbR4/SNbGbo8fqPW0W1xtm41O6OYlKQVDaNaF+RUS2Otdlzf5+hSw
F4RDB2mMB2YWp1aHZ1cYaCMwB9ZGR4PBp3TUR3VFKvrra+h2nYxr27rKerWwlJAAAOuklEQVR4nOWdeXviyBGHm2u2YaTNRBlZa25sA2Ztw3rnSjbH5vt/quhA0EdVHyWBgNSTf/KsrOGlqqurq3/dsNb/kbHhcNX0ZzibsecgCAYvz01/jrMYaw0YYylw5/H2gVlrFbDcgoANV/dNf56TGkv/d7Qg6N9yRKewjwGTeNnNRnQK25JgbzmiM9gXjTYH
HvzqYP/+z18vyP60w95DsKl1hp2BaB3dBnz8e/zpMiyKPv/NDtsawrC/DYcAn2L95O3Th0uwdvsnJ9hn2LW/dToOtAO2/r1p0A85qxtsq4PBdlycy2eN07bbv/zkCgu7NoN1ou0vPzQbygWrI2yrj8I60Q7Ya5PO3bO6wq4g1xawTrQdPm2ONhuuPrAtgLWEdQzl8aeGQvnA6gz7CLj2AOsWys3MQWUI+8DqNaMI6xbK/QbmIJHVHXao0wqwKa1LKH
vNQXWEvcTqDgvUjEp92Gd9m/FRO267WRStx5HjswYTWd1hgZpRg7UbTzahw0eMw9084Xzm8uxJYPXCggCb4k6tBFG4HXGePTup7FsibN6Mqg7L+DgyhXLh1PLZTVVaKqxWWNBg01DeoQgHp5a2aAhWqxmJsKltwVCOw8XRqXtbVhy2ZFjVtXRYPtcZokhxavHkuBotGVatGemwjI/kgQs5df+kPaGdBlapGSvAZnPQceDCTi2ffK2SpOiwrfpgs3kl
tDi1tIVrIVIvrFxYVIPNhmOsp1/AkgqurQAr14wVYRlfLmxOLb+VJmDlFFUVNgdxeuiBTFsljGv1rLvxLTWS6bD3dSYoP9sRkxQdVumonhOWmqQuoILyN8ckFUfKKuMCamMKLVBhShZFYRhtJrONREuF1XpuZ4VlfI1EcpxhtjeT+Shd76cr/qgO2HoW7xXsTUtSce7N9XycMF6WJklYA2wtbZlKJiapzJ3Rbv0gYhbGpTimwQLbPeeG5aOwxHzbPo
yXKub+KSmOabBaU+b8sClHOji303E+ONGnpDgmwUKbPWeHTX2b5yDLQ2Ick2Cht54f1sn4PKoGC231XCqsFMcEWFhCcqmwYhwTYGEFycXCCnHsD4sISC4VVoxjf1hg2snsYmGFOPaGBTUG7JJhj3HsDYu982JhhTj2hQWli5ldLizfEWEx5eJFwz5ENFhY3ZbZ5cIe49gPFpl2MqsXlu+t2lvKl72RYJFpJ7PaYDlPluPZdDKZTKfzdE3DKiMf4tgP
FqyKC6sFNgUdT96yjkNpYbjYzpYVect9Xc8xi7+wBliezDYpZ1uxOAoX00q8ZT72hMVKihpg+WgdogKLKNyM6bRlHPvOs+iorbyLt9F9Kvk33NFx93HsC4vm40qwfLQJ7Vsa4dZhlw9+/4IEix0RqCQzSLYOqFkwt0c0Wj6NSLD3tcPymTmAJecSQ7mIY/8lHjL9UGEdNX0HWqJvdzRYZPqhir7MEjfd4oTCWsQxARaefohyPm+tT/RKcm3eUqd0F8
HVAA0WVrcZLRxTYHmbCAuu8yiwyRthVzneUFybxzGpSQ4IySmwCU3TFJJGbRbHtL2eOmB54iwkly2ak0btggoLTD++sHxpCuE4zpY88JcRb0lxPImo+7M6iy9sgoNGYbzZpqvZyfYNWAS12zsCax7HTcnmsfEah/G62FMuOhWjaVtL2DEJltFlBtr04wmrqwQK1O1Y6Uxwrp37CEmsaRxTYbXpxwsWEamF2yW0e66Obns6BvtX45AsDVIbyD6wsPww
2iF1r+rbyIaajB8m07EqheRkz1ZRksOarfAB/wPlUTPq+DVvYYXqFMUnfyfDrsjaRUiNF5uWqvKRHmMJlS2iynQQTuQHx3RYZfrxgAWSU7QxNSEkrUA7Whu+lpnYBlDL6AoS3GeaBBc6eRWa6wR50EYz9GElGcTyCon/44kMSxNXF/olxa8GX+V/I6mZ8GSsSRpDGfadDvtC86x+7Cqy1X/HranMdujREC3xKd/LVzIsTVwNBHFsLf8kWWb0gH412q
sV2I9/UGFp4mogiNv2GmGBAwhP6d+jHMbs7tsTDVatjt1gDxtqwgeyNwwlUSY68egzmpKg2N07EZYkrgZO/EYTK6uUn9CujDywi3crefuuR4Mliqv1GXZhQ5V1W/Ebmp422rvVuvKu+4UES1ri7RvznkEsnSTFn0/0oJkqz951hUHrIa4mweqfB3eU8BVtBcfipaKe+rSgueu+E2Bp4mooXTo4VvyKwiX6mAYbjnTYHgEW6Bw7wAILgIWDY4WvyJTN
1GPToV5V3vWEQXtacTUwYp0ahUJSM2UzLpdmIVB7pLDfn3xhIbc5eBZYADi0gIUaUA9MEVZcBMSAX3PYd19YmrhaXqcVH8mhuS/EA+Qs0Y77C+Eb1N/JYLufPWHBf8kOu1NZTWXu8c8Oudi+pfUaRnEcR+FuBv/3DPbLL16wRHE1UBW77FEdYO3rhXT5ON1utnNUWZPBHgbtKcXV0IGyyGHIllVgbF8vMKStKMG+e8FSxdVAo9hh4skmrOwvowifYZ
0tg+35wFLF1UBHUV2UILbchOFiWg2zsAy2+88nd1jsRRZYqPPksOAp/jZJtOPwJMFbDvvdHZYqruZAFGuFurPxZDYn7NLmsO/OsGRxtb4GcPesZpmYKCQoSXLYrjMsJvmywSqndvdj1tJUxKxQndhakoAVsPtBezpxNXhNF00dkdUORWB4/2EB+8MRliyuBnpPmRFg+Wix/978tRUF7LsjLJqerGMWZCVIQYRy37gsAK2A7TrCksXVUH4ybmQgqMmr
sAYCywzT2YI97L+e3GCp4mqoXewvBeHjWOyWA3HBk/F6s9tMwUVPCfvDERY/62KEBZMx8nlxVNGtbWgbhCeTbN2TSVDWBth3V1h0ojXD6mvZAtZhjXd4x0yWCuklSfqvHP4ZcP9oD9v9w7VcxHKUGVbvyOzHnatr+VJV6ur5SXI8lL5K2HzQOq16kE9jhsVuw3SsDHiy1rTmWhNWFkJC+aCE/eEMi+QoGqxTL5WzaQQ0YZWH1Ps2geZcCfvVGRZZ0B
Jh0wnEtjmbPOio2vJQ7w0AtXMJ26162zxtzKYWGWlhVD2PA3Ob/rIDbKY3cGy4QQpcC6y+wyZ8bjSSOR9tQVQt+rm+nw9srBxgf7jD+l/Kgc2z+08+ga6q4zyZ75AjMNq0o/dBoMXyAfarB6z/joD53umoPVNwU9LZK+zUNtBU5a/al2KaerrZLsjpLtKBy0Xh40eT0UGKmsnxNvi5vHasJVpg0x1aPh5hvz2dcBfPfsVcJjKePMzn88l2FxpI21CR
qX+XYEv6CPvuAeu/P+tyD3NcHJm1ien1c0y6ShcuVo6wX31g9RxlWbzrg4pqQBmiweqBrsCmg/Z0mgrj3OPHCu1yqmGMrKYE2G9PJ1TL2DKUMyu8TpJGSdxG6hQB9t0L1lMHxeuBVVW15dvFvdkQVbgKsL3PXgo3patqg93WMWjRRdJxGRAZdnEF2O6XU95cXfHudDNrXn1n+vFwMTUIl0XY736wj36q1OqsRlVyWonMHmZL4x3JIuz7KfXGpoWPI6
ttoW+9sUSE7fnBrvw8C3dTPVipO0MwbPeLF6z8IrumArvL1ZHVozfnBPvdB/bFV1xdybWg1KcS7LsHrNpTJYm+3Fkr3D+CwPY8YNXNSxehJhU1joh3GJhgf/6vM6y2yHMRahLn2mhHvXnEBNv71RlWg3HSG5NyVPhaC6kGe2f+GfcjrK7oc1OSEy7FryMNg7AfAyPtEVZ/kRts4gtLvk7GAZYZaQ+wwIaP4+kP40l3wK1bt9/IoMEaaUtYaCvP9RDT
MnZ3buy9W+0Ja6ItYaFNWuezeO43NoSvNWVhHJYF6A+3m36S1f1IaeL2k2/RopZCwgKL05p+bNfnZLTD7TnpGrzO0YrDorQFLHwhlNeZ99HOjBtFpjV4vbAYbQFbx+VXfIZt4xS/s1W/VzODYRm7R2HBPTzveyp4fh0fcB48zK+qqJFQMAwWpM1gMUWf/61BPJlvolzdUjg0vz5zcjJSZoCFaDNYTBtEuQ8q28Karze7dIzGu9fsJ0pqugoWMRwWoG
W4kJx+Yd2+c1TbnbcGM8DqtAwXkl/y/cYHu+uJJsP2dVj8Gtxrh9VoGTLtZHb1sCotw4XkNwDLBjIsfiX5LcDKtAw/D3ETsEFHGrNI+cRuA1aiveWppzCBlqF34N4KLBtK5SJGcRuwgRTGNS4Ezm/2Mfsow2IrgZuAFeuKHBaZfm4BVupZFJ0K+JTALcAOWxos8YD/BZgFNmgBsBVbqc2ZGVbMTkdY8JTA9cPK64ADLDT9XD2s2lE9bGwBS71rhw2G
LQQWmH6uHVbReIn7s/r0c+Ww+nYeXVx9GWaAHaisIqw2/Vw3LLDfI8a1Ov1cNayWnRRY2iWTzRruWZ21irj6IgyDBcUGVcTVl2CoZwHWauLqCzDUs49WWNplzk0anqCQLcujEa/pbtDI2VjNUFcNa5tnbypBMdYxwz7eFKyxNtYayFcOC21GH00tjq8dVpt+RFi1fXztsFplUdtP2DRk5rbMEIXVGjNXD6tWFlXvJG/aLH3jDgJLPSPQrNma5M8wrP
XX05KPF2i27Y8+CGu9uuFj7yKtK/4fYGNrBcHaLmCXdHMnNyIttBkNwFoORAy6Z2X1gRVpoc3oFx0W2rQ8wvZ752X1gu0dHwdlBvcaLPDUETY5M6on7JHWQUDSsmxZfjw7qyfsgRaEPU4/e1jwXrNBE6mJBFvSgrDHrQHrtWbnTk002D0tDHuYfmxX6/cbYfWHLZIyDHuoLCxqmX4jqCTYjBaBLRe2DJt3ctjzp+EKsD31jIBgAizyffTvfr4yu0O0
evuFLfY7AkEweLyX7S9XYKsOA3mLyoJB804QdFbg+a5rsOeXfqAD5wtbps07GWnTH7ii3T92VN68smDyvBOw4bWT7m01ZBJwNv0woR0TBLdCWtjz4+DIm1UWh0NMt+NTyQQHZ7D9zKVsiB4Uv3rbZ6x0YctWQdB/uV3SwtKMlXr0ng1vnnRvq+EQ1B7cqv0Pc9wIDT8ePVAAAAAASUVORK5CYII="

write-host "Creating install Script"
try{new-item -Path $WorkPath -Name "ChocoDeploy" -ItemType Directory -Force}catch{"Some Error 216"}
$WorkPath = $WorkPath + "\ChocoDeploy"

try{new-item -Path $WorkPath -Name "Source" -ItemType Directory -Force}catch{"Some Error 219"}

$SourcePath = $WorkPath + "\Source"

try{New-Item $SourcePath -Name "install.ps1" -ItemType File -Force}catch{"Some Error 223"}

$InstallScriptContent = "Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"

try{$RequirementRule = New-IntuneWin32AppRequirementRule -Architecture All -MinimumSupportedOperatingSystem 1607}catch{"Some Error 227"}

try{Set-Content ($SourcePath + "\install.ps1") $InstallScriptContent}catch{"Some Error 229"}

try{Remove-Item ($WorkPath + "\install.intunewin")}catch{"Some Error 231"}

Write-Host "Creating Win32 APP Package File"
try{$AppPackage = New-IntuneWin32AppPackage -SourceFolder $SourcePath -SetupFile "install.ps1" -OutputFolder $WorkPath}catch{"Some Error 233"}
write-host "Creating Detection Rule" 
try{$DetectionRule = New-IntuneWin32AppDetectionRuleFile -Existence -DetectionType exists -Path "C:\ProgramData\chocolatey" -FileOrFolder "choco.exe"}catch{"Some Error 235"}

write-host "Starting uploading to intune"
try{$APP = Add-IntuneWin32App -FilePath $AppPackage.Path -DisplayName "Chocolatey" -RequirementRule $RequirementRule -Notes "FiredWithPowershell" -Description "Chocolatey Package Manager" -Publisher "www.linkedin.com/in/LuEd" -RestartBehavior suppress -InstallExperience system  -Icon $Icon -InstallCommandLine "powershell.exe -executionpolicy bypass .\install.ps1" -UninstallCommandLine "powershell.exe -executionpolicy bypass .\uninstall.ps1" -DetectionRule $DetectionRule}catch{"Some Error 237"}

write-host "Make application installable for everyone in the company"
try{Add-IntuneWin32AppAssignmentAllUsers -ID $App.id -Intent available -Notification hideAll }catch{"Some Error 239"}
if ($APP.id -ne $Null){
write-host "chocolatey successfully installed."
return $APP.id
}
else{
return "Some Error Occured"
}
}# Deploys Chocolatey to Intune-Tenant

function get-ChocoWin32ID {

while($true){

$APP = Get-IntuneWin32App -DisplayName "chocolatey"

if ($APP.notes -like "*FiredWithPowershell*"){
write-host "chocolatey found "
return $APP.id}
else{
write-host "Chocolatey not found in intune, it will be deployed now"
$Install = install-chocolatey

}}



}#Returns the Intune ID of the Cocolatey App in Intune

function Get-ChocoIconBase64{
param(
[String[]][parameter(Mandatory=$true)]$ChocoName
)
set-alias inkscape "C:\Program Files\Inkscape\bin\inkscape.exe"
$BaseURL = "https://community.chocolatey.org/content/packageimages/"
$IconName = choco search --exact $ChocoName --detail
$IconName = $Iconname[1].split("[")[0].split()[0] + "." + $Iconname[1].split("[")[0].split()[1]


$Icon = $BaseURL + $IconName + ".png"


try{ $Output =  curl $Icon }catch{

$Icon = $BaseURL + $IconName + ".svg"
$FilePath = ($ENV:Temp +"\"+ $ChocoName + ".svg")
$WebClient = New-Object System.Net.WebClient
$WebClient.DownloadFile($Icon,$FilePath)

inkscape --export-type="png" $FilePath

$FilePath = ($ENV:Temp +"\"+ $ChocoName + ".png")

write-host "Icon file is in .svg format it will be converted to PNG"
write-host "starting converting Image, waiting 5 Seconds"
Start-Sleep -s 5


$Base64Coded = [convert]::ToBase64String((Get-Content $FilePath -Encoding byte))

return $Base64Coded.tostring()


}

$FilePath = ($ENV:Temp +"\"+ $ChocoName + ".png")
$WebClient = New-Object System.Net.WebClient
$WebClient.DownloadFile($Icon,$FilePath)

$FilePath = ($ENV:Temp +"\"+ $ChocoName + ".png")

$Base64Coded = [convert]::ToBase64String((Get-Content $FilePath -Encoding byte))

return $Base64Coded.tostring()




}#Returns a Intune-Deployment-ready Base64-Coded PNG File grabbed from The Choco-Site

function Get-ChocoPackageBySearch{

Import-Module -Name chocolatey
Write-Host "Enter the Software you want to Install: "
$SearchPattern = Read-Host

$Selection = Get-ChocolateyPackage -Name $SearchPattern | Out-GridView -Title "Select Application" -PassThru

return $Selection.Name

}

function New-IntuneWin32ChocoApplicationInstallFromRepo{

$Content = '
"Adobe Acrobat Reader DC","adobereader"
"Google Chrome","googlechrome"
"Mozilla Firefox","firefox"
"Java SE Runtime Environment","jre8"
"Microsoft Visual C++ Redistributable for Visual Studio 2015-2022","vcredist140"
"Notepad++","notepadplusplus"
"Python 3.x","python3"
"Python 2.x","python2"
"Adobe AIR Runtime","adobeair"
"7-Zip","7zip.install"
"Microsoft Visual C++ Redistributable for Visual Studio 2015","vcredist2015"
"Microsoft .NET Framework 4.8","dotnetfx"
"VLC media player","vlc"
"Git","git.install"
"Microsoft Edge","microsoft-edge"
"Zoom Client for Meetings","zoom"
"Microsoft Silverlight","silverlight"
"Sysinternals","sysinternals"
"Foxit PDF Reader","foxitreader"
"Paint.NET","paint.net"
"Teamviewer (Install","teamviewer"
"Skype","skype"
"Putty","putty.install"
"Java SE","jdk8"
"Visual Studio Code","vscode"
"FileZilla","filezilla"
"PDF Creator","pdfcreator"
"Dot Net 3.5","dotnet3.5"
"Dot Net 4.5.2","dotnet4.5.2"
"Windows Terminal","microsoft-windows-terminal"
"WinSCP","winscp.install"
"Inkscape","inkscape"
"Dropbox","dropbox"
"Wireshark","wireshark"
"Process Explorer","procexp"
"Advanced IP Scanner","advanced-ip-scanner"
"Opera","opera"
"Everything","everything"
"Microsoft OneDrive Sync Client","onedrive"
"Teamviewer Host","teamviewer.host"
"Teamviewer QuickSupport","teamviewer-qs"
"WinDirStat","windirstat"
"Adobe Creative Cloud Client","adobe-creative-cloud"
"Greenshot","greenshot"
"Process Monitor","procmon"
"PSExec","psexec"
"Sublime Text 4","sublimetext4"
"Power BI Desktop","powerbi"
"Rufus","rufus"
"Veeam Agent for Microsoft Windows","veeam-agent"
'

$Softwarelist = $Content | ConvertFrom-CSV -Delimiter "," -Header "Name","ChocoName"

$SelectedSoftware = $Softwarelist | Out-GridView -PassThru -Title "Select software to deploy"

foreach($Software in $SelectedSoftware){

    New-IntuneWin32ChocoApplication $Software.ChocoName

}


}


Write-Host "Insert Tenant Name:"
$Tenant = Read-Host

Connect-MSIntuneGraph -TenantID $Tenant

New-IntuneWin32ChocoApplicationInstallFromRepo
