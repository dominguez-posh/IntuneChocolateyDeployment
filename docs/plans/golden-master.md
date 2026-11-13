# Plan: Golden Master Deployment mode

Status: PLAN only, no product code. Author: Feature-Entwickler Golden Master. Branch `feature/golden-master`. Needs CTO go and the user's answers (section 13) before building. Security relevant (elevation, service toggling, sysprep, downloads), so the Sicherheitspruefer reviews each phase.

Sources named below were taken from my knowledge of the projects and Microsoft Learn, not re-fetched in this step. Phase 0 verifies every license and URL again and records the commit hash and license text of anything we copy.

## 1. Goal

A button "Golden Master Deployment" switches PackTune from the Intune workspace to a Golden Master workspace for preparing a reference image (VDI, AVD, Citrix, VMware Horizon, or a plain reference image). It runs locally on the master, elevated, uses the same catalog (`catalog.json`, winget, Chocolatey) to install and update software without Intune, automates Windows, Office and optimization steps, and writes a versioned state file plus exportable documentation.

Non-goals (first version): managing a fleet of masters from one console, replacing MDT/Packer/Image Builder pipelines, Citrix Optimizer integration beyond launching it if present.

## 2. Key decisions (summary)

1. Separate process, elevated on entry. The normal tool stays non-elevated. The button starts a second instance (`Start-IntuneChocoTool.ps1 -GoldenMaster`) with `Start-Process -Verb RunAs` (UAC prompt) and the main window offers "Zurueck" by closing it. No elevation switching inside one process (impossible), no Intune sign-in in the GM process.
2. Engine first, UI second. A new module `Modules/GoldenMaster.psm1` holds all steps as small units with one contract (below). UI and CLI (`Invoke-GoldenMaster -Plan x.json -WhatIf`) call the same engine. This makes dry-run and tests possible.
3. Every step is `Test` / `Apply` / (optional) `Undo`, idempotent, optional, explained, with a risk level and a preset membership. Nothing is on by default except read-only detection.
4. State in a JSON file on the master (source of truth), documentation rendered from it. History is append-only, one file per run plus a `current.json`.
5. Windows Updates through the WUA COM API (`Microsoft.Update.Session`), no PSWindowsUpdate dependency.
6. Reuse VDOT (MIT) as data, not as a runtime dependency: we import its JSON configuration idea and re-implement the steps in our contract, with attribution.
7. Real runs are tested in Windows Sandbox / throwaway VM only. Never on a developer machine. Dry-run is the default in the UI for the first run.

## 3. Reuse of open source

| Work | License (verify in Phase 0) | Use |
|---|---|---|
| Virtual Desktop Optimization Tool, `The-Virtual-Desktop-Team/Virtual-Desktop-Optimization-Tool` | MIT (my recollection; confirm LICENSE file) | Best source for the optimization lists: AppX removal, services, scheduled tasks, autologgers, network and registry tweaks, per Windows version JSON. Copy the data (names, values) into our own step catalog with a NOTICE entry. Do not shell out to its script (it is unsigned, changes behavior between releases, and has no idempotent report). |
| Microsoft `Azure/RDS-Templates` (`CustomImageTemplateScripts`, AVD image scripts) | MIT (confirm per repo) | Reference for FSLogix install, Teams media optimization, language pack, Office, "Remove-AppxPackages", sysprep wrapper. Re-implement; borrow ordering. |
| Microsoft Learn: "Prepare and customize a master VHD image" (AVD), "Install Office on a master VHD image", "Optimize Teams for AVD", "FSLogix", "Sysprep", "Office shared computer activation", "ODT reference" | documentation (read only, link in generated docs) | Authoritative step order and registry values. Cite the page in each step's `Source` field. |
| Office Deployment Tool (`setup.exe`) | Microsoft EULA, redistribution not allowed | Download at run time from the official Microsoft link, verify Authenticode (Microsoft Corporation, valid chain) and optionally pinned SHA-256, never bundle. |
| FSLogix, Teams VDI components, language packs | Microsoft EULA | Download at run time from aka.ms links, verify signature. FSLogix is also in winget (`Microsoft.FSLogix` style id, check) which gives hash verification for free. |
| `PSWindowsUpdate` | MIT-like (community) | Not used. WUA COM API instead (below). |
| `Citrix Optimizer` | proprietary, not redistributable | Only: if user has it installed, offer "Run Citrix Optimizer template" step as an external launcher. Not in scope for v1. |
| Windows Sandbox config (.wsb), Pester | Microsoft / Apache 2.0 | Test harness. Pester only for local dev, not shipped. |

Rule: a step catalog entry carries `Source` (URL), `License`, `Upstream` (commit or doc date). `NOTICE` file lists third-party data with license text. Nothing without a clear license is copied.

## 4. Architecture

```
Start-IntuneChocoTool.ps1 -GoldenMaster      (own WPF window, elevated)
  UI/GoldenMaster.xaml                        (sections, see 8)
  Modules/GoldenMaster.psm1                   (engine, no UI)
  GoldenMaster/steps/*.json                   (step catalog as data: id, title, why, risk, source, params)
  GoldenMaster/steps/*.ps1                    (Test/Apply/Undo scriptblocks for steps that need code)
  GoldenMaster/presets/*.json                 (VDI-multisession, VDI-persistent, Reference, Citrix, minimal)
  GoldenMaster/templates/*.html|md            (export templates)
```

Reuse from the existing tool: catalog loading and winget/Chocolatey helpers (`ChocoIntuneDeployment-Winget.ps1`: `Get-Winget`, `Invoke-Winget`, `Get-PendingUpdate`, `Invoke-Upgrade`; Sources/Runtime scripts), the `Global\IntuneChocoDeployment` mutex around every choco/winget call, Theme.xaml. Shared code that is device-script-like stays plain ASCII, PS 5.1.

Step contract (all steps):

```
Id, Title, Section, Why (plain text), Risk (low|medium|high), RequiresReboot, Presets[],
Test  -> { State: Applied|NotApplied|Partial|Unknown; Detail }
Apply -> { Result: Changed|Unchanged|Failed|Skipped; Detail; Before; After }   # honors -WhatIf
Undo  -> optional; steps without Undo are flagged "not reversible" in the UI
```

Rules: Apply calls Test first (idempotent). Registry/service/task changes record the prior value in the run record so Undo and the diff have data. No step shells out with string-built commands from catalog data (use argument arrays). Everything runs inside try/catch with the step result persisted after each step, so a crash or reboot resumes.

## 5. Elevation, local and remote

- Local, elevated: UAC prompt on entering the mode. The GM process refuses to start un-elevated (`WindowsPrincipal.IsInRole(Administrator)`), so no half-working mode. Own mutex `Global\PackTuneGoldenMaster` allows one run at a time.
- The Intune process is never elevated and the GM process loads no Intune/Graph tokens, keeping the blast radius small.
- Remote (phase 5, optional): run the same engine on a VM via PowerShell Remoting (`Invoke-Command -ComputerName`/`-VMName` over PowerShell Direct for Hyper-V). The engine module is copied to the target and executed there, results returned as JSON. UI works on the aggregated result. Reasons to defer: credentials handling, WinRM setup, double hop. v1 is "run PackTune on the master" (or inside the VM), which is what most image builders do.
- Reboot handling: a resume mechanism via a RunOnce entry that starts the engine with `-Resume <runId>` (elevated through the autologon-free path: RunOnce runs in the user's context; if the user is admin it is elevated only with UAC off, so instead use a scheduled task "PackTune GM Resume" running as SYSTEM at startup that executes the engine headless and writes progress to the state file; the UI re-attaches on next start). Task is removed when the run ends.

## 6. Steps (proposed catalog)

Each step optional, explained, with preset membership. Presets: "VDI multi-session (AVD/Citrix/Horizon)", "VDI persistent", "Reference image (light)".

### Software
- Detect: read winget list and `choco list -lo` and match against `catalog.json` ids (same matching as the Intune side), mark Installed / Update available / Not in catalog. Also show installed software the catalog does not know (read-only, with "add to catalog" link).
- Install new from catalog, Update all, Update per app, Remove. Silent, inside the mutex, logs per app, versions recorded in state.
- Optional: install pinned versions (version field in plan) so a master is reproducible.

### Windows Updates (WUA)
- Procedure (the service is disabled on the master): remember start type and state of `wuauserv`, `UsoSvc`, `bits`, `WaaSMedicSvc` (note: WaaSMedic is protected and often resists changes; detect and report, do not fight it), set Manual, start, search with `IUpdateSession.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Software'")`, filter (exclude drivers by default, exclude preview, optional KB exclude list), download, install via `IUpdateInstaller` (`IUpdateDownloader`), record KB, title, result code per update, reboot required flag. In a `finally` block: restore the previous start type and stop, so a crash does not leave the service on (plus a verification step at the end of every run: "Windows Update service is Disabled").
- Alternative path for fully offline masters: WSUS or Microsoft Update Catalog downloads are out of scope for v1.
- Disabling Windows Update on the master (step in Security): service `wuauserv` Disabled, policy `NoAutoUpdate=1` and `AUOptions`, optionally remove access ("Remove access to use all Windows Update features"). Document clearly that this means the image is patched only by rebuilding (image lifecycle), and that production session hosts typically patch via image version, not Windows Update.
- Risk: Windows 11 UsoSvc/WaaSMedic may re-enable the service. The final verification step catches and reports it; the policy approach is the reliable one.

### Office (Microsoft 365 Apps, ODT)
- Download `setup.exe` from the official Microsoft download link, verify Authenticode (publisher Microsoft Corporation, status Valid), optional pinned hash. Generate `configuration.xml` from a form: channel (Current, Monthly Enterprise, Semi-Annual Enterprise), architecture, products, excluded apps (Teams, OneDrive, Groove, Lync), languages, `SharedComputerLicensing=1` for multi-session, `AUTOACTIVATE`, `PinIconsToTaskbar=FALSE`, `Updates Enabled=FALSE` on the master (updates by rebuild or by ODT step in the tool), `DisplayLevel=None`.
- Install, update (`/configure` with same config), uninstall (`/configure` with Remove). Detect Office build from `ClickToRun\Configuration` (`VersionToReport`, `CDNBaseUrl`, `SharedComputerLicensing`).
- Config is a file in the state folder and part of the export. Teams: "new Teams" installed separately (below).
- Open: whether to support a local ODT source (`/download` to a network share) for faster repeat builds.

### Optimizations and performance
- Data-driven from VDOT-style lists: remove AppX provisioned packages (with allow-list), disable unneeded services, scheduled tasks, autologgers, visual effects, network (TCP, DNS), disable hibernation, disable Storage Sense, indexing, Cortana/Copilot/widgets, consumer features, telemetry level (Security/Required, honest note on what it does), power plan High performance, page file policy, time zone and redirection, RDP settings (`fEnableTimeZoneRedirection`, graphics, `MaxMonitors`), screen saver off.
- Each entry shows the registry path/service/task name, before/after, source.

### Security
- Windows Update off (above), Defender settings for VDI (exclusions for FSLogix VHD(X) and profile paths, scan exclusion for the profile share, optional "disable scheduled scan randomization", cloud-delivered protection stays on), SmartScreen/Edge policies (first-run, update off, sync off), OneDrive per-machine install and Known Folder policy, BitLocker note, disable unused features/capabilities, TLS settings, local admin and password hygiene (report only), `DisableAutoplay`. Defaults are conservative and nothing weakens security without a visible "this lowers protection" label.
- No credentials or secrets are ever written to the state file.

### VDI components
- FSLogix (install or update, set profile container registry keys, redirections.xml template), new Teams with VDI media optimization (WebRTC redirector, MsTeamsPlugin, registry `IsWVDEnvironment`), language packs and Features on Demand via `Add-WindowsCapability`/`Install-Language` (needs Windows Update or an FoD ISO; document), Azure Virtual Desktop agent and boot loader are NOT installed on the master (documented, they are installed on the session host, not the master image), but optional "AVD prerequisites check".

### Cleanup and seal
- Cleanup: `Dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase` (irreversible, warn), clear temp folders, Windows Update download cache (`SoftwareDistribution\Download`), event logs, `cleanmgr` profile, delete shadow copies, delete user profiles other than the builder (with explicit list), empty recycle bin, clear Prefetch (optional), `sdelete`-style zero free space (optional, slow, only for thin disks; uses `cipher /w`).
- Seal (optional, last, never default): checks (pending reboot, pending updates, apps provisioned for a single user that break sysprep, e.g. Store apps updated per user), then `sysprep /generalize /oobe /shutdown /mode:vm` with optional unattend. Known blockers listed, `setupact.log` and `setuperr.log` parsed for the report. After sysprep the machine shuts down; the state file is written BEFORE sysprep and marked `sealed`.
- Hypervisor snapshot reminder before seal (we cannot make it, see section 9).

## 7. State, history, export

Location on the master: `C:\ProgramData\PackTune\GoldenMaster\` (ACL: Administrators and SYSTEM full, Users read) containing:

- `current.json` (latest snapshot, schema version, `runId`)
- `runs\<yyyyMMdd-HHmmss>-<runId>.json` (immutable run record: steps with Test before and after, result, duration, error, before/after values)
- `logs\<runId>.log` (transcript, plain text)
- `config\` (Office configuration.xml, FSLogix settings, plan used)
- `export\` (generated documents)

State file content (JSON, UTF-8): schema version, image name, build number and edition (`Get-ComputerInfo`/registry), PackTune version, who (user, domain, machine), start/end time, mode (dry run or real), presets and steps with state, installed software (name, id, source, version before/after), Windows Updates (KB, title, date, result), Office build and config hash, services state (Windows Update disabled), applied optimizations, cleanup done, sealed or not. No secrets, no tokens. Written atomically (write temp, rename) after every step so interrupted runs are traceable.

Versions: image "version" is an integer plus label (e.g. `2026.11-r3`), incremented per run that changed something. The diff compares the last two run records: software added/updated/removed with version change, KB added, Office build change, steps newly applied/reverted, settings changed (before/after).

Export (Section "History / Export"): from the same JSON, no hidden extra data.
- Markdown and self-contained HTML (inline CSS, no network, print-friendly) via templates. PDF: render the HTML through Edge headless `--print-to-pdf` if Edge is present (optional, no new dependency). 
- Contents: summary, image identity, change list of this version, full inventory, KB list, Office, applied optimizations with reason and source, diff to previous version, open items (e.g. "not sealed"), run log reference, integrity: SHA-256 of `current.json` printed in the document.
- Optional copy to the SharePoint library planned for Custom Applications (see question 3), done through the Intune-mode sign-in, not from the elevated GM process. v1: export folder only, manual copy; v2: "Publish" in the non-elevated main window, which picks up exported files.
- Tamper evidence: hash chain (each run record stores the hash of the previous one). Not a signature, stated as such.

## 8. UI concept (consistent with redesign)

Same shell and Theme.xaml as the redesign. Left navigation replaced by Golden Master sections; header shows a clear "Golden Master mode" badge and "Elevated" status, a "Zurueck zu Intune" action, and the current image name and version.

| Section | Content |
|---|---|
| Overview | image identity, last run, health checks (pending reboot, Windows Update service state, Office build, sealed state), "Run recommended steps" per preset, dry-run toggle |
| Software | table: detected, version, available, source; Update all, per-app Update, Install from catalog, Remove |
| Windows Updates | scan, list with KB, select, install with service toggle, history |
| Office | configuration form, preview of `configuration.xml`, install/update/remove, build info |
| Optimizations | step list with checkboxes, explanation, risk, before/after, preset chooser |
| Security | Windows Update policy, Defender, Edge, OneDrive, telemetry |
| Cleanup & Seal | cleanup steps, seal checklist, snapshot reminder, final confirmation with typed image name |
| History / Export | run list, compare two versions, export HTML/Markdown/PDF, open folder |

UX rules: every destructive or hard-to-reverse step has an explanation and a confirmation; dry-run result view shows what would change as a table; a progress panel with per-step status and a log tail; Cancel stops after the current step. All text in German and English like the rest of the tool (check how the tool localizes today; follow it).

## 9. Safety, rollback

- Snapshot advice: the tool detects a hypervisor (WMI `Win32_ComputerSystem.Model`/`Manufacturer`, Hyper-V integration services) and shows "Create a checkpoint/snapshot now" with the exact steps for Hyper-V, VMware, Azure (managed disk snapshot, Azure Compute Gallery image versions as the proper versioning). A checkbox "I created a snapshot" is recorded in the state (not enforced). If Hyper-V Integration Services is present it may offer `Checkpoint-VM` only when running remote (phase 5).
- Undo for steps that have it, based on recorded before values. Not-reversible steps (ResetBase, sysprep, AppX removal for all users) are flagged.
- Safe-by-default: dry-run first, presets show what they contain, no step runs without a visible selection, "Run all" requires typing the image name.
- Guard rails: refuse on a domain controller, refuse when not a VM unless "Allow physical machine" is ticked, refuse sysprep when the machine is domain joined and the user did not confirm, warn when running on the machine that hosts the Intune mode data (`%LOCALAPPDATA%\IntuneChocoDeployment` of an interactive admin).
- Logging: transcript plus structured per-step log in the run record, rotated, no secrets, ASCII.

## 10. Checks and tests (without touching this machine)

1. Unit-style checks `Tests\Check-GoldenMaster.ps1` in the style of existing checks (no Pester dependency): engine functions against fakes. Everything system-touching goes through thin adapter functions (`Get-Svc`, `Set-RegValue`, `Invoke-Dism`, `New-WuaSession`, `Invoke-Native`) that the checks replace with an in-memory fake (a hashtable "machine"). This tests Test/Apply/Undo logic, idempotency (run twice, second run all Unchanged), ordering, resume, diff, export rendering (golden file comparison for Markdown/HTML), and the "service restored in finally" guarantee when a fake WUA install throws.
2. Catalog check: every step has Id, Why, Risk, Source, License fields; no duplicate ids; ASCII only; presets reference existing steps.
3. WhatIf mode: `-WhatIf` runs Test only, produces the would-change table; a check asserts the fake machine is unchanged afterwards.
4. GUI smoke: extend `Invoke-GuiSmoke.ps1` with a Golden Master window using the fake engine (screenshots for docs). No UAC in the smoke (the elevation guard is a parameter in the fake path).
5. Real runs only in Windows Sandbox (`.wsb` with mapped read-only repo folder and a writable output folder) or a throwaway VM, run on Hans Brandt's (Smoke-Tester) order and bundled. Sandbox limits: no sysprep, no Windows Update of the real kind, no reboot-resume, no drivers; so those parts are verified in a disposable Hyper-V VM with a checkpoint, as a documented manual procedure, not on this machine.
6. Static analysis: PSScriptAnalyzer rules for PS 5.1 compatibility where available; repo ASCII check.

## 11. Phases and effort

| Phase | Content | Effort (dev days, rough) |
|---|---|---|
| 0 | License and URL verification, VDOT data review, schema of step contract and state file, CTO go | 1 |
| 1 | Mode switch (elevated second instance, window shell, sections, Back), engine skeleton, adapters and fakes, state/run record writer, Overview, check framework | 4 |
| 2 | Software: detection, install, update all/per app, state capture. Export v1 (Markdown/HTML) and History with diff | 4 |
| 3 | Windows Updates via WUA with service toggle and verification, security basics (WU off, policies) | 4 |
| 4 | Office via ODT (download, signature check, config form, install/update, build detection) | 3 |
| 5 | Optimizations from VDOT data, VDI components (FSLogix, Teams), Defender/Edge/OneDrive | 5 |
| 6 | Cleanup and Seal (DISM, sysprep checks, resume task), PDF export | 3 |
| 7 | Remote run via PowerShell Direct/Remoting (optional), SharePoint publish (optional) | 4 |
| Cross | docs, demo recording, sandbox/VM procedure, security review fixes | 3 |

About 25 to 30 dev days for phases 0 to 6; each phase ends with checks green, a Sicherheitspruefer pass for phases 1, 3, 4, 6, and acceptance before the next.

## 12. Risks

- Breaking a master: mitigated by dry-run default, idempotent steps, Undo where possible, snapshot advice and guard rails. Residual: AppX removal and ResetBase are not reversible.
- Windows Update service re-enabled by Windows (WaaSMedic/UsoSvc): policy plus final verification; report as warning.
- Supply chain: downloads (ODT, FSLogix, Teams) only from Microsoft-owned hosts, HTTPS, Authenticode check (publisher and chain), optional pinned hash, file saved in a protected folder (ACL admin only) before execution to avoid TOCTOU; Chocolatey community packages are third-party code running as admin, show a clear label in the Software section and prefer winget (hash verified manifests) when both exist; the catalog is the allow-list.
- Elevated GUI attack surface: the process runs elevated, so no untrusted input into commands, no loading modules/scripts from user-writable paths (the repo folder can be user-writable: on start the GM process verifies the script/module signatures or file hashes of its own files, or runs from a copy under `C:\Program Files\PackTune` / ProgramData with admin-only ACL; open question, see 13).
- State file trust: JSON is data only (no code), schema-validated on read.
- Sysprep failures and per-user Store app issues (known issue class): pre-checks and log parsing.
- Scope creep ("and much more"): the step catalog is data-driven so steps can be added without UI work; v1 limited to the list above.
- Legal: Microsoft EULAs for Office/FSLogix/Teams (no redistribution: we download from Microsoft at run time); VDOT attribution (MIT).
- PS 5.1 only: WUA COM, WPF, ODT all work; PS 7 not required.

## 13. Open questions for the user (each with recommendation)

1. Scope of v1: all sections or a first slice? Recommendation: slice by phases 1 to 4 first (mode, software, Windows Updates, Office, export), then optimizations, cleanup and seal. Fastest usable value and the riskiest parts (seal) come last.
2. Run locally on the master only, or also remote on VMs? Recommendation: local only in v1; remote in a later phase.
3. Where do state and docs go: on the master only, or also to the SharePoint library of Custom Applications? Recommendation: master (`C:\ProgramData\PackTune\GoldenMaster`) in v1, plus a manual "Publish" later through the non-elevated Intune mode.
4. Reuse VDOT data (MIT) as the base of the optimization catalog? Recommendation: yes, as re-implemented data with attribution and NOTICE; no runtime dependency.
5. Which targets for presets? Recommendation: "AVD multi-session", "Persistent VDI", "Reference image (light)", plus Citrix/Horizon notes as add-ons.
6. Seal (sysprep) inside the tool? Recommendation: yes, optional and last, with a checklist, typed confirmation and snapshot reminder; never part of "Run recommended".
7. Windows Update: exclude drivers and previews by default? Recommendation: yes; plus a KB exclude list.
8. Office default channel and config? Recommendation: Monthly Enterprise Channel, 64-bit, shared computer activation on for multi-session presets, Teams/OneDrive excluded from the ODT config, updates disabled on the master.
9. Chocolatey in the GM mode: allow or winget only? Recommendation: both, as in the catalog, Chocolatey marked as third-party, winget preferred when equivalent.
10. Elevated process integrity: run from a copy in a protected folder with hash/signature check? Recommendation: yes (copy to `C:\ProgramData\PackTune\GoldenMaster\bin` with admin-only ACL, verify before start), because the repo may sit in a user-writable path.
11. Export formats: Markdown and HTML always, PDF via Edge if present? Recommendation: yes.
12. Image versioning scheme (`YYYY.MM-rN` vs semantic) and whether to link to an Azure Compute Gallery version? Recommendation: `YYYY.MM-rN`, free text field for the gallery version, no Azure integration in v1.
13. Docs and UI language: German plus English like the rest of the tool? Recommendation: follow the tool's existing localization.
