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

## Requirements
- Windows 10 or Windows 11, Windows PowerShell 5.1 or PowerShell 7 (the graphical interface runs in Windows PowerShell 5.1)
- The PowerShell module [IntuneWin32App](https://github.com/MSEndpointMgr/IntuneWin32App) 1.5.0 or newer
- An Entra ID app registration (see below)

Chocolatey and Inkscape are **not** needed on the admin machine anymore: package infos and icons come straight from the
chocolatey.org feed, SVG icons are converted with Microsoft Edge.

## Install-Guide
1. Download the script and save it, for example to C:\admin
2. Install the required module once (no admin rights needed):
```powershell
. C:\admin\ChocoIntuneDeployment-Main.ps1
Install-IntunechocoComponents
```
3. Create an app registration in Entra ID (once per tenant). Microsoft retired the shared "Microsoft Intune PowerShell" app,
   so IntuneWin32App needs your own. **The graphical interface does this for you** (*Set up everything* or *Create* on
   the start page, or `New-IntuneChocoAppRegistration` on the command line): you sign in once with a Global Administrator
   through Microsoft's "Microsoft Graph Command Line Tools" app, and the tool creates the registration "Intune Chocolatey
   Deployment" with the permissions below, grants the admin consent and saves tenant and client ID. By hand:
   - Entra admin center > App registrations > New registration, any name (e.g. "Intune Choco Deployment")
   - Authentication > Add a platform > Mobile and desktop applications > Redirect URI `http://localhost`
   - API permissions > Microsoft Graph > Delegated: `DeviceManagementApps.ReadWrite.All`, `DeviceManagementConfiguration.ReadWrite.All`,
     `DeviceManagementRBAC.Read.All`, `Group.Read.All`, then grant admin consent
   - Note the Application (client) ID

## Graphical interface
Double-click **Start.cmd** (or run `powershell.exe -ExecutionPolicy Bypass -File C:\admin\Start-IntuneChocoTool.ps1`).
The tool is a WPF window for Windows PowerShell 5.1, without a console window next to it.

- **Package source**: the switch in the header sets **Chocolatey** or **winget** (see below), the active one is filled
  light; the choice is remembered.
- **Start**: guided steps and a readiness list (modules, app registration, sign-in, Chocolatey app in the tenant). An item
  that is not ready is red, says why and has the button that fixes it; **Set up everything** runs all fixes one after
  another (install the modules, create the app registration with admin consent, sign in, deploy the Chocolatey app).
- **Sign in**: opens the Microsoft sign-in in your browser and waits up to five minutes for it; the button turns into
  *Cancel sign-in* meanwhile. The sign-in is renewed silently during long runs. The arrow next to it offers
  **Sign in with Keevault**: you pick the Microsoft account in [Keevault](https://keevault.de), and user name, password and
  one-time code are filled into an embedded sign-in window (WebView2). Needs Keevault with *AI agents (MCP)* switched on;
  the token stays in this process. Keevault lists the accounts of the configured tenant first, all other Microsoft
  accounts below. Picking an account of another tenant switches the tool to that tenant: with the app registration
  used there before, or, the first time, with *Create* on the start page to set one up.
- **Catalog**: curated apps by category with icons, versions, publishers and license notes. Select several apps
  (Ctrl+click / Shift+click, the selection is kept across filters), choose the assignment (available, required, none),
  version and automatic updates, and deploy them in one go (see [Updates](#updates)).
- **Search**: the whole Chocolatey community repository (or your metadata feed).
- **Details**: description, links, license note, and a custom icon for any package (PNG, JPEG, SVG, ICO).
- **In tenant**: the Win32 apps this tool created, with a link to each app in the Intune admin center and
  *Remove from Intune* (only apps this tool created; Chocolatey stays while other apps depend on it). Catalog and
  search mark apps that are already in the tenant and do not deploy them twice. Select an app to change its version and
  automatic updates below the list (**Apply in Intune**); a pinned app with a newer version offers **Release <version>**
  (see [Updates](#updates)).
- **Test in sandbox**: tests a package with the chosen settings in a Windows Sandbox before it goes to Intune (from the
  deploy panel, or under In tenant), via
  [MSIX Sandbox Studio](https://github.com/dominguez-posh/WindowsSandboxMSIXInstaller) (Win32 Test Lab). The tool finds
  it next to this repo, in `C:\git\WindowsSandboxMSIXInstaller` or as installed module; otherwise set the path in Settings.
- **Activity**: deployments run one after another in the background, the window stays usable; every step is logged,
  also to a log file per day (`%LOCALAPPDATA%\IntuneChocoDeployment\logs`, button *Log files*).
- **Settings**: tenant and client ID, deployment defaults, update defaults for new apps, update delay, package sources,
  the Sandbox Studio path and the module installation.
  Saved in `%LOCALAPPDATA%\IntuneChocoDeployment\settings.json` and also used by the command line functions.

Package infos are cached for 24 hours; SVG icons are rendered once with Edge and kept in the work folder
(`%LOCALAPPDATA%\IntuneChocoDeployment`, button *Open work folder* in the settings).

## How to Use (command line)
![Animation](https://user-images.githubusercontent.com/9081611/163805757-500bed68-a553-48db-b468-c3f8e62f25dd.gif)
  
in simplest way, easy run the script.
```powershell
C:\admin\ChocoIntuneDeployment-Main.ps1 -TenantID "contoso.onmicrosoft.com" -ClientID "<application id>"
```
Without parameters you will be asked for tenant and client ID. A browser window opens for the sign-in.

Then you can choose the software you want to install. (Hold STRG to select more then One; in PowerShell 7 you get a numbered list instead)

To use the functions manually, dot-source the script and connect:
```powershell
. C:\admin\ChocoIntuneDeployment-Main.ps1
Connect-IntuneChoco -TenantID "contoso.onmicrosoft.com" -ClientID "<application id>"
```

Start the Process With OK
  

Everything else is done automaticly now
  
### Optional Steps
### Adding Applications to the Softwarelist
The software list lives in [catalog.json](catalog.json), used by the GUI and by the command line:
```json
{ "id": "<choconame>", "winget": "<winget id, optional>", "name": "<Description>", "category": "<Category>" }
```
`winget` is the id of the same app in the winget repository (e.g. `7zip.7zip`); entries without it only show up when
Chocolatey is the package source.

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
To make it automaticly installed add the Switch -Required, or choose the assignment explicitly
```powershell
New-IntuneWin32ChocoApplication -Required
New-IntuneWin32ChocoApplication "vlc" -Assignment None   # Available, Required or None
```

If you know the exact chocolatey name, you can also deploy the software without any userpromt
```powershell
New-IntuneWin32ChocoApplication "googlechrome"
New-IntuneWin32ChocoApplication "vlc", "7zip.install" -NoIconPrompt
```
If a package has no icon on chocolatey.org, you can pick a file (Cancel creates the app without icon),
pass one with `-IconFile C:\icons\app.png`, or skip the question with `-NoIconPrompt`.

Update mode, grace period and version can be set per app:
```powershell
New-IntuneWin32ChocoApplication "vlc" -UpdateMode Custom -GraceHours 48
New-IntuneWin32ChocoApplication "7zip.install" -Version current -UpdateMode Off   # pin today's version
Update-IntuneChocoApp -AppId <intune app id> -Version 3.0.21                      # release a new version
Update-IntuneChocoApp -AppId <intune app id> -UpdateMode Startup                  # change only the settings
Test-IntuneChocoPackage -ChocoName vlc                                            # Windows Sandbox test
```

### Updates
Each app has its own update mode, stored in the app notes in Intune (`update=` and `grace=`):

| Mode | Behaviour on the device |
|------|-------------------------|
| **Off** | No automatic updates. The device gets a new version only when you release it in the tool. |
| **Startup** | The update is installed at the next PC start (after the random delay). |
| **Custom** | Checked at startup and every 4 hours. When an update is available, signed-in users get a popup and can install it right away or snooze it. After the grace period (hours or days) it is installed automatically, without waiting for a restart. |

The version is either **latest** (the device follows the newest version on the feed) or **pinned** to one version.
For pinned apps, **Release** in the tool (or `Update-IntuneChocoApp -Version`) moves the app to a new version. The
update mode then decides when devices install it.

Settings changes take effect without redeploying. The detection script compares a fingerprint of the policy with
`%ProgramData%\IntuneChocoUpdates\<package>\policy.txt`. After a change in Intune, detection fails, Intune runs
`install.ps1` again, and that applies the new settings.

Apps created by older versions keep working. They count as **latest / Startup** until you change their settings.

### What gets deployed
- `install.ps1` runs `choco upgrade <package> -y` as SYSTEM in 64-bit PowerShell and copies `update.ps1` and
  `notify.ps1` to `%ProgramData%\IntuneChocoUpdates\<package>`. It also registers the scheduled tasks under
  `\Intune-Choco-Updates\`:
  - `Update <package> on startup` (Startup and Custom modes). Each device waits a random 5 to 60 minutes after startup
    (configurable), so many devices behind one IP don't download at the same time.
  - `Check <package> for updates` (Custom mode) runs every 4 hours.
  - `Notify <package> update` (Custom mode) shows the popup in the user session.
  - `Update <package> now` (Custom mode) is started by the popup. Users may start it, and it runs as SYSTEM.

  Uninstall removes the tasks and the folder again.
- With a package source configured, install and update task use `choco --source <your feed>`.
- The detection script checks `%ProgramData%\chocolatey\lib\<package>` and the policy fingerprint.
- The app gets a dependency to the Chocolatey app (auto install), which is deployed once per tenant.
  Its installer retries with a random wait when the Chocolatey download is rate limited.
- Requirement: Windows 10 1607 or newer (includes Windows 11), x64/x86. Use `-Architecture AllWithARM64` for ARM devices.

### winget packages
The package source switch in the header (Chocolatey | winget, the active source is filled light) switches catalog,
search and deployment between Chocolatey and winget. On the command line:
```powershell
New-IntuneWin32WingetApplication -WingetId "7zip.7zip", "VideoLAN.VLC" -Assignment Available
```
- Package infos and the search come from Microsoft's `Microsoft.WinGet.Client` module (installed by
  `Install-IntunechocoComponents`) and the manifests in [winget-pkgs](https://github.com/microsoft/winget-pkgs).
- `install.ps1` runs `winget install --id <id> --exact --scope machine --silent` as SYSTEM (falling back to no scope
  for packages without a machine installer). winget is not in SYSTEM's path, so the script takes the newest App
  Installer from `WindowsApps` and waits up to ten minutes when it is not registered yet (right after Autopilot).
- Update modes, grace period, pinned versions and the sandbox test work as for Chocolatey apps (see [Updates](#updates));
  the tasks are under `\Intune-Winget-Updates\`, the helpers in `%ProgramData%\IntuneWingetDeployment\<id>`. winget cannot
  go back to an older version, so a pinned winget app only moves forward. Apps deployed before keep working and count
  as **latest / Startup** until you change their settings.
- Uninstall runs `winget uninstall` and removes the tasks. Logs: `%ProgramData%\IntuneWingetDeployment\Logs`.
- The detection script runs `winget list --id <id> --exact` and checks the policy fingerprint. Requirement: Windows 10
  1809 or newer.
- No dependency app: winget is part of Windows. winget downloads from the vendors' sites, so there is no repository
  rate limit. Packages rarely have an icon in winget; catalog apps use the icon of their Chocolatey package.
- An app that already exists under the same name (e.g. from Chocolatey) is skipped, so nothing is installed twice.

## Licenses and rate limits
- Chocolatey itself is Apache 2.0. The installed software keeps its own license. The tool shows a note for packages with
  known restrictions (Oracle Java, TeamViewer, AnyDesk, Adobe Reader distribution, Sublime Text, 1Password); the catalog
  uses Eclipse Temurin instead of Oracle Java.
- Chocolatey [does not recommend](https://docs.chocolatey.org/en-us/community-repository/community-packages-disclaimer/)
  organizational use of the community repository and rate limits it (about 20 package downloads per minute and IP,
  temporary blocks at heavy use). For larger environments put a caching proxy or internal repository (ProGet, Nexus,
  Azure Artifacts) in front and set it as package source.
- Package infos are read with the NuGet v2 queries choco itself sends (choco 1.x style, falling back to the choco 2.x
  style). Chocolatey does not guarantee other OData query forms, so the catalog has no batch lookup and caches results for 24 hours.
### IntuneWin32App on non-English Windows
IntuneWin32App 1.5.0 checks the token expiry by writing the date in the current culture and reading it back in US
format. On a German (or any day-first) Windows a fresh token then counts as expired, the module tries to renew it
and gives up with `break`, which silently ends the calling script. This tool runs every module call with the invariant
culture and turns such a give-up into a visible error, so it works on any Windows language.

## Tests
`Tests\Invoke-GuiSmoke.ps1` starts the interface off-screen with a fake IntuneWin32App module (`Tests\Fakes`) and its own
`%LOCALAPPDATA%`, drives every page (sign-in with cancel and token renewal against a local stand-in for the Microsoft
sign-in, catalog, search, custom icon, deployments, tenant with removal, settings, sign-out) and checks the results.
Nothing shows up on the desktop and nothing is sent to a tenant; package infos come from the real Chocolatey feed. Screenshots of every page land in `%TEMP%\IntuneChocoSmoke`.

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

  


