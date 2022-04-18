![image](https://user-images.githubusercontent.com/9081611/163731912-44660347-56b9-4a20-a571-bd1139bc2636.png)

# Deploy Intune Win32 Applications automated with chocolatey
## Description
With this script you automate the APP-Deployment.
You can publish Chocolatey APPs with intune and keep them up2date.
The Script automaticly creates the application, and installs automaticly the required chocolatey application.
It also downloads the Application-Icons from Chocolatey to make it watching nice in the Customer Portal, if you dont want to install it automaticly
The Application is published automaticly for every user.
You can also make it be installed automaticly

For keeping the installed software updated, the Installer creates a Scheduled Task for every application with fires a "choco upgrade <application> -y" on every startup for every deployed application
  
Special thanks to Brad Wyatt who gave me the the incentive to that automation 
https://www.thelazyadministrator.com/2020/02/05/intune-chocolatey-a-match-made-in-heaven/

## Install-Guide
1. Start powershell with elevated rights.
2. Download The Script and Save it for example to C:\admin
3. Install and Import all required Modules, chocolatey and Software for icon-converting.
```powershell
set-executionpolicy unrestricted # not needed but my one is set so, you can try it with other policies
Install-Module IntuneWin32App -Force
Import-Module IntuneWin32App
Install-Module Microsoft.Graph.Intune -Force
Import-Module Microsoft.Graph.Intune
Install-Module -Name chocolatey
Import-Module -Name chocolatey
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
choco install inkscape -y
```
4. OPTIONAL IF YOU USE IT MANUALLY Connect to Intune Graph API (Multi-Tenant Use is possible) 
```powershell
Connect-MSIntuneGraph -TenantID "contoso.com"
```
5. OPTIONAL IF YOU USE IT MANUALLY Import Downloaded Script (in this sample from C:\admin)
```powershell
import-module "C:\admin\ChocoIntuneDeployment-Main.ps1"
```
## How to Use
![Animation](https://user-images.githubusercontent.com/9081611/163805757-500bed68-a553-48db-b468-c3f8e62f25dd.gif)
  
in simplest way, easy run the script.

First you will be asked, what tenant you want to connect and you will be asked for M365 Creds to authenticate to Graph API

Then you can choose the software you want to install. (Hold STRG to select more then One)

Start the Process With OK
  

Everything else is done automaticly now
  
### Optional Steps
### Adding Applications to the Softwarelist
You can easy add software you like to the list.
You need to find following line and add Software in following pattern
```powershell
 "<Description>","<choconame>"
```
```powershell

$Content = '
<ADD YOUR CONTENT HERE>
"Adobe Acrobat Reader DC","adobereader"
"Google Chrome","googlechrome"
"Mozilla Firefox","firefox"
"Java SE Runtime Environment","jre8"
.
.
.
```

### Install Chocolatey Manually
This step is only required, if you want to install it manually or the automatic process is not working.
Normaly, chocolaty will be installed automaticly befor you publish the first application
```powershell
install-chocolatey
```
### Create a new Application
Installing a new Application is done simply by running the main function
```powershell
New-IntuneWin32ChocoApplication
```
You will be prompted to enter a pattern of what Software you want to install.
After that select the wanted software.

By default the Software is published but not autoinstalled for every user in the intune Tenant.
To make it automaticly installed add the Switch -Required
```powershell
New-IntuneWin32ChocoApplication -Required
```

If you know the exact chocolatey name, you can also deploy the software without any userpromt
```powershell
New-IntuneWin32ChocoApplication "googlechrome"
```
### Results:
New created Windows applications
![image](https://user-images.githubusercontent.com/9081611/163807675-df7319ab-3104-43ee-8707-7a8c0b0f0255.png)

Configured chocolatey Application with detection Rule

![image](https://user-images.githubusercontent.com/9081611/163807786-8cad4527-6922-46b2-a650-ad29a70e82b1.png)

Deployed application with detection script, dependency to the choco application and available for all users

![image](https://user-images.githubusercontent.com/9081611/163807922-685e9195-9568-4833-9e5f-3167d731efe5.png)


![image](https://user-images.githubusercontent.com/9081611/163808042-c876dcd3-3d1b-4f7d-a150-0917ee611f53.png)
  
Result shown in Company Portal:

![image](https://user-images.githubusercontent.com/9081611/163808208-c31b7b10-3db3-4a03-b657-591bcb241625.png)

Configured Update Task in Task Scheduler
  
![image](https://user-images.githubusercontent.com/9081611/163808457-a48c8598-1e48-474e-a397-7e471d5f6f80.png)

  


