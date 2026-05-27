# Lessons Learned

## 1. Vulnerability remediation is not just patching

This project showed me that remediation requires more than installing a new version. I had to understand the affected software, validate scan results, coordinate with owners, and reduce production risk.

## 2. .NET components are more complex than they first look

One challenge was understanding which .NET components mattered from a vulnerability perspective. I used Tenable plugin output to focus on the components that were actually reported as potentially vulnerable.

## 3. Architecture matters

x64 and x86 components had to be evaluated separately. A machine could be compliant for x64 but still have unsupported x86 components.

## 4. Safe remediation matters

The safest logic was to confirm or install the supported .NET component first, then remove the unsupported version after validation.

## 5. Ownership is part of vulnerability management

Some findings did not have clear ownership. I had to take initiative, work with teams, and help drive the remediation forward instead of waiting for the issue to stay unresolved.
