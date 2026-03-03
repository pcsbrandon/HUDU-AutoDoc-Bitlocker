# HUDU-AutoDoc

PowerShell automation scripts for documenting endpoints and configurations into [Hudu](https://www.hudu.com) — maintained by Pittsburgh Computer Solutions.

## Scripts

### BitLocker → Hudu (`BitLocker/Invoke-BitLockerToHudu.ps1`)

Collects BitLocker recovery key(s) from a Windows machine and uploads them into Hudu under the correct company and asset layout.

#### What it does
- Gathers system info (hostname, serial number, OS, make/model, last logged-in user)
- Reads BitLocker recovery keys from all encrypted volumes
- Finds the matching Hudu company by name
- Creates or updates a **Configurations** asset for the computer
- Creates or updates a **Bitlocker** asset with the recovery key and drive details
- Links the BitLocker asset to the computer asset via a Hudu Relation

#### Requirements
- Must be run as **Administrator**
- PowerShell 5.1 or later
- Hudu API key with **Password access** enabled
- Hudu asset layouts named `Configurations` and `Bitlocker` must exist

#### Usage
```powershell
.\Invoke-BitLockerToHudu.ps1 -CompanyName "Acme Corp"
```

#### Configuration
Edit the top of the script before deploying:

| Variable | Description |
|---|---|
| `$HuduBaseUrl` | Your Hudu instance API base URL |
| `$HuduApiKey` | Your Hudu API key |
| `$ComputerLayoutName` | Exact name of your computer asset layout in Hudu |
| `$BitLockerLayoutName` | Exact name of your BitLocker asset layout in Hudu |

#### Notes
- The serial number is embedded in the BitLocker asset name for visibility
- To populate the Serial Number field on the Configurations asset, add a `Serial Number` (Text) field to that layout in Hudu Admin
- Custom fields are dynamically filtered — unmatched field labels are silently skipped
- Re-running the script updates existing assets rather than creating duplicates
