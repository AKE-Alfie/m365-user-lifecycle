# M365 User Lifecycle

PowerShell automation for the two jobs every IT team and MSP does each week: **onboarding new hires** and **offboarding leavers** in Entra ID / Microsoft 365. Built on **Microsoft Graph** and **Exchange Online**. Every change supports **`-WhatIf`**, and every action is written to a **CSV audit log**.

## The problem

Manual joiner/leaver work in the admin centers takes time and steps get missed: a licence left on a leaver, sessions not revoked, a mailbox deleted before anyone saved the mail, or a new hire who starts without the right groups. Clients and auditors also want proof of what was done.

## Features

### Onboarding (`Start-EntraOnboarding.ps1`)
- Create users in bulk from **CSV or JSON**
- **Role templates** (JSON): licences, groups/Teams/DLs, department, job title, shared mailboxes per role
- Unique UPNs (`first.last@`, then `first.last2@` on collision), accents removed (`José Núñez` becomes `jose.nunez`)
- Cryptographically random temporary password, change forced at first sign-in. Returned only as a `SecureString` and **never written to logs or files**
- Sets manager and hire date, checks **licence seat availability** before assigning
- Waits for the mailbox to provision, then sets **language and time zone** and grants **FullAccess + SendAs** on the role's shared mailboxes
- Writes a **welcome sheet** (HTML) per hire with sign-in steps and the access granted

### Offboarding (`Start-EntraOffboarding.ps1`)
- Block sign-in and **revoke all sessions**
- **Auto-reply** with templated text (`{DisplayName}`, `{ManagerName}`, `{ManagerEmail}`)
- **Convert the mailbox to shared** and give the **manager FullAccess**, *before* licences are removed so no mail is lost
- Hide from the GAL
- Remove **group memberships** (cloud groups via Graph, DLs via Exchange). Skips dynamic groups, on-prem-synced groups and an exclusion list
- Remove **directly assigned licences**. Group-based licences are reported, not forced
- On-prem-synced accounts are detected and flagged for AD instead of failing

### Both
- `-WhatIf` dry runs that still log the full plan, plus `-Confirm` for step-by-step approval
- A failed step is logged and the run continues. The result object shows `Succeeded` / `Failed`
- Delegated or **app-only certificate** auth
- Pester tests with Graph and Exchange fully mocked, PSScriptAnalyzer-clean, GitHub Actions CI

## Time saved

Estimates: a careful manual offboarding takes **20-30 minutes** and onboarding **15-25 minutes** per user. With these scripts it's about **1-2 minutes of review per user**, with a consistent result and an audit trail.

## Requirements

- PowerShell **7.0+**
- Modules:
  ```powershell
  Install-Module Microsoft.Graph.Authentication, ExchangeOnlineManagement -Scope CurrentUser
  ```

## Permissions needed

| Area | Graph permission / role |
|---|---|
| Create/disable users, revoke sessions, set manager | `User.ReadWrite.All` |
| Group membership | `GroupMember.ReadWrite.All` (onboarding with name lookup: `Group.ReadWrite.All`) |
| Licences | `LicenseAssignment.ReadWrite.All` (+ `Organization.Read.All` to read `subscribedSkus`) |
| Manager lookup | `User.Read.All` / `Directory.Read.All` |
| Mailbox, auto-reply, DLs, permissions | Exchange Online: **Exchange Administrator** role (app-only: `Exchange.ManageAsApp` + role assignment) |

The signed-in admin (delegated) needs at least **User Administrator** + **License Administrator** + **Exchange Administrator**. Disabling *privileged* admins needs Privileged Authentication Administrator.

## Usage

### Onboarding

```powershell
Copy-Item ./config/role-templates.example.json ./config/role-templates.json   # edit roles, SKUs, groups

# 1. Dry run
./Start-EntraOnboarding.ps1 -InputPath ./new-hires.csv -WhatIf

# 2. Live run
$r = ./Start-EntraOnboarding.ps1 -InputPath ./new-hires.csv -TenantId contoso.onmicrosoft.com

# 3. Hand temporary passwords to managers through a secure channel
$r | ForEach-Object { '{0}  {1}' -f $_.User, ($_.TemporaryPassword | ConvertFrom-SecureString -AsPlainText) }
```

Input CSV ([example](examples/new-hires.example.csv)):

```csv
FirstName,LastName,Role,ManagerUpn,StartDate,JobTitle,UsageLocation
Ana,Rivera,Sales,slead@contoso.com,2026-11-02,,
```

### Offboarding

```powershell
Copy-Item ./config/offboarding.config.example.json ./config/offboarding.config.json

# 1. Dry run: nothing changes, full plan in the CSV log
./Start-EntraOffboarding.ps1 -UserPrincipalName jordan.doe@contoso.com -WhatIf

# 2. Live, mailbox access to someone other than the Entra manager
./Start-EntraOffboarding.ps1 -UserPrincipalName jordan.doe@contoso.com -DelegateUpn teamlead@contoso.com

# Bulk from CSV, confirm each change
Import-Csv ./leavers.csv | ./Start-EntraOffboarding.ps1 -Confirm

# App-only (certificate)
./Start-EntraOffboarding.ps1 -UserPrincipalName jordan.doe@contoso.com -TenantId contoso.onmicrosoft.com `
    -ClientId $AppId -CertificateThumbprint $Thumb
```

Turn any step off in [`config/offboarding.config.example.json`](config/offboarding.config.example.json) (`"HideFromGAL": false`), and protect groups with `ExcludedGroupIds` / `ExcludedGroupNamePatterns`.

## Sample output

Offboarding log ([full file](examples/sample-offboarding-log.csv)):

```text
Action                  Target                         Status   Details
DisableAccount          jordan.doe@contoso.com         Success
RevokeSessions          jordan.doe@contoso.com         Success
SetAutoReply            jordan.doe@contoso.com         Success  ExternalAudience=All
ConvertToSharedMailbox  jordan.doe@contoso.com         Success
GrantManagerAccess      sam.lead@contoso.com           Success  FullAccess
RemoveGroupMembership   DL-Sales-All (...)             Success  Exchange
RemoveGroupMembership   Dyn-All-Employees (...)        Skipped  Dynamic group (rule-based)
RemoveLicense           f30db892-...                   Skipped  Assigned by group; removed when group membership is removed
RemoveLicense           05e9a617-...                   Success
```

Onboarding log ([full file](examples/sample-onboarding-log.csv)) and [welcome sheet](examples/sample-welcome-sheet.html):

```text
User                     Action         Target         Status   Details
ana.rivera@contoso.com   CreateUser     7b3f...        Success  Ana Rivera; Sales
ana.rivera@contoso.com   AssignLicense  SPE_E3         Success  5 seat(s) left
jose.nunez@contoso.com   AssignLicense  POWER_BI_PRO   Failed   No free seats for POWER_BI_PRO (buy more or free one up)
```

All names, IDs and domains in the examples are fictitious.

## Project layout

```text
Start-EntraOnboarding.ps1     onboarding entry script
Start-EntraOffboarding.ps1    offboarding entry script
src/EntraOnboarding.psm1      onboarding steps
src/EntraOffboarding.psm1     offboarding steps
config/                       example role templates and offboarding config
tests/                        Pester tests (Graph + Exchange mocked)
examples/                     sample CSV input, logs and welcome sheet (fake data)
```

## Running the tests

```powershell
Invoke-Pester ./tests -Output Detailed
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

## Not covered (yet)

- OneDrive access for the manager (SharePoint admin / PnP) and data retention holds
- Wiping or retiring the user's Intune devices
- Reclaiming phone numbers (Teams Phone)

## License

MIT, see [LICENSE](LICENSE).
