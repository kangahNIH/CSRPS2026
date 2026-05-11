# CSRST AD Management App — Changelog

Web application for managing and reporting on Active Directory objects under the CSR OU (`OU=CSR,OU=NIH,OU=AD,DC=nih,DC=gov`). Hosted on Azure App Service, backed by an Azure Storage Queue and a PowerShell poller on the Jump Server (CSRMGMT02).

URL: https://csrst-ps-adm-app-egcbevftg6fjd0fu.eastus2-01.azurewebsites.net/

---

## Feature Overview

| Area | Capability |
|------|-----------|
| **Group Members report** | Select one or more AD groups (SG/DL) and export per-group CSVs of all members, sorted by Last Name, with email and group-type identification. |
| **Service Accounts report** | Pick from auto-discovered AD properties for the Service Accounts OU and export a CSV. |
| **OU Browser** | Browse the full OU hierarchy under CSR, scan any OU for populated properties on-demand, and generate a CSV of objects in that OU (users, computers, groups, contacts, MSAs — nested OUs excluded). |
| **Reports list** | Auto-refreshing list of completed CSVs from blob storage, newest first. |
| **Server-proxied downloads** | Downloads stream through `server.js` so end users don't need direct storage firewall access. |
| **Async job pipeline** | UI → Azure Queue → Jump Server PowerShell worker → Blob upload → UI polls `/api/status/:id` for live progress. |
| **Poller heartbeat** | Jump Server writes `config/poller-heartbeat.json` every minute. UI shows Online if last check-in was <10 min. |
| **Auto-script-sync** | Jump Server poller downloads updated `.ps1` files from `scripts` blob container every 10 minutes — no manual deploy needed. |
| **OU property cache** | First scan of an OU takes ~1 min; results cached in `config/ou-props/` for instant subsequent loads. |
| **Diagnostics** | `Setup-JumpServer.ps1` and `Fix-NodeSSL.ps1` for environment troubleshooting (RSAT, NIH/HHS corporate proxy SSL). |

---

## Change Log

### 2026-05-11 — OU Browser: scan all object types
- **Fix**: `Query-OUAccounts.ps1` and `Export-OUProperties.ps1` now use `Get-ADObject` instead of `Get-ADUser`. Previously, reports for OUs that didn't contain user accounts (e.g., computers, groups, MSAs, contacts) returned zero results.
- Nested organizational units are excluded via LDAP filter `(!(objectClass=organizationalUnit))`.
- `ObjectClass` is now always included as a column so each row shows what type it is.
- Property discovery uses `Get-ADObject -Properties *` and dynamically discovers populated LDAP attributes — works for mixed-type OUs.
- Excludes noisy/internal attrs (`nTSecurityDescriptor`, etc.) from the discoverable property list.
- Deployment: PS1 files uploaded directly to `scripts` blob container; Jump Server picks them up on next 10-min sync.

### 2026-05-11 — OU Browser: faster scans, object-class breakdown, empty-OU clarity
- **Fix**: First-time scans on Server2016 / Server2019 were leaving the property picker blank for an extended period. Replaced `Get-ADObject -Properties *` (which fetched every attribute including security descriptors) with a curated candidate list and added `-ResultSetSize $SampleSize` for server-side limiting. Scans now finish noticeably faster.
- **New**: The selected-OU info banner now shows an object-class breakdown of the sample (e.g., "30 object(s) (subtree): 26 computer, 4 user"). Makes it obvious what kind of objects a parent OU like `Servers` actually contains.
- **New**: When an OU contains zero eligible objects, the picker now shows a clear red message explaining that nested sub-OUs and AD plumbing (DFSR, SCPs, etc.) are excluded by design, and the Generate Report button is disabled. No more silently empty UI.
- **New**: Hint under "Select Attributes to Include" explains that reports cover the selected OU **and all sub-OUs recursively**. Picking a parent like `Servers` includes every descendant.
- Property scan result JSON now includes `objectClassCounts`, `isEmpty`, and `searchScope` fields.
- Friendly synthetic property names (`Enabled`, `PasswordLastSet`, `LastLogonDate`, `EmailAddress`, `AccountExpirationDate`, etc.) are auto-added to the picker when the underlying LDAP attribute is populated in the sample. `Query-OUAccounts.ps1`'s existing translation layer turns them into readable column values at report time.

### 2026-05-11 — OU report: hide AD infrastructure objects
- **Fix**: Reports for OUs like `Servers 2022` were including ~89 rows instead of the 46 real computer objects shown in Active Directory Users and Computers. The extra rows came from infrastructure objects that ADUC hides by default — DFSR replication metadata (`msDFSR-Subscription`, `msDFSR-Subscriber`, `msDFSR-LocalSettings`), Service Connection Points that Windows VMs auto-register (`serviceConnectionPoint`), legacy FRS objects, internal `CN=` containers, etc.
- Both `Query-OUAccounts.ps1` and `Export-OUProperties.ps1` now apply an LDAP exclusion filter for these well-known plumbing classes. Result matches what users actually see in ADUC.
- Generic filter — works for every OU, not just Servers. A Users OU still shows users; a Groups OU still shows groups; nobody sees DFSR/SCP/FRS noise anymore.

### 2026-05-11 — OU tree UX: visual hierarchy + sticky selection
- The OU Browser tree now shows folder icons (📁 closed / 📂 open / 📄 leaf), dashed vertical connector lines between parent and children, and a thicker left-bar accent on the selected row — so the hierarchy is obvious at a glance.
- **Sticky selection**: selecting a deeply-nested OU no longer collapses its ancestors. Expand state is tracked in a JS `Set` that survives every re-render; `selectOU` adds every ancestor DN to that set before redrawing.
- **Centered scroll**: after selection, the selected row is scrolled to the vertical center of the OU tree pane (the surrounding page does not move).
- Toggle arrow and folder icon are now independent click targets for expand/collapse; clicking the node name selects the OU.
- Long OU names truncate with an ellipsis (full DN shown on hover via `title`).

### 2026-05-11 — In-app "What's New" changelog
- Added `What's New` button in the header (next to the version tag) that opens a modal displaying this changelog.
- New backend endpoint: `GET /api/changelog` — serves `CHANGELOG.md` as raw markdown.
- Frontend renders the markdown client-side via `marked@12` loaded from jsDelivr CDN. Falls back to plain `<pre>` if the CDN is blocked.
- End users can now read the change log without leaving the app or browsing the repo.

### 2026-05-11 — OU Browser: friendly property name compatibility (patch)
- **Fix**: First report against the WVD OU after the previous patch failed with `AD query error: One or more properties are invalid. Parameter name: PasswordLastSet`. Root cause: stale cached property lists (`config/ou-props/*.json`) still listed user-friendly names like `Enabled`, `PasswordLastSet`, `LastLogonDate`, `EmailAddress` that are computed by `Get-ADUser` but unknown to `Get-ADObject`.
- `Query-OUAccounts.ps1` now maintains a `$friendlyAttrMap` that translates friendly property names → underlying LDAP attribute(s) at query time, and a `Get-FriendlyValue` helper that derives the friendly value from raw LDAP fields when building each row.
- Mappings handled: `Enabled`, `PasswordNeverExpires`, `PasswordNotRequired`, `SmartcardLogonRequired` (decoded from `userAccountControl` bits); `PasswordLastSet`, `LastLogonDate`, `AccountExpirationDate` (converted from FileTime); `LockedOut` (derived from `lockoutTime`); `EmailAddress`/`OfficePhone`/`MobilePhone`/`HomePage`/`Surname`/`GivenName`/`Office`/`Country`/`BadLogonCount`/`ServicePrincipalNames` (aliased to their LDAP names).
- Stale cached property lists now keep working — no need to re-scan OUs first.

### 2026-04-06 — OU Browser (initial release)
- New `OU Browser` tab in the web UI (`public/index.html`).
- Frontend fetches OU tree via `/api/ou-tree`, properties via `/api/ou-properties?dn=...`, and queues reports via `/api/submit-ou-report`.
- New worker scripts on Jump Server: `Query-OUAccounts.ps1` (report) and `Export-OUProperties.ps1` (property discovery).
- New queue message types: `ou-report` and `ou-property-scan`.
- `Export-OUTree.ps1` exports the full CSR-rooted OU hierarchy to `config/ou-tree.json` on Jump Server startup and daily.
- CLAUDE.md updated to document the expanded API surface.
- **Fix**: Removed the `upload-scripts` GitHub Actions job — storage firewall blocks GitHub runner IPs. Scripts are now uploaded out-of-band (manual upload to `scripts` container).

### 2026-04-03 — Service Account reporting + auto-sync
- New `Service Accounts` tab — users pick from auto-discovered AD properties and export CSVs.
- `Export-ServiceAccountProperties.ps1` exports populated properties to `config/service-account-properties.json` on Jump Server startup and daily.
- `Query-ServiceAccounts.ps1` worker handles `service-account-report` queue messages.
- Jump Server poller now **auto-syncs** `.ps1` files from the `scripts` blob container every 10 minutes — eliminates manual script deploys.
- GitHub Actions workflow simplified: dropped the `azure/login` action and uses `az` CLI directly with the publish profile secret.

### 2026-03-25 to 2026-03-26 — Reliability & UX polish
- **Fix**: Standardized all timestamps to UTC ISO 8601 — resolved timezone mismatch between Jump Server and App Service (`8eedd41`).
- **Fix**: BOM-free UTF8 JSON output from PowerShell — prevented 500 errors when parsing status blobs (`269c67d`, earlier `c3c30aa`).
- **Fix**: Improved heartbeat reliability and added `Setup-JumpServer.ps1` diagnostics script (`1f77868`).
- Silenced noisy Azure CLI warnings/progress on Jump Server (`9c26416`).
- UI: Added Clear Selection button and auto-refresh of the reports list (`2c954e7`).

### 2026-03-24 — Jump Server heartbeat
- Jump Server poller writes `config/poller-heartbeat.json` to blob each minute.
- New `/api/poller-status` endpoint reports Online/Offline based on a 10-minute threshold.
- UI shows live poller status indicator.

### 2026-03-16 to 2026-03-18 — Group Members hardening
- Switched to **per-group CSVs** with SG/DL naming convention and group-type identification (`93c0d2a`, `8ab6a69`, `b3a6061`).
- Background exporter and searchable group-list pickers in the UI (`dc70e1c`).
- **Fix**: Numbering correctly increments across rows (`35e15d6`).
- **Fix**: Robust AD group lookup using `-Filter` with Name/SamAccountName/DistinguishedName and explicit `-Server` (`e05141c`, `5879037`).
- Status history persisted in the UI so messages aren't lost between polls (`0dac82d`, `7c455dd`).
- Sort by Last Name; improved email reliability (`cd37179`).
- UI warning about expected processing delay shown on submit (`263d01c`).

### 2026-03-09 to 2026-03-10 — Error visibility & deployability
- Surface actual Azure error messages in API responses and the frontend (`2abafc2`, `d8bfc61`).
- Detailed error logging for queue submission (`fd2c89d`).
- Robust status JSON parsing including encoding edge cases (`15b646d`).
- Startup logging + environment check at boot (`4f0b466`).
- Include `node_modules` in deployment artifact for Windows App Service (`45501a3`).
- **New endpoint**: `/api/download-report/:name` proxies blob downloads through the server so end users bypass the storage firewall (`17cb67e`).

---

## Deployment notes

- **Web app**: Auto-deploys on push to `master` via `.github/workflows/master_csrst-ps-adm-app.yml`.
- **PowerShell scripts**: Not deployed by CI (storage firewall blocks GitHub runners). Upload to the `scripts` blob container manually or from a whitelisted IP; the Jump Server syncs every 10 min.
- **Storage firewall**: `defaultAction: Deny` with an explicit IP allowlist. Adding/removing temporary IPs requires `Storage Account Contributor` rights.
- **Required env var**: `AZURE_STORAGE_CONNECTION_STRING` (App Service + Jump Server).
