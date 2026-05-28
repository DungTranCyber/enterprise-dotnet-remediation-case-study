# Enterprise .NET Remediation Case Study

PowerShell case study for safely detecting, remediating, and validating outdated Microsoft .NET components across Windows endpoints.

## What This Project Shows

This project walks through how I detected unsupported .NET components, tested the remediation logic, and built a safer install-before-uninstall workflow for Intune and SCCM/MECM.

The goal was not just to uninstall old .NET versions. The goal was to do it safely by confirming that a supported replacement exists before removing unsupported components.

## Included Scripts

| Script | Purpose |
|---|---|
| `scripts/DotNet-Detection.ps1` | Intune detection script. Detects unsupported .NET components and returns exit code `1` when remediation is needed. |
| `scripts/DotNet-Remediation.ps1` | Intune remediation script. Installs supported .NET first when needed, then removes unsupported versions after validation. |
| `scripts/DotNet-Detect-Remediate-SCCM-TaskSequence.ps1` | SCCM/MECM task sequence script. Combines detection, remediation, re-detection, uninstall logic, and local logging. |

## Skills Demonstrated

- PowerShell automation
- Vulnerability remediation
- Registry-based software detection
- Version parsing and comparison
- x64/x86 architecture handling
- Intune Proactive Remediation design
- SCCM/MECM task sequence scripting
- Safe install-before-uninstall remediation logic
- Endpoint logging and troubleshooting

## Scripts

- [PowerShell Scripts](scripts/)  
  Contains the Intune detection script, Intune remediation script, and SCCM/MECM task sequence script.
  
## Project Documentation

- [Case Study](docs/case-study.md)  
  Full story of the remediation problem, ownership challenge, technical decisions, and business value.

- [Testing Notes](docs/testing-notes.md)  
  Technical issues found during testing, including version parsing, architecture handling, and SCCM logging.

- [Lessons Learned](docs/lessons-learned.md)  
  Summary of what this project taught me about vulnerability remediation, PowerShell, and production risk.
  
## Disclaimer

This is a sanitized portfolio case study. The scripts do not contain company names, internal server names, usernames, private URLs, or production data.

Test and adjust all scripts before using them in any production environment.
