# scripts

PowerShell script collection organized by topic. Each folder contains the scripts, requirements, examples, and notes that previously lived in its own standalone repository.

## Script folders

| Folder | Contents |
| --- | --- |
| [azure-vm-lifecycle-tools](azure-vm-lifecycle-tools/) | Azure VM lifecycle operations, VHD import, VM clone and conversion helpers, placement inventory, and archived blob rehydration. |
| [azure-vm-uptime-tools](azure-vm-uptime-tools/) | Azure VM uptime reporting and CSV export tools based on Activity Log events and VM power state. |
| [windows-network-diagnostic-tools](windows-network-diagnostic-tools/) | Windows RDP readiness, Active Directory connectivity, and TCP/UDP endpoint monitoring tools. |

## Usage

Clone the repository and move into the folder for the tool you want to run:

```powershell
git clone https://github.com/hrezenmsft/scripts.git
Set-Location scripts
Set-Location .\azure-vm-lifecycle-tools
```

Review the README in each script folder before running a script. The folders keep their own requirements, examples, troubleshooting notes, and security considerations.

## Individual script versions

Every script declares its version in the `.NOTES` help section. On a push to `main`, GitHub Actions increments the version of each changed script using the commit message with the highest release impact:

| Commit prefix | Version change |
| --- | --- |
| `fix:` | Patch, for example `1.0.0` to `1.0.1` |
| `feat:` | Minor, for example `1.0.0` to `1.1.0` |
| `feat!:` or `BREAKING CHANGE:` | Major, for example `1.0.0` to `2.0.0` |

Use a `fix:`, `feat:`, or breaking-change commit whenever a PowerShell script changes. The workflow commits the resulting version updates with `[skip script-version]` to prevent a second bump.

## Disclaimer

The sample scripts are not supported under any Microsoft standard support program or service. They are provided AS IS without warranty of any kind. The entire risk arising from their use or performance remains with you.

## License

Licensed under the [MIT License](LICENSE).