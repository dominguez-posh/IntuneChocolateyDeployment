# Plan: Custom Applications page

Status: approved by the user, no code yet. Security-relevant (code signing, SharePoint as package store, trust on devices).
Branch: feature/custom-apps. Issue: to be opened when work starts.

## 0. Decision log

The user approved this plan with all recommendations of the first version, with one change (3).

| # | Decision |
|---|---|
| 1 | Certificates: a new self-signed code-signing certificate per package VERSION, subject fixed per app (`CN=PackTune <App>`), key non-exportable, deleted right after signing, RFC 3161 timestamp required. |
| 2 | SharePoint: private site, library "PackTune Packages", delegated `Sites.Selected` with a one-time admin grant, the admin creates the site, PackTune creates the library. Only the Intune administrator group may change the library. MSI versions are stored too. On delete the SharePoint copy is kept by default. |
| 3 | **Change: a custom MSIX ends up as ONE Intune app.** MSIX is delivered as a Win32 app (.intunewin) containing the MSIX and the public certificate of that version. Install script: certificate into `LocalMachine\TrustedPeople`, then `Add-AppxProvisionedPackage` for all users. Detection checks the provisioned package version. Uninstall removes the package and only that version's certificate. Update = new Win32 app version with supersedence or in place, like the rest of PackTune. **No LOB app, no custom OMA-URI certificate profile, no certificate cleanup of profiles.** |
| 4 | The module (MSIX Sandbox Studio) is changed directly for the gaps; PackTune checks a minimum module version; without the module the page stays disabled. |
| 5 | Order of work: first the internal rename and the GitHub repository rename (PackTune), then Custom Applications (phase 0 spike needs a test tenant, still open), then Golden Master. |

## 1. Goal

A new page "Custom Applications" for software that is in no catalog:

- **MSI**: fully automatic Win32 app (.intunewin) from the MSI: product code detection (with version), silent
  install and uninstall from MSI properties, no capture.
- **Other** (EXE setups, scripts, several files): the user puts all installation files into one folder; PackTune
  captures an MSIX automatically in Windows Sandbox and delivers it as a Win32 app; the app appears in the list.
- Every version is kept in a SharePoint library in the tenant, so a package can be updated or edited from any PC.
- Updates keep the same MSIX identity and publisher; each version gets its own throw-away signing certificate.

## 2. What MSIX Sandbox Studio already does (map: requirement to module)

Module: `C:\git\WindowsSandboxMSIXInstaller\MsixSandboxStudio` (v2.4.0, found by `Find-SandboxStudio`, loaded like
`Test-PackTunePackage` does today). Rule: PackTune calls the module and does not copy its code. Gaps are small
changes to the module (same owner) or thin PackTune wrappers.

| Requirement | Existing function | Gap |
|---|---|---|
| MSI: read product code, version, name, publisher | `Get-MsixInstallerInfo` / `Get-MsiProperty` | none |
| MSI: Win32 project with MSI detection, silent scripts | `Save-Win32AppProject` + `New-Win32Detection` (MSI product code, optional min. version) | PackTune device-script rules (8.3) |
| `.intunewin` build | `New-IntuneWinPackage`, `New-Win32AppPackage` | none |
| Upload as Win32 with supersedence | `Publish-Win32AppToIntune` | PackTune has its own token path and supersedence helpers: upload with PackTune's `IntuneWin32App` calls so app, assignment, notes and supersedence behave like the other apps; the module is used for packaging and tests only |
| Other: unattended capture of one installer with silent arguments | `Invoke-MsixPackaging` (Silent recipe, closes itself) | input is ONE installer file |
| Other: folder with several files plus entry point | none | **GAP A**: job input = whole folder, entry command + arguments (recipe fields `InstallerFolder`, `EntryPoint`, `Arguments`), copied to `C:\MsixStudioLocal\input` |
| Other: no silent mode | `Start-MsixRecording` (manual, needs the "Start recording" click) | offered as "Record manually" fallback, never the default |
| Update: restore previous content, run new installer | `Start-MsixRecording -BasePackage` | **GAP B**: previous MSIX comes from SharePoint; needs A to run the updater unattended |
| Signing on host | `Invoke-MsixSigning` | **GAP C**: uses the ONE global active certificate (PFX + DPAPI password file). Needs signing with `-Thumbprint` of a non-exportable key in `CurrentUser\My` and the Publisher per call (packaging template) instead of "active certificate subject" |
| Certificate creation | `New-MsixCertificate` (exportable PFX + stored password) | **GAP C**: ephemeral variant (no PFX, no password file) |
| Test in a second sandbox (cert trusted, no network, apps started, uninstall) | `Test-MsixPackage` | version's certificate as `signing.cer` instead of the global one (gap C). The test must additionally run the generated Win32 `install.ps1` as SYSTEM (new, see 4.3) |
| Documentation | `New-MsixDocumentation` | stored in SharePoint as is |
| Win32 Test Lab, update test | `Start-Win32TestLab -BaseBuild` | used for the MSI app and for the MSIX Win32 wrapper (install, detect, uninstall, update from previous build) |
| ~~MSIX LOB upload~~, ~~Trusted-certificate profile~~ | `Publish-MsixToIntune`, `Publish-MsixCertificateToIntune` | **not used any more** (decision 3) |

Other module facts: one sandbox at a time (jobs are serial); PackTune's sign-in is handed to the module with
`Set-MsixIntuneSession` where needed; the module has no SharePoint code.

## 3. User flows

### 3.1 New MSI
1. Custom Applications > New > MSI > choose the .msi.
2. PackTune reads name, version, publisher, product code (`Get-MsixInstallerInfo`). The user can edit name,
   description, extra MSI properties (`ALLUSERS=1`, `TRANSFORMS=`), assignment, architecture.
3. Build: Win32 project, `.intunewin`, detection = product code (+ min. version).
4. Optional test in the Win32 Test Lab.
5. Upload, notes marker, assignment, store the version in SharePoint, list entry.

### 3.2 New Other
1. New > Other > folder with all installation files, entry point (file in the folder), silent arguments (suggested by
   `Get-MsixInstallerInfo`: Inno, NSIS, WiX Burn, InstallShield, ...).
2. Name, version, publisher display name; identity name `PackTune.<App>` and subject `CN=PackTune <App>` are fixed (5).
3. Sandbox: capture, build MSIX, sign on host, test in a second sandbox.
4. Wrap: Win32 app with the MSIX, the public certificate and the generated scripts (4.3); test the wrapper
   (install as SYSTEM, detect, uninstall) in a sandbox.
5. Upload as ONE Win32 app, assignment, SharePoint copy, list entry.
6. No silent mode available: the dialog says so and offers "Record manually" (module recorder, the user clicks).

### 3.3 Update
1. Select the app > Update version. PackTune downloads from SharePoint: previous MSIX and the installer folder of the
   last build (always kept).
2. The user changes files in the local copy of the installer folder or chooses a new installer, sets a higher
   version (proposed +1).
3. MSIX: sandbox restores the previous content (`-BasePackage`), runs the new installer, builds; new certificate,
   same subject, sign, wrap, test.
4. New Win32 app version: assigned like the old one; the old app is superseded (type update) when it is Available
   only, or updated in place when Required: the existing `Publish-PackTuneRelease` decides (needs the notes marker
   of the custom app, see 6). The old app is removed by the existing cleanup when no device has it any more.
5. SharePoint folder for the new version.
6. MSI: same, with the new MSI.

### 3.4 Export on another PC
Select app > Export. PackTune lists the versions from SharePoint, downloads the chosen one (package, installer folder,
recipe, documentation), verifies the hashes (7.3). "Edit and replace" is flow 3.3 on that PC. Nothing is needed from
the first PC.

### 3.5 Delete
Confirm dialog says what goes: the Intune app (existing removal checks apply: dependencies, supersedence) and,
after a second confirmation (default off), the SharePoint folders of the app. Devices keep the installed software
(as with the other apps); uninstall assignments are a separate action the user can take first.

## 4. Decision: MSIX delivered as a Win32 app

One custom MSIX = ONE Intune app (decision 3). The Win32 app contains the signed MSIX and the public `.cer` of that
version. Win32 gives the rest of PackTune for free: supersedence and in-place release, install status, In tenant list,
return codes, detection, test lab. MSI stays a Win32 app as well.

### 4.1 Install script (SYSTEM, PowerShell 5.1, ASCII)
Same rules as the other device scripts: relaunch in 64-bit, `$ToolRoot` = `%ProgramFiles%\PackTune`,
protected folders (`Protect-Folder`, SIDs), `Global\PackTune` mutex around the install, `Write-DeviceLog`.
Steps:
1. Work folder `%ProgramFiles%\PackTune\Custom\<app id>` protected; copy `package.msix` and `signing.cer`
   there from the package folder (the Intune cache folder is user-readable but not writable).
2. Check the MSIX signature on the device against the shipped `.cer` (`Get-AuthenticodeSignature`: signer thumbprint
   equals the thumbprint of `signing.cer`, status valid or only "untrusted root" before the next step). Refuse
   otherwise (tamper check for the package in the cache).
3. Import `signing.cer` into `LocalMachine\TrustedPeople`.
4. `Add-AppxProvisionedPackage -Online -PackagePath <msix> -SkipLicense` (all users; existing users get it at the next
   sign-in, see spike). If the same identity is already provisioned in a lower version: `Add-AppxProvisionedPackage`
   with the new package replaces it (identity and Publisher equal).
5. Marker `<AppRoot>\version.txt` (identity, version, certificate thumbprint) for detection and uninstall.
6. Failure: leave no half state (certificate added in this run is removed again when provisioning fails), log, exit code.

### 4.2 Detection
Script: `Get-AppxProvisionedPackage -Online` has `PackageName` for the identity and version >= the app version
(equal for pinned). Optionally AND the marker file. Exit 0 only then. No time dependency.

### 4.3 Uninstall
- `Remove-AppxProvisionedPackage -Online -PackageName <full name>` and `Remove-AppxPackage -AllUsers` for the identity.
- Certificate: remove ONLY the certificate of that version (thumbprint from `version.txt`), and only if no other
  installed package of this tool still needs it: `Get-AppxPackage -AllUsers` signature thumbprints of packages whose
  identity name starts with `PackTune.`; other versions of the same app hold other thumbprints, other apps have other
  subjects. A certificate that is still referenced stays.
- Update path: the new version's install does NOT remove the old certificate (the old package may still be
  installed until provisioning replaced it); the new install removes certificates of the same subject that no
  provisioned or installed package references any more (device-side cleanup, replaces the profile cleanup).

### 4.4 Build and test
- Wrapper build uses the module's Win32 project/`New-IntuneWinPackage` with PackTune's scripts (`-Scripts`).
- Test (module sandbox): fresh sandbox without the certificate, run `install.ps1` as SYSTEM through the scheduled-task
  runner of the Win32 Test Lab, detect, start the app, update from the previous build (`-BaseBuild`), uninstall, detect,
  check that the certificate is gone.

## 5. Certificates

### 5.1 MSIX rules (what matters)
- Package identity = Name + Publisher (+ version). The Publisher string in the manifest must equal the signing
  certificate subject exactly; the family name suffix is a hash of that string.
- An update needs the same identity name, the same Publisher string and a higher version. It does not need the same
  certificate: the new package's signature must chain to a certificate the device trusts.
- Hence: subject fixed per app (`CN=PackTune <App>`, sanitized: no `,+="<>;\#`, max 64 characters, unique per identity
  name), a NEW certificate per version.
- Several certificates with the same subject in `TrustedPeople` are harmless: the check is on the signer
  certificate of the package being installed, and Trusted People matches the certificate itself, not the subject.
  (Spike: install version 2 signed with a new certificate of the same subject over version 1.)
- Always sign with an RFC 3161 timestamp. The module falls back to "no timestamp" when offline: PackTune refuses that
  (the signature would end with the throw-away certificate) unless the user allows it in settings.

### 5.2 Key handling
- Per version the key pair is created in `CurrentUser\My`, `-KeyExportPolicy NonExportable`, RSA 3072, SHA256, EKU
  code signing only, not a CA, validity 5 years.
- Sign with `signtool /sha1 <thumbprint>`: no PFX file, no password anywhere.
- Right after signing, also in `finally` on any error: `Remove-Item Cert:\CurrentUser\My\<thumb> -DeleteKey`, then
  verify the key is gone. Only the public `.cer` survives (inside the Win32 package and in SharePoint).
- A version can never be re-signed; re-signing = new version. Intended.

### 5.3 Deployment of the public certificate
The certificate travels INSIDE the Win32 package and is imported by the install script (4.1). There is no separate
Intune certificate profile, no OMA-URI, no ordering problem between profile and app, and the certificate never reaches a
device that does not install the app. Store: `LocalMachine\TrustedPeople` (not Root: a certificate in Root is a trust
anchor for everything its EKU allows).

### 5.4 Cleanup
Device side only, by the scripts (4.3). Nothing to clean up in the tenant.

## 6. Notes markers in Intune

Existing markers stay. New:

- MSIX wrapper app: `PoweredByPackTune;kind=msix;app=<appid>;ver=<version>;identity=<name>;thumb=<thumb>;manifest=<sha256 prefix>`
- MSI app: `PoweredByPackTune;kind=msi;app=<appid>;ver=<version>;product=<guid>;manifest=<sha256 prefix>`

Notes are limited to 1000 characters (see Check-Schedule); all fields are short. `ConvertFrom-PackTuneAppNotes` belongs to
another feature area: add `ConvertFrom-PackTuneAppNotes`; `Get-PackTuneTenantApps` returns `Source = Custom` rows;
`Get-PackTuneReleasePath` and the supersedence release path accept them (they read package and version from the
notes and rebuild with the custom builder instead of the choco/winget script builder). In tenant shows them with the same
status columns (update policy columns replaced by version and "packaged from folder"). Intune is the trust anchor for
the manifest hash (7.3).

## 7. SharePoint package store

### 7.1 Layout
One private site, one document library `PackTune Packages`:

```
PackTune Packages/
  <app-id>/
    app.json                      app id, display name, kind, identity name, subject, latest version
    <version>/
      package.intunewin           the built Win32 package (MSI or MSIX wrapper)
      package.msix                MSIX only: the signed MSIX
      installer.zip               ALL original installer files of THIS build (always kept)
      recipe.json                 entry point, arguments, name, version, publisher, MSI properties, detection
      signing.cer                 MSIX only: public certificate of this version
      documentation.zip           module HTML documentation, test result, screenshots
      manifest.json               file list with SHA256 and sizes, PackTune version, creation time
```
One zip for the installer folder and for the documentation: one upload and one hash each, folder structure preserved,
no problems with long paths or forbidden SharePoint names. Files above 4 MB use `createUploadSession` (chunks of
multiples of 320 KiB). `manifest.json` is written last; a version without it is incomplete and resumed or deleted by
the next run.

### 7.2 Access
- Graph, delegated, scope `Sites.Selected`. It grants nothing alone: an admin grants the PackTune app registration
  access to the one site with `POST /sites/{id}/permissions` (role `write`; `manage` if PackTune should create the
  library). That call needs `Sites.FullControl.All` in the SETUP sign-in of an admin only. Effective rights = app grant
  AND the signed-in user's rights on the site.
- Daily scopes: `Sites.Selected` only. `Files.ReadWrite.All` is not acceptable (all SharePoint and OneDrive).
- The admin creates the site (Graph cannot create one without a Microsoft 365 group); PackTune checks site and library,
  creates the library when allowed, otherwise shows the exact steps.
- Readiness item "Package store" (needed once Custom Applications is used).

### 7.3 Integrity
SharePoint write access is the power to replace an installer that becomes an app for all devices:
- The site is restricted to the group that manages Intune apps; readiness warns about other members or sharing links.
- Intune holds the trust anchor: the notes carry a hash prefix of `manifest.json`; the manifest lists SHA256 of every
  file. Before Export or Update PackTune verifies all hashes and the manifest against Intune. Mismatch = stop, nothing
  is built.
- Library versioning on (rollback), recycle bin as safety net.
- Installers run only inside Windows Sandbox, never on the admin PC.

## 8. Security analysis

### 8.1 Certificates and signing
- Leaked code-signing key = packages devices trust. Mitigation: non-exportable, never on disk, deleted right after
  signing, Trusted People (not Root), EKU code signing only, per-version certificates. Residual: a process of the same
  user could use the key during the few seconds it exists (accepted).
- Old certificates on devices: their keys no longer exist, so they cannot sign anything new; the device scripts remove
  unreferenced certificates of the subject (4.3).
- The install script trusts the shipped `.cer` for that package only because Intune delivered the package; a changed
  package in the cache fails the signature-thumbprint check (4.1 step 2). A stolen admin token could upload a package
  with a new certificate: the same risk as any Intune admin token, no new right.

### 8.2 Sandbox and host
- Installers run in Windows Sandbox only (fresh, discarded). Packaging jobs have network (many installers download),
  test sandboxes none. Mapped folders: job folder writable, toolchain read-only. Nothing from the installer runs on the
  host.
- The installer folder can hold secrets (license files, keys) and goes to the SharePoint site: the dialog says so, the
  site restriction is the control.
- Documentation screenshots can show typed secrets (module note); documentation is off by default for manual recording.
- Zip path traversal: extraction refuses paths outside the target (`Expand-IntuneWinPackage` does this; same rule for
  `installer.zip`).

### 8.3 Device scripts
MSI and MSIX scripts run as SYSTEM: ASCII, Windows PowerShell 5.1, SIDs instead of names, `Global\PackTune`
mutex around `msiexec` and the provisioning (Windows Installer allows one install at a time, 1618), `Write-DeviceLog`,
folders under `%ProgramFiles%\PackTune` only, no user-writable paths, `DeviceScriptRevision` raised where
shared text changes. Tests parse and check them. Where the module's templates do not meet this, PackTune passes its own
scripts (`Save-Win32AppProject -Scripts`).

### 8.4 Graph permissions
Used: DeviceManagementApps.ReadWrite.All, DeviceManagementConfiguration.ReadWrite.All (already granted),
Group.Read.All. New: `Sites.Selected` (daily), `Sites.FullControl.All` (one-time admin site grant only).
`DeviceManagementConfiguration.ReadWrite.All` is not needed for custom apps (no profiles).

## 9. UI (consistent with the redesign)

- Nav entry "Custom" (between Apps and In tenant). Page: list of custom apps (tiles: name, kind badge MSI/MSIX,
  version, assigned, status), filter and search; header button "New".
- Side panel for the selected app: details (identity, publisher subject, latest version, build date, where the files
  are), buttons Update version, Export, Test in sandbox, Documentation, Delete; status block as on In tenant.
- "New" dialog: step 1 choice MSI or Other (two large cards). MSI: file picker, review. Other: folder picker, entry
  point, arguments (suggested), identity fields, "Record manually" link.
- Progress dialog with the activity log (preparing, installing, capturing, building, signing, wrapping, testing,
  uploading, storing); one sandbox job at a time, further jobs queue.
- Dialogs for Update, Export (version list, target folder), Delete (what goes, checkboxes).
- Readiness: Windows Sandbox available, MSIX Sandbox Studio found (minimum version), Package store.
- Wired in phase 5 after the backend functions (section 11).

## 10. Failure handling

- Every step writes a job state; the SharePoint copy and the list entry come last. A failed build leaves nothing in
  Intune; a failed upload keeps the package locally ("Retry upload").
- Order for MSIX: build, sign, wrap, test, upload app, assign, store in SharePoint. If storing fails after the upload,
  the app works but the version is not restorable: the list shows "not stored", Retry store is offered, update and
  export of that app are blocked until stored (default: the store is required, so a missing store stops BEFORE the
  upload).
- On devices: failed provisioning removes a certificate added in that run; the script exits non-zero so Intune reports
  and retries.
- Sandbox timeout or crash: the module log folder is kept, the sandbox is closed, the temporary key is deleted in
  `finally`; a check enforces that no PackTune key stays in the key store after any failure path.
- Version rules: not higher than the latest stored version = refused (Windows would refuse the update).

## 11. Backend contract (new file `PackTune-Custom.ps1`)

`Get-CustomAppStoreState`, `Initialize-CustomAppStore`, `New-CustomMsiApp`, `New-CustomOtherApp`, `Update-CustomApp`,
`Get-CustomApps`, `Export-CustomApp`, `Remove-CustomApp`, `Test-CustomApp`; helpers for SharePoint
(`Invoke-PackTuneStoreRequest`, upload/download with sessions, hash manifest), `New-PackTuneVersionCertificate`
(ephemeral), `Get-CustomMsixScripts` (install, uninstall, detection). Module calls through one adapter
(`Invoke-SandboxStudio`) that imports the module and hands over the sign-in; a fake adapter for tests.

## 12. Checks and tests (no real tenant, no real SharePoint)

New `Tests\Check-Custom.ps1` (fake IntuneWin32App module, a local HTTP server as SharePoint/Graph stand-in like the
existing sign-in stand-in, fake module adapter, no sandbox):
- MSI: product code and version from a small test MSI, detection rule, notes marker, supersedence on update.
- MSIX flow with the adapter faked: certificate created, signed, key deleted (also on every failure path), subject
  fixed across versions, publisher equals subject, version must increase, timestamp required.
- MSIX scripts: parse, ASCII, mutex, SIDs, protected folders under `%ProgramFiles%`, no placeholders; install order
  (signature check, certificate, provisioning, marker), certificate rollback on failure, uninstall removes only the
  version's certificate and keeps one that another package references (script logic tested against injectable store
  functions), detection uses the provisioned version.
- Release: custom apps take the supersedence path when Available only and in place when Required.
- SharePoint: upload sessions, manifest written last, hash verification (tamper tests: changed byte, swapped zip,
  wrong manifest hash against notes), incomplete version resumed, zip path traversal refused.
- Notes parser: new markers, 1000-character limit.
- Spike (manual, documented in the issue): see 13, phase 0.

## 13. Phases and effort

Prerequisite order (decision 5): internal rename and GitHub repository rename first; then this feature; then Golden Master.

| Phase | Content | Effort |
|---|---|---|
| 0 | Spike in a test tenant with test devices (below), decision record | 1 day |
| 1 | MSI path: adapter, `New-CustomMsiApp`, notes, upload via PackTune calls, supersedence update, list, checks | 2 days |
| 2 | Module changes (gaps A, B, C) with Pester tests in the module repo | 2 days |
| 3 | SharePoint store: site and library check, upload/download with sessions, manifest and hash verification, readiness item, checks | 3 days |
| 4 | Other path: capture, signing, MSIX Win32 wrapper (scripts, test), update, export, delete, checks | 4 days |
| 5 | UI page (list, panel, dialogs, readiness), smoke test, README | 3 days |
| 6 | Review: security reviewer pass (certificates, SharePoint, device scripts), live test with the user | 1-2 days |
Total about 16 days; phases 1 and 2 can run in parallel. The test tenant for phase 0 is still open.

### Phase 0 spike list (manual, needs a test tenant)
1. MSIX provisioning as SYSTEM from a Win32 app: certificate imported into `LocalMachine\TrustedPeople` by
   `install.ps1`, then `Add-AppxProvisionedPackage -Online`; does the app appear for the signed-in user without a
   sign-out, and for a new user? Does the Intune Management Extension (32-bit host, relaunch as 64-bit) handle it?
2. Update with a NEW certificate of the same subject: version 2 signed with certificate B over version 1 (certificate A
   in Trusted People): accepted? Both certificates present; then A removed by the script: version 1 still runs, repair
   and new-user registration still work?
3. Detection with `Get-AppxProvisionedPackage -Online` right after install and after the update (version compare,
   architecture in the full package name).
4. Supersedence of the Win32 wrapper (Available, update) and in-place update (Required) for an MSIX wrapper app.
5. Uninstall: package removed for all users, only that version's certificate removed, a certificate still used by
   another package kept.
6. `Sites.Selected` delegated: admin grant flow with `Sites.FullControl.All`, then daily use with the app registration;
   library creation with role `write` vs `manage`; upload session of a large file.

## 14. Open questions

All questions of the first version were answered (decision log). Still open:

1. Test tenant and test devices for phase 0: who provides them, which Windows builds (10 and 11)?
2. Start date: after the internal rename and the GitHub repository rename are done.
3. Name of the SharePoint site and who is its owner group (default proposal: site "PackTune", owners = Intune administrators).
