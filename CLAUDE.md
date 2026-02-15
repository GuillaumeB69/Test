# CLAUDE.md

## Project Overview

This is the **Test** repository (`GuillaumeB69/Test`). It contains a PowerShell script for extracting and comparing Entra ID (Azure AD) configurations across multiple tenants using the Global Reader role.

## Repository Structure

```
.
├── CLAUDE.md                                    # AI assistant guidance (this file)
├── README.md                                    # Project readme
└── Extract-TenantInventory-GlobalReader.ps1     # Multi-tenant Entra ID extraction script
```

## Key Script: Extract-TenantInventory-GlobalReader.ps1

**Purpose:** Automated inventory extraction for comparing Entra ID settings across multiple tenants with read-only (Global Reader) permissions.

**What it extracts (16 categories):**
1. Tenant properties (name, ID, country, license type)
2. Domains (primary, custom, initial)
3. Users (UPN format, DisplayName conventions, sample of 200)
4. User attributes (EmployeeID, Department, JobTitle, Company, Manager)
5. Extension Attributes 1-15 (usage, examples, population %)
6. Groups (total, M365, security, dynamic)
7. Conditional Access policies and named locations
8. Identity Protection status
9. Admin roles (Global Admins)
10. Administrative Units
11. Licenses (SKUs, purchased, consumed)
12. Devices (by join type and OS)
13. Applications (Enterprise Apps, App Registrations)
14. Hybrid identity (AAD Connect status)
15. Guest users
16. Secure Score

**Outputs:**
- `TenantComparison_YYYYMMDD_HHMMSS.json` - Full data for all tenants
- `Differences_YYYYMMDD_HHMMSS.csv` - Only the differences between tenants

## Development Setup

**Language:** PowerShell
**Required modules (auto-installed by the script):**
- `Microsoft.Graph.Authentication`
- `Microsoft.Graph.Users`
- `Microsoft.Graph.Groups`
- `Microsoft.Graph.Identity.DirectoryManagement`

**Permissions required:** Global Reader role on each target tenant.

## Running the Script

```powershell
$tenants = @{
    "Tenant1" = @{ TenantId = "xxxx-xxxx"; TenantName = "My Tenant 1" }
    "Tenant2" = @{ TenantId = "yyyy-yyyy"; TenantName = "My Tenant 2" }
}
$results = .\Extract-TenantInventory-GlobalReader.ps1 -Tenants $tenants
```

## Git Conventions

- **Default branch:** `master`
- **Commit messages:** Use clear, descriptive messages explaining the "why" behind changes.
- **Branching:** Feature branches should be created off `master`.

## Code Style & Conventions

- **Language:** PowerShell 5.1+ / PowerShell 7+
- **Encoding:** UTF-8 for CSV exports
- **Error handling:** Try/catch with fallback messages per extraction section
- **Output:** Console progress with colored status indicators + JSON/CSV file exports

## Guidelines for AI Assistants

- Read files before modifying them.
- Do not introduce unnecessary complexity or over-engineer solutions.
- Keep changes focused on what is requested.
- Do not add files, dependencies, or abstractions that are not needed.
- Update this CLAUDE.md when significant project structure or workflow changes occur.
- This script targets the Microsoft Graph PowerShell SDK; any modifications should use the `Microsoft.Graph.*` module cmdlets.
