# Case Study: Enterprise .NET Remediation Automation

This project started as a vulnerability remediation task for outdated Microsoft .NET components on Windows endpoints.

At first, the problem seemed simple: detect old .NET versions, install the supported version, and remove the unsupported versions.

During testing, I found that the remediation logic needed to be safer. Removing old .NET components before confirming a supported replacement could create application risk.

The final design focused on safe remediation: confirm or install supported .NET first, re-detect the endpoint state, and only then remove unsupported components.

This project shows how vulnerability remediation requires more than just patching. It also requires validation, testing, safe rollback thinking, and clear reporting.

## Scope and Impact

This remediation affected roughly 3,000–4,000 endpoints out of an environment of about 10,000 assets.

The project was not only a PowerShell automation task. It was a vulnerability management workflow involving scan validation, application-owner coordination, technical testing, and safe remediation planning.

Microsoft .NET and .NET Framework vulnerabilities have appeared in CISA KEV historically, including remote code execution vulnerabilities. Because of that, outdated .NET components were treated as security-relevant software that needed controlled remediation instead of blind removal.

## Ownership Challenge

Another major challenge was ownership.

Because the affected .NET components existed across many different systems, it was not always clear which team owned the remediation. I reached out to multiple teams to identify the right owners, but in many cases ownership was unclear or delayed.

Rather than waiting for someone else to take responsibility, I took initiative to drive the remediation effort forward. I reviewed the Tenable plugin output, analyzed affected systems, worked with technical teams and asset owners, and helped define a safer remediation path.

This became more than a scripting task. It became a vulnerability management project that required ownership mapping, risk communication, technical validation, and coordination across teams.

## Component Selection

One challenge was understanding which .NET components mattered from a vulnerability perspective.

I reviewed Tenable plugin output to identify which .NET components were being reported as potentially vulnerable. The five repeated component patterns in the scripts were selected because they appeared in the vulnerability scan results:

- Microsoft .NET SDK
- Microsoft .NET Runtime
- Microsoft .NET Host FX Resolver
- Microsoft .NET Host
- Microsoft ASP.NET Core Runtime

Other outdated .NET-related components were also considered for cleanup, but the main detection/remediation logic focused on the components confirmed through Tenable plugin output.

## Operational Challenge

During testing, I had to think beyond whether the script worked technically.

I had to consider production risks such as:

- What if an application depends on a specific .NET component?
- What if a server needs x86 instead of only x64?
- What if old components were installed separately instead of through one SDK package?
- What if uninstalling a component breaks an application?

Because of this, remediation required coordination with technical teams and asset owners. If an application required .NET, the remediation path was not simply to remove it. The safer approach was to work with the owner or vendor to identify a supported version.

## Final Logic

The final workflow was designed to reduce production risk:

1. Detect installed .NET components from registry uninstall keys.
2. Parse the component name, version, architecture, and uninstall command.
3. Identify unsupported versions below the approved minimum version.
4. Evaluate x64 and x86 separately.
5. Confirm whether supported replacements exist for the same component type and architecture.
6. Install supported .NET first when needed.
7. Re-detect after installation.
8. Remove unsupported versions only after supported replacements are confirmed.
9. Log results for troubleshooting and validation.

## What I Learned

This project helped me improve in several areas:

- Building safer remediation logic instead of simple uninstall logic
- Understanding which .NET components mattered based on Tenable plugin output
- Handling x64 and x86 separately in PowerShell
- Thinking through production risk before deployment
- Working with technical teams and asset owners
- Using testing to find logic gaps before production rollout

## Business Value

This project helped turn a large vulnerability issue into a controlled remediation workflow.

Instead of manually tracking thousands of affected endpoints, the scripts created a repeatable way to detect, remediate, validate, and log outdated .NET components.

The main value was reducing vulnerability exposure while lowering the risk of breaking applications that depended on .NET.
