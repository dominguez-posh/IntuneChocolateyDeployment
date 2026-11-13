# Plan: Custom Applications page

Status: plan only, no code. Security-relevant (code signing, SharePoint as package store, trust deployment to devices).
Branch: feature/custom-apps. Issue: to be opened after approval.

## 1. Goal

A new page "Custom Applications" for software that is in no catalog:

- **MSI**: fully automatic Win32 app (.intunewin) from the MSI: product code detection (with version), silent
  install and uninstall from MSI properties, no capture.
- **Other** (EXE setups, scripts, several files): the user puts all installation files into one folder; PackTune
  captures an MSIX automatically in Windows Sandbox; the app appears in the list.
- Every version is kept in a SharePoint library in the tenant, so a package can be updated or edited from any PC.
- Updates keep the same MSIX identity and publisher; each version gets its own throw-away signing certificate.

## 2. What MSIX Sandbox Studio already does (map: requirement to module)

Module: `C:\git\WindowsSandboxMSIXInstaller\MsixSandboxStudio` (v2.4.0, found by `Find-SandboxStudio`, loaded like
`Test-IntuneChocoPackage` does today). Rule: PackTune calls the module and does not copy its code. Gaps are small
changes to the module (it is the same owner's repo) or thin PackTune wrappers.

| Requirement | Existing function | Gap |
|---|---|---|
| MSI: read product code, version, name, publisher | `Get-MsixInstallerInfo` / `Get-MsiProperty` | none |
| MSI: Win32 project with MSI detection, silent scripts | `Save-Win32AppProject` + `New-Win32Detection` (type MSI product code, optional min. version) | PackTune device-script rules (see 8.3) |
| `.intunewin` build | `New-IntuneWinPackage`, `New-Win32AppPackage` (also `intune-app.json`, documentation) | none |
| MSI upload as Win32 with supersedence | `Publish-Win32AppToIntune` | PackTune already has its own Graph-token path and supersedence helpers: use PackTune's `IntuneWin32App` calls for upload so app, assignment, notes and supersedence behave like the other apps; use the module for package and test only (decide in phase 1) |
| Other: unattended capture of one installer with silent arguments | `Invoke-MsixPackaging` (Silent recipe, MSIX Packaging Tool, closes itself) | input is ONE installer file |
| Other: folder with several files plus entry point | none | **GAP A**: job input = whole folder, entry command + arguments (recipe fields `InstallerFolder`, `EntryPoint`, `Arguments`); the folder is copied to `C:\MsixStudioLocal\input` like the single installer |
| Other: no silent mode (clicks needed) | `Start-MsixRecording` (manual, needs "Start recording" click) | not automatic; PackTune offers it as "Record manually" fallback, never as the default path |
| Update: new sandbox, restore previous content, run new installer | `Start-MsixRecording -BasePackage` (restores files, registry, shortcuts; raises version) | **GAP B**: the "previous MSIX" is downloaded from SharePoint first; needs the entry point/folder from GAP A to run the updater unattended |
| Update from previous Win32 (.intunewin) | `Start-MsixRecording -BaseIntuneWin` | not needed for the plan, kept for importing existing apps later |
| Signing on host | `Invoke-MsixSigning` (signtool, SHA256, RFC 3161) | **GAP C**: uses the ONE global active certificate (`Get-MsixCertificate`, PFX plus DPAPI password file in the module workspace). Needs `-Thumbprint` signing with a non-exportable key in `CurrentUser\My`, and the packaging template needs the Publisher per call instead of "active certificate subject" |
| Certificate creation | `New-MsixCertificate` (exportable PFX + password stored) | **GAP C**: PackTune needs an ephemeral variant (no PFX, no password file) |
| Test in a second sandbox (cert trusted, network off, apps started, uninstall) | `Test-MsixPackage` | needs the version's cert as `signing.cer` instead of the global one (same gap C) |
| Documentation (clicks, files, test) | `New-MsixDocumentation` | stored in SharePoint as is |
| MSIX upload to Intune as LOB, new version of existing app | `Publish-MsixToIntune` (identity name lookup, content version, assignment) | notes marker (section 6); PackTune token via `Set-MsixIntuneSession` |
| Trusted-certificate profile | `Publish-MsixCertificateToIntune` | **GAP D**: creates `windows81TrustedRootCertificate` with store `computerCertStoreRoot`. That profile type has NO "Trusted People" store (only root and intermediate). Trusted People needs a custom profile (OMA-URI, see 7.2) |
| Win32 Test Lab, update test | `Start-Win32TestLab -BaseBuild` | used for MSI tests (optional) |

Other module facts that shape the plan: one sandbox at a time (jobs are serial), PackTune's sign-in is handed to the
module with `Set-MsixIntuneSession` (module needs `Microsoft.Graph.Authentication`), the module has no SharePoint code.

## 3. User flows

### 3.1 New MSI
1. Custom Applications > New > MSI > choose the .msi.
2. PackTune reads name, version, publisher, product code (`Get-MsixInstallerInfo`). The user can edit name,
   description, extra MSI properties (e.g. `ALLUSERS=1`, `TRANSFORMS=`), assignment, architecture.
3. Build: Win32 project, `.intunewin`, detection = product code (+ min. version).
4. Optional test in the Win32 Test Lab (install, detect, uninstall).
5. Upload to Intune with notes marker, assignment, store the version in SharePoint (7), show in the list.

### 3.2 New Other
1. New > Other > choose the folder with all installation files, the entry point (file in the folder) and the silent
   arguments. PackTune suggests arguments (`Get-MsixInstallerInfo` detects Inno, NSIS, WiX Burn, InstallShield, ...).
2. Name, version, publisher display name; identity name `PackTune.<App>` fixed, certificate subject
   `CN=PackTune <App>` fixed (section 5).
3. Sandbox job: capture, build MSIX, sign on host, test in a second sandbox (certificate trusted, no network).
4. Upload: MSIX LOB app (decision in 4), trusted-certificate profile, assignment, SharePoint copy, list entry.
5. No silent mode available: the dialog says so and offers "Record manually" (module recorder, user clicks).

### 3.3 Update (MSIX)
1. Select the app > Update version. PackTune downloads from SharePoint: previous MSIX and the installer folder of
   the last build (always kept, 7).
2. User replaces or adds files in the (local copy of the) installer folder or chooses a new installer, sets the new
   version (must be higher; PackTune proposes +1 or reads it from the installer).
3. Sandbox: restore previous content (`-BasePackage`), run the new installer or updater (entry point), build.
4. New certificate for this version, same subject, sign, test, upload as new content version of the same app,
   new cert profile with the same assignment, SharePoint folder for the new version, then clean up (5.4).
5. MSI update: new Win32 app for the new MSI, supersedence type update with PackTune's existing
   `Publish-IntuneChocoSupersedingApp` pattern; old app removed by the existing cleanup function.

### 3.4 Export on another PC
Page > select app > Export. PackTune lists versions from SharePoint, downloads the chosen version (package, installer
folder, recipe, documentation) to a folder, verifies hashes (7.3). "Edit and replace" is then flow 3.3 on that PC. The
other PC needs the same sign-in and access to the library; nothing is needed from the first PC.

### 3.5 Delete
Delete app: confirm dialog says what goes. Removes the Intune app, its certificate profiles and (after a second
confirmation, default off) the SharePoint folders of that app. Versions are kept in the SharePoint recycle bin
for the library retention. An app that other apps depend on or supersede is refused (existing check).

## 4. Decision: MSIX as LOB app, MSI as Win32

**MSIX: line-of-business app (`windowsUniversalAppX`)**, justification:
- Intune installs it machine-wide itself (provisioning). A Win32 wrapper would run `Add-AppxProvisionedPackage` as
  SYSTEM, which stages the app but registers it per user only at the next sign-in; avoiding that delay needs extra code.
- An update is a new content version of the SAME app with the same identity: devices update in place. Supersedence
  and old-app cleanup are not needed for MSIX, which removes a whole failure class.
- The module already uploads it (`Publish-MsixToIntune`, tested against stand-ins).
- Cost: no dependencies, supersedence or requirement scripts for LOB apps (not needed: the package is
  self-contained). The In-tenant list needs to read `windowsUniversalAppX` apps (small addition next to the existing
  win32LobApp listing); install status uses the same `installSummary` endpoints.
- Fallback if the spike (phase 0) shows that Available assignments of LOB MSIX update badly: Win32 wrapper.

**MSI: Win32 app**, because an MSI has no identity/publisher model, needs product-code detection and benefits from
supersedence (new product code per version), dependencies and return codes (1641, 3010, 1618).

## 5. Certificates

### 5.1 MSIX rules (what matters)
- Package identity = Name + Publisher (+ version). The Publisher string in the manifest must equal the signing
  certificate subject exactly (string compare of the DN); the family name suffix is a hash of that string.
- An update needs the same identity name, the same Publisher string and a higher version. It does NOT need the same
  certificate: the signature of the new package must chain to a certificate the device trusts.
- Therefore: subject fixed per app (`CN=PackTune <App>`, sanitized: no `,+="<>;\#`, max 64 characters, unique per
  identity name), a NEW certificate for every version.
- Several certificates with the same subject on a device are harmless: Windows validates the signer certificate of
  the package being installed, not "the certificate of the app". Each version's certificate must be trusted when that
  version is installed; the one in Trusted People matches by certificate (thumbprint), not by subject. Needs live
  confirmation in the spike (two versions, two certs, same subject, update on a test device).
- Always sign with an RFC 3161 timestamp (signature stays valid after the certificate expires). The module falls
  back to "no timestamp" when offline: PackTune refuses that fallback (fails with a message), unless the user
  explicitly allows it.

### 5.2 Handling of the key
- Per version: create the key pair in `CurrentUser\My` with `-KeyExportPolicy NonExportable`, RSA 3072, SHA256,
  EKU code signing only (1.3.6.1.5.5.7.3.3), basic constraints not a CA, validity 5 years.
- Sign with `signtool /sha1 <thumbprint>` (no PFX file, no password anywhere).
- Right after signing (also in `finally` on any error): `Remove-Item Cert:\CurrentUser\My\<thumb> -DeleteKey`. Verify
  the key is gone. Only the public `.cer` survives (stored with the version, deployed to devices).
- Consequence: a version can never be re-signed. Re-signing means a new version. This is intended.
- Needs the module change from gap C (`-Thumbprint`, per-call publisher) or a PackTune wrapper around signtool.

### 5.3 Deployment of the public certificate
- The "Trusted certificate" profile type (`windows81TrustedRootCertificate`) can only write to Root and Intermediate.
  Trusted People is the narrower and correct store for sideloaded packages (a certificate in Root would be a trust
  anchor for everything its EKU allows). So: custom profile `windows10CustomConfiguration`, OMA-URI
  `./Device/Vendor/MSFT/RootCATrustedCertificates/TrustedPeople/<THUMBPRINT>/EncodedCertificate` (RootCATrustedCertificates
  CSP, LocalMachine), value = base64 of the `.cer`. Same assignment (groups, intent) as the app. Name
  `PackTune cert - <App> <version>`; notes marker with app id and version.
- Fallback (to verify in the spike): Trusted certificate profile into Root. Wider trust, so only with the user's OK.
- Ordering: the profile and the app arrive independently. The app may be tried before the certificate. Intune retries,
  so it converges; the profile is created BEFORE the app is assigned.

### 5.4 Cleanup
- When version N+1 is rolled out: keep the profile of N and N+1. Delete profiles of N-1 and older when the install
  summary of the app shows no device on a version older than N (Graph `installSummary` of the LOB app only gives
  counts, not versions: use "all assigned devices have N+1 or failed" as the conservative rule, or a user-triggered
  "Clean up old certificates" button with a preview, default).
- Deleting a profile removes the certificate from devices; installed apps keep running (signature is checked at
  install time). A new user on a device gets the app from the staged package; this needs confirmation in the spike.
- Delete app: remove all its profiles.

## 6. Notes markers in Intune

Existing markers stay (`PoweredByChocolatey`, `PoweredByWinget`, `PackTuneRuntimeApp`, ...). New:

- MSIX LOB app: `PoweredByPackTune;kind=msix;app=<appid>;ver=<version>;manifest=<sha256 prefix>;cert=<thumb>`
- MSI Win32 app: `PoweredByPackTune;kind=msi;app=<appid>;ver=<version>;product=<guid>;manifest=<sha256 prefix>`
- Cert profile description (not notes): `PackTune;app=<appid>;ver=<version>;thumb=<thumb>`

Notes are limited (1000 characters, see Check-Schedule): all fields are short. `ConvertFrom-ChocoAppNotes` belongs to
another feature area: add a separate `ConvertFrom-PackTuneAppNotes` and make `Get-IntuneChocoTenantApps` return
`Source = Custom` rows. The In-tenant page shows them with the same status columns; update policy columns are
replaced by "Version" and "Packaged from folder". Intune is the trust anchor for the manifest hash (6.3).

## 7. SharePoint package store

### 7.1 Layout
One site (private), one document library `PackTune Packages`:

```
PackTune Packages/
  <app-id>/
    app.json                      app id, display name, kind, identity name, subject, latest version
    <version>/
      package.msix | package.intunewin     the built, signed package
      installer.zip               ALL original installer files of THIS build (always kept)
      recipe.json                 entry point, arguments, name, version, publisher, MSI properties, detection
      signing.cer                 public certificate of this version
      documentation.zip           module HTML documentation, test result, screenshots
      manifest.json               file list with SHA256 and sizes, PackTune version, creation time
```
Zip for installer folder and documentation: one upload and one hash per item, folder structure preserved, no path
problems on SharePoint (long paths, forbidden names). Files above 4 MB go through `createUploadSession`
(chunks of multiples of 320 KiB). `manifest.json` is written last; a version without manifest counts as incomplete
and is resumed or deleted by the next run.

### 7.2 Access
- Graph, delegated, scope `Sites.Selected` (read or write on one site only). `Sites.Selected` alone grants nothing:
  an admin grants the PackTune app registration access to the site once with
  `POST /sites/{id}/permissions` (role `write`, or `manage` if PackTune should create the library). That grant call
  needs `Sites.FullControl.All` (or `Sites.Manage.All`) in the SETUP sign-in of an admin only, not in daily use.
  Effective rights = what the app is granted AND what the signed-in user may do on the site.
- Daily scopes added to PackTune's app registration: `Sites.Selected` (and nothing else for SharePoint).
  Fallback if delegated `Sites.Selected` does not work as described (to verify in the spike): `Files.ReadWrite.All`
  is NOT acceptable (all of OneDrive/SharePoint); then use app-only with a certificate per tenant, which PackTune
  does not have today: not recommended.
- The site is created by the admin (private site, members = Intune administrators only; Graph cannot create a
  SharePoint site without a Microsoft 365 group). PackTune checks site and library, creates the library if missing
  and the role allows it, and otherwise shows the exact steps.
- Readiness item "Package store" (optional until Custom Applications is used).

### 7.3 Integrity
SharePoint write access = the power to replace an installer that is later built into an app for all devices. So:
- The site is restricted to the group that may manage Intune apps. The readiness item warns when the site has
  other members or sharing links (Graph `permissions` of the site and library).
- Intune holds the trust anchor: the notes of each Intune app carry a hash prefix of `manifest.json`. `manifest.json`
  lists SHA256 for every file. Before Export or Update, PackTune downloads, verifies all hashes against the manifest
  and the manifest hash against Intune; mismatch = stop with a clear message, nothing is built.
- SharePoint library versioning stays on (rollback of tampering), recycle bin as safety net.
- PackTune never executes anything from SharePoint on the admin PC except in a sandbox (the installer runs only
  inside Windows Sandbox).

## 8. Security analysis

### 8.1 Certificates and signing
- Threat: a leaked code-signing key lets anybody sign packages that devices trust. Mitigation: key non-exportable,
  never written to disk, deleted right after signing; Trusted People store (not Root) on devices; EKU code signing
  only. Residual risk: any admin PC process running as the same user can use the key in the few seconds it exists
  (accepted, same as any signing).
- Threat: trust of old certificates stays on devices forever. Mitigation: cleanup (5.4); keys no longer exist, so an
  old certificate cannot sign anything new.
- Threat: a stolen PackTune token could upload a package signed with a new certificate and deploy trust. Same as the
  existing risk of an Intune admin token; no new right is needed.

### 8.2 Sandbox and host
- Installers run only in Windows Sandbox (fresh, discarded). Packaging jobs have network (many installers
  download); the test sandbox has none. Mapped folders: job folder writable, toolchain read-only. Nothing from the
  installer runs on the host.
- The installer folder the user chooses can contain secrets (license files, keys). It goes to the SharePoint site:
  the dialog says so; the site restriction (7.3) is the control.
- Documentation screenshots can show typed secrets (module note); documentation stays optional for manual recording
  and is off by default for it.
- A malicious zip in SharePoint (path traversal): extraction refuses paths outside the target (the module's
  `Expand-IntuneWinPackage` already does this for .intunewin; same rule for `installer.zip`).

### 8.3 MSI device scripts
Module-generated install/uninstall/detect scripts run as SYSTEM. PackTune rules apply: ASCII, Windows PowerShell 5.1,
no group names (SIDs), the `Global\IntuneChocoDeployment` mutex around `msiexec` so choco and msi installs do not
collide (Windows Installer allows one at a time and returns 1618), `Write-DeviceLog` helper, no user-writable
paths. The generated scripts are checked against these rules in a test; where the module's template does not meet
them, PackTune passes its own scripts (`Save-Win32AppProject -Scripts`).

### 8.4 Graph permissions summary
Already used: DeviceManagementApps.ReadWrite.All, DeviceManagementConfiguration.ReadWrite.All (profiles),
Group.Read.All. New: `Sites.Selected` (daily), `Sites.FullControl.All` (one-time admin setup of the site grant only).

## 9. UI (consistent with the redesign)

- Nav entry "Custom" (between Apps and In tenant). Page: list of custom apps (tiles like the other lists: name,
  kind badge MSI/MSIX, version, assigned, status), filter and search; header button "New".
- Side panel for the selected app: details (identity, publisher subject, latest version, last build date,
  where the files are), buttons Update version, Export, Test in sandbox, Documentation, Delete. Status block as on
  In tenant (devices installed/failed/pending).
- "New" dialog: step 1 choice MSI or Other (two large cards). MSI: file picker, review panel. Other: folder picker,
  entry point dropdown, arguments (suggested), identity fields, "Record manually" link.
- Progress as a dialog with the existing activity log (sandbox steps: preparing, installing, capturing, building,
  signing, testing, uploading, storing). One sandbox job at a time: further jobs queue; the dialog says so.
- Dialogs for Update (version, installer changes, release notes), Export (version list, target folder), Delete
  (what goes, checkboxes), certificate cleanup (preview).
- Readiness items: Windows Sandbox available, MSIX Sandbox Studio found, Package store (site + library), certificate
  cleanup due (informational).
- The UI is wired in a later step; the backend functions come first (phase 1 to 4), so the UI developer has a clear
  contract (section 11).

## 10. Failure handling

- Every step writes to the job state (`PackTune Packages` is updated last). A failed build leaves nothing in Intune;
  a failed upload after the build keeps the package locally and can be resumed ("Retry upload").
- Order for MSIX: build, sign, test, create certificate profile, upload app (new content version), assign, store in
  SharePoint, then cleanup. If storing in SharePoint fails after the upload: the app works but the version is not
  restorable: the list shows "not stored" and Retry store is offered; update and export of that app are blocked
  until stored.
- A failed MSIX content upload leaves the app at its previous committed version (Intune commits content versions
  atomically).
- Sandbox timeouts and crashes: the job state shows the module's log folder; the sandbox is closed; the temporary
  key is deleted in `finally`. A check enforces that the key store has no leftover `PackTune` key after any failure.
- SharePoint unreachable or no permission: clear message with the step to fix; Intune work is not started when the
  store is required and not reachable (default: store is required).
- Version rules: same or lower version than the latest stored is refused for MSIX (Windows would refuse the update).

## 11. Backend contract (functions, new file `ChocoIntuneDeployment-Custom.ps1`)

`Get-CustomAppStoreState`, `Initialize-CustomAppStore`, `New-CustomMsiApp`, `New-CustomOtherApp`,
`Update-CustomApp`, `Get-CustomApps`, `Export-CustomApp`, `Remove-CustomApp`, `Test-CustomApp`,
`Remove-CustomAppOldCertificates`, plus small helpers: SharePoint (`Invoke-PackTuneStoreRequest`, upload/download with
sessions, hash manifest), `New-PackTuneVersionCertificate` (ephemeral), `New-PackTuneCertProfile`. Module calls through a
single adapter (`Invoke-SandboxStudio`) that imports the module, hands over the sign-in
(`Set-MsixIntuneSession`) and is replaceable by a fake in tests.

## 12. Checks and tests (no real tenant, no real SharePoint)

New `Tests\Check-Custom.ps1` (fake IntuneWin32App module extended for LOB apps and custom profiles; local HTTP server
as SharePoint/Graph stand-in, like the existing sign-in stand-in; fake module adapter, no sandbox):
- MSI: product code and version read from a small test MSI (built with WiX-less `msi` API or a checked-in tiny MSI),
  detection rule, notes marker, supersedence for updates.
- MSIX flow with the adapter faked: certificate created, signed, key deleted (also on failure paths), subject fixed
  across versions, publisher equals subject, publisher hash stable, version must increase.
- Cert profile: custom OMA-URI body (store TrustedPeople, thumbprint, base64), assignment copied from the app, cleanup
  rule keeps N and N+1, delete removes all.
- SharePoint: upload sessions for large files, manifest written last, hash verification (tamper test: changed byte,
  swapped installer.zip, wrong manifest hash against notes), incomplete version resumed, zip path traversal refused.
- Notes parser: all new markers, 1000-character limit.
- Device scripts of MSI apps: ASCII, parses, mutex, SIDs, no placeholders.
- Smoke test extended later for the page (phase 5).
- Spike (manual, once, documented in the issue): real tenant with test devices for the unknowns: Trusted People
  custom profile, same subject different certificates update, Available LOB update behavior, Sites.Selected delegated
  grant flow. These are not automated.

## 13. Phases and effort (one developer)

| Phase | Content | Effort |
|---|---|---|
| 0 | Spike in a test tenant: the unknowns above; decision record | 1 day |
| 1 | MSI path: adapter, `New-CustomMsiApp`, notes, upload via PackTune calls, supersedence update, list, checks | 2 days |
| 2 | Module changes (gaps A, B, C: folder input, per-call publisher, thumbprint signing, ephemeral cert) with Pester tests in the module repo | 2 days |
| 3 | SharePoint store: site/library check, upload/download with sessions, manifest and hash verification, readiness item, checks | 3 days |
| 4 | Other path: MSIX capture, signing, cert profile (custom OMA-URI), LOB upload, update, cleanup, export, delete, checks | 4 days |
| 5 | UI page (list, panel, dialogs, readiness), smoke test, README | 3 days |
| 6 | Review: security reviewer pass (certificates, SharePoint), live test with the user | 1-2 days |
Total about 16 days, phases 1 and 2 can run in parallel.

## 14. Open questions for the user (with recommendation)

1. **MSIX as LOB or Win32 wrapper?** Recommendation: LOB for MSIX (section 4), Win32 only for MSI.
2. **Certificate store on devices:** Trusted People via custom OMA-URI profile, because the Trusted certificate profile
   cannot target it. Alternative: Root store (wider trust). Recommendation: Trusted People.
3. **SharePoint access:** delegated `Sites.Selected` with a one-time admin grant on a private site. Alternative would be
   broad file scopes. Recommendation: `Sites.Selected`; who creates the site: the admin by hand (Graph cannot
   without a group), PackTune creates only the library.
4. **Who may touch the library?** Recommendation: only the Intune administrator group, PackTune warns otherwise.
5. **Timestamp server required?** Recommendation: yes, signing fails offline (the signature would die with the
   throw-away certificate); an opt-in setting allows it.
6. **Certificate validity and cleanup:** 5 years; cleanup of N-1 and older only by button with preview.
   Recommendation: button, not automatic.
7. **Delete in SharePoint:** default keep (recycle bin), checkbox to delete. Recommendation: keep.
8. **MSI apps in SharePoint too?** Recommendation: yes (MSI, recipe, `.intunewin`), same layout, so Export works for both.
9. **Does PackTune get its own copy of the module code if the module is not installed?** Recommendation: no, the page
   stays disabled with a readiness hint (module path setting exists).
10. **Updates of the module (gaps A to C):** change the module repo directly and bump its version, PackTune checks the
    minimum module version. Recommendation: yes.
