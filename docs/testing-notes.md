# Testing Notes

## Test Focus

The script was tested around a few important safety questions:

- Can it detect .NET from registry uninstall keys?
- Can it compare versions correctly?
- Can it separate x64 and x86 components?
- Can it avoid uninstalling old .NET before a supported version exists?
- Can it work differently for Intune and SCCM?

## Main Issues Found During Testing

### 1. Version Parsing

The script needed to extract version numbers from DisplayName values and compare them as PowerShell `[version]` objects instead of plain text.

### 2. Regex Match Check

I learned to check regex results using `.Success` so the script does not process entries where no version was actually found.

### 3. Pattern Matching Bug

A matched pattern variable needed to be reset inside the loop. Otherwise, one .NET component match could accidentally affect the next registry item.

### 4. Architecture Handling

x64 and x86 needed to be evaluated separately because a device could be compliant for x64 but still have unsupported x86 .NET components.

### 5. Safe Remediation

The script should install or confirm supported .NET first, then uninstall unsupported versions.
