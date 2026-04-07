# CSRST AD Management App

## Overview
Web app for managing and reporting on Active Directory objects under the CSR OU (`OU=CSR,OU=NIH,OU=AD,DC=nih,DC=gov`).
Three report modes: **Group Members**, **Service Accounts**, **OU Browser** (generic AD account reports from any OU).
- **Frontend**: Single-page HTML/CSS/JS (`public/index.html`)
- **Backend**: Node.js/Express (`server.js`) on Azure App Service
- **Jump Server (CSRMGMT02)**: PowerShell poller processes queue messages and queries AD via RSAT

## Architecture Flow
1. User selects AD groups in the web UI
2. Backend sends request to Azure Storage Queue (`group-requests`)
3. Jump Server poller (`Polling-GroupRequests.ps1`) picks up the message
4. Worker script (`CSRmemberLIST-RSAT.ps1`) queries AD and uploads CSV to Azure Blob (`reports` container)
5. Web UI polls for completed reports and displays download links

## Key Files
| File | Purpose |
|------|---------|
| `server.js` | Express backend — API endpoints, Azure Storage integration |
| `public/index.html` | Main web UI (single file, includes CSS/JS) — 3 tabs |
| `Polling-GroupRequests.ps1` | Jump Server poller — monitors queue, dispatches to workers |
| `CSRmemberLIST-RSAT.ps1` | Worker: group members report |
| `Query-ServiceAccounts.ps1` | Worker: service account report with selectable properties |
| `Query-OUAccounts.ps1` | Worker: generic OU account report with selectable properties |
| `Export-GroupLists.ps1` | Exports SG/DL group lists → `config/group-lists.json` |
| `Export-ServiceAccountProperties.ps1` | Exports available properties for Service Accounts OU → `config/service-account-properties.json` |
| `Export-OUTree.ps1` | Exports full OU hierarchy under CSR root → `config/ou-tree.json` |
| `Export-OUProperties.ps1` | Samples accounts in a specific OU to find non-empty properties → `config/ou-props/{dn}.json` |
| `Setup-JumpServer.ps1` | Diagnostics script to verify Jump Server environment |
| `web.config` | IIS/Azure App Service config for Node.js |
| `Fix-NodeSSL.ps1` | Dev utility — fixes Node.js SSL errors behind NIH/HHS corporate proxy |

## Backend API Endpoints (`server.js`)
| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/health` | GET | Health check — Node version, storage client status |
| `/api/group-lists` | GET | Fetches `config/group-lists.json` from Blob |
| `/api/reports` | GET | Lists blobs in `reports` container, newest first |
| `/api/poller-status` | GET | Reads `config/poller-heartbeat.json`; Online if < 10 min old |
| `/api/download-report/:name` | GET | Proxies blob download through server (bypasses Storage firewall) |
| `/api/status/:id` | GET | Reads `status/{requestId}.json` from Blob |
| `/api/submit-groups` | POST | Enqueues group member request |
| `/api/service-account-properties` | GET | Fetches `config/service-account-properties.json` |
| `/api/submit-service-account-report` | POST | Enqueues service account report request |
| `/api/ou-tree` | GET | Fetches `config/ou-tree.json` (OU hierarchy) |
| `/api/ou-properties?dn=...` | GET | Fetches cached `config/ou-props/{dn}.json` for a specific OU |
| `/api/scan-ou-properties` | POST | Queues an `ou-property-scan` job to discover non-empty attrs |
| `/api/submit-ou-report` | POST | Queues an `ou-report` job to generate a CSV |

## Queue Message Types (all base64-encoded JSON)
| type field | Handler script |
|---|---|
| *(none / group members)* | `CSRmemberLIST-RSAT.ps1` |
| `service-account-report` | `Query-ServiceAccounts.ps1` |
| `ou-report` | `Query-OUAccounts.ps1` |
| `ou-property-scan` | `Export-OUProperties.ps1` |

## Build & Run
- **Install**: `npm install`
- **Run locally**: `npm start` (port 3000)
- **Required env var**: `AZURE_STORAGE_CONNECTION_STRING`
- **Frontend served from**: `public/` (static files via Express)
- **No build step** — plain JS, no bundler

## Deployment
- **CI/CD**: GitHub Actions (`.github/workflows/master_csrst-ps-adm-app.yml`)
- **Trigger**: Push to `master` branch or manual `workflow_dispatch`
- **Target**: Azure Web App `csrst-PS-ADM-app` (East US 2)
- **URL**: https://csrst-ps-adm-app-egcbevftg6fjd0fu.eastus2-01.azurewebsites.net/

## Azure Resources
- **Storage Queue**: `group-requests` — request pipeline
- **Blob Containers**: `reports` (CSV output), `config` (group-lists.json), `heartbeat`
- **App Service**: `csrst-PS-ADM-app`

## PowerShell Scripts
- Run on Jump Server (CSRMGMT02), not in CI
- Require RSAT (Remote Server Administration Tools) for AD queries
- Use Azure CLI (`az`) for storage operations

## Conventions
- Keep frontend as a single file in `public/index.html` (no framework)
- PowerShell scripts use `-ErrorAction Stop` for reliability
- All timestamps should use UTC/ISO 8601 format
- Test changes locally with `npm start` before pushing
- Behind NIH/HHS corporate proxy: run `Fix-NodeSSL.ps1` to set `NODE_EXTRA_CA_CERTS` if Node/Claude CLI hits SSL errors
- Heartbeat is considered Online if last check-in was < 10 minutes ago (`/api/poller-status`)
- Queue messages are base64-encoded JSON; see message types table above
- OU report filenames: `{OUShortName}-{yyyyMMdd-HHmmss}.csv`
- OU property scans cache results in `config/ou-props/` — first-time scan takes ~1 min, subsequent loads are instant
- **Branching**: Use `feature/*` branches for new work; merge to `master` via PR to trigger Azure deploy
- CSR root OU DN: `OU=CSR,OU=NIH,OU=AD,DC=nih,DC=gov`
