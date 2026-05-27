# Case Study: Enterprise .NET Remediation Automation

This project started as a vulnerability remediation task for outdated Microsoft .NET components on Windows endpoints.

At first, the problem seemed simple: detect old .NET versions, install the supported version, and remove the unsupported versions.

During testing, I found that the remediation logic needed to be safer. Removing old .NET components before confirming a supported replacement could create application risk.

The final design used this logic:

1. Detect installed .NET components from Windows registry uninstall keys.
2. Identify unsupported versions below the approved minimum version.
3. Separate x64 and x86 components.
4. Confirm a supported replacement exists.
5. Install supported .NET first when needed.
6. Re-detect after installation.
7. Remove unsupported versions only after the supported replacement is confirmed.

This project shows how vulnerability remediation requires more than just patching. It also requires validation, testing, safe rollback thinking, and clear reporting.
