# Enterprise .NET Remediation Case Study

PowerShell case study for safely detecting, remediating, and validating outdated Microsoft .NET components across Windows endpoints.

## What This Project Shows

This project demonstrates how unsupported .NET components can be detected and remediated using enterprise deployment tools.

The goal was not just to uninstall old .NET versions. The goal was to do it safely by confirming that a supported replacement exists before removing unsupported components.

## Included Scripts

- `scripts/DotNet-Detection.ps1`  
  Intune detection script used to identify unsupported .NET components.

- `scripts/DotNet-Remediation.ps1`  
  Intune remediation script used to install supported .NET and remove unsupported versions.

- `scripts/DotNet-Detect-Remediate-SCCM-TaskSequence.ps1`  
  SCCM/MECM task sequence version that performs detection, remediation, and local logging.

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

## Disclaimer

This is a sanitized portfolio case study. Test and adjust all scripts before using them in any production environment.
