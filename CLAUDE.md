# IntuneChocoDeployment

Team: read `.claude/team/README.md` and `.claude/team/RULES.md`. The lead is the session "IntuneChocoDeployment CTO".

- PowerShell 5.1 tool (WPF GUI `Start-IntuneChocoTool.ps1`, `UI/*.xaml`) that publishes Chocolatey and winget packages as Intune Win32 apps. Core: `ChocoIntuneDeployment-Main.ps1` (Chocolatey, device scripts, Intune calls), `ChocoIntuneDeployment-Winget.ps1`, `Modules/Keevault.psm1` (sign-in), `catalog.json`.
- State lives in Intune only (app notes carry package and update policy); no local database. Settings in `%LOCALAPPDATA%\IntuneChocoDeployment`.
- Generated device scripts run as SYSTEM through the Intune Management Extension: plain ASCII, Windows PowerShell 5.1, SIDs instead of group names, every choco/winget call inside the `Global\IntuneChocoDeployment` mutex. Raise `DeviceScriptRevision` when they change.
- Checks: `Tests\Invoke-GuiSmoke.ps1` (off-screen GUI with fake IntuneWin32App module and fake sign-in, never a real tenant). README tour: `Tests\Record-Demo.ps1` (needs img2webp).
- The repo is public: no tenant data, IDs or customer names in code, docs, tests or commits.
- Redesign target (Nov 2026): https://claude.ai/artifact/Aw8sZU6LLLb5EZZBtxoSXq
