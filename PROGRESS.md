# Project Progress: CSRST AD Group Member Retrieval

## Current State (v.2026-03-24)
- **Web App**: Node.js/Express app running on Azure App Service.
- **Jump Server (CSRMGMT02)**: PowerShell poller (`Polling-GroupRequests.ps1`) monitoring an Azure Storage Queue.
- **Worker Script**: `CSRmemberLIST-RSAT.ps1` performs AD queries and uploads CSV reports to Azure Blob Storage.
- **Deployment**: GitHub Actions (`master_csrst-ps-adm-app.yml`) triggers on push to `master`.

## Recent Improvements
1. **Heartbeat System**: Jump Server now uploads a heartbeat every minute to track status (Online/Offline) on the Web UI.
2. **Clear Selection**: Added a button to reset the selected groups in the UI.
3. **Auto-Refresh**: Reports list now refreshes every 30 seconds automatically.
4. **Reliability**: 
   - Fixed timezone issues causing "False Offline" status.
   - Silenced Azure CLI warnings/progress bars on the Jump Server.
   - Added diagnostics script (`Setup-JumpServer.ps1`) to verify the environment.

## Pending Verification
- [ ] Confirm GitHub Action completion (Commit: `5982037`).
- [ ] Verify site updates: [https://csrst-ps-adm-app-egcbevftg6fjd0fu.eastus2-01.azurewebsites.net/](https://csrst-ps-adm-app-egcbevftg6fjd0fu.eastus2-01.azurewebsites.net/)

## Strategy for Speed ("Snappiness")
- **Parallelism**: Group independent tool calls (e.g., reading multiple files or checking git status) into a single turn.
- **Targeted Reads**: Use `grep_search` and line-limited `read_file` instead of reading entire files.
- **Sub-Agents**: Use `codebase_investigator` for complex research to keep the main session context lean.
