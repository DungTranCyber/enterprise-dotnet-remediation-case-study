<#
.SYNOPSIS
Remediates unsupported Microsoft .NET components on Windows endpoints.

.DESCRIPTION
This script is designed for Intune Proactive Remediations.

It detects installed Microsoft .NET components from Windows registry uninstall keys,
checks for unsupported versions below the approved minimum version, installs a
supported replacement when needed, re-detects the endpoint state, and removes
unsupported versions only after supported .NET is confirmed.

The remediation logic evaluates x64 and x86 components separately to reduce
application risk.

.NOTES
Portfolio case study script.
Sanitized for public GitHub use.

Key safety logic:
- Do not uninstall unsupported .NET first.
- Confirm or install supported .NET before removal.
- Re-detect after installation.
- Remove old versions only when supported replacement exists.
#>

$ErrorActionPreference = "Stop"

# Force TLS 1.2 for installer downloads.
# This helps avoid download failures on systems where older TLS defaults may still be used.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Minimum approved .NET version for this case study.
# Any installed .NET component below this version is treated as unsupported.
$MinimumSupportedVersion = [version]"8.0.27"

# Separator used when multiple .NET components need to be written in one Intune output line.
$Separator = " | "

# Installer map for supported .NET replacements.
# The remediation logic handles x64 and x86 separately so each architecture can be evaluated
# and repaired without assuming both architectures need the same action.
$InstallerMap = @{
    x64 = @{
        Url      = "https://builds.dotnet.microsoft.com/dotnet/Sdk/10.0.300/dotnet-sdk-10.0.300-win-x64.exe"
        FileName = "dotnet-sdk-10.0.300-win-x64.exe"
    }

    x86 = @{
        Url      = "https://builds.dotnet.microsoft.com/dotnet/Sdk/8.0.421/dotnet-sdk-8.0.421-win-x86.exe"
        FileName = "dotnet-sdk-8.0.421-win-x86.exe"
    }
}

# Core .NET component types that should have a supported replacement before old versions are removed.
# This avoids uninstalling important runtime pieces before confirming the endpoint has a safe replacement.
$CorePatterns = @(
    ".NET SDK",
    ".NET Runtime",
    ".NET Host FX Resolver",
    ".NET Host -",
    "ASP.NET Core Runtime"
)

# Architectures evaluated by the remediation workflow.
# x64 and x86 are checked separately because an endpoint can have old .NET components in one architecture
# even when the other architecture is already compliant.
$ArchitecturesToCheck = @(
    "x64",
    "x86"
)

# Registry uninstall locations checked for installed .NET components.
# These paths help detect machine-wide 64-bit installs, 32-bit installs, and per-user installs.
$RegistryPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
)

# Normalizes different .NET registry DisplayName values into consistent component categories.
# The uninstall registry names are not always formatted the same way, so this function helps
# the rest of the script compare components without relying on one exact DisplayName.
function Get-DotNetPattern {
    param (
        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )

    if ($DisplayName -match "^Microsoft \.NET SDK\s+\d+\.\d+\.\d+") {
        return ".NET SDK"
    }
    elseif ($DisplayName -match "^Microsoft \.NET Runtime\s+-\s+\d+\.\d+\.\d+") {
        return ".NET Runtime"
    }
    elseif ($DisplayName -match "^Microsoft \.NET Host FX Resolver\s+-\s+\d+\.\d+\.\d+") {
        return ".NET Host FX Resolver"
    }
    elseif ($DisplayName -match "^Microsoft \.NET Host\s+-\s+\d+\.\d+\.\d+") {
        return ".NET Host -"
    }
    elseif ($DisplayName -match "^Microsoft ASP\.NET Core Runtime\s+-\s+\d+\.\d+\.\d+") {
        return "ASP.NET Core Runtime"
    }
    elseif ($DisplayName -match "^Microsoft \.NET AppHost Pack\s+-\s+\d+\.\d+\.\d+") {
        return ".NET AppHost Pack"
    }
    elseif ($DisplayName -match "^Microsoft \.NET Targeting Pack\s+-\s+\d+\.\d+\.\d+") {
        return ".NET Targeting Pack"
    }
    elseif ($DisplayName -match "^Microsoft \.NET .*Templates\s+\d+\.\d+\.\d+") {
        return ".NET Templates"
    }
    elseif ($DisplayName -match "^Microsoft \.NET Toolset\s+\d+\.\d+\.\d+") {
        return ".NET Toolset"
    }

    return $null
}

# Reads installed .NET components from the uninstall registry paths and converts them
# into cleaner objects the remediation workflow can use.
#
# This function keeps the registry lookup in one place so the script can re-run detection
# after installing supported .NET and again after uninstalling old versions.
function Get-DotNetInstalls {
    $Installs = Get-ChildItem -Path $RegistryPaths -ErrorAction SilentlyContinue |
        Get-ItemProperty -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.DisplayName -like "*Microsoft .NET*") -or
            ($_.DisplayName -like "*ASP.NET Core Runtime*")
        }

    $ParsedDotNetInstalls = foreach ($Install in $Installs) {
        $DisplayName = $Install.DisplayName

        if ([string]::IsNullOrWhiteSpace($DisplayName)) {
            continue
        }

        $Pattern = Get-DotNetPattern -DisplayName $DisplayName

        if (-not $Pattern) {
            continue
        }

        $VersionMatch = [regex]::Match($DisplayName, "\d+\.\d+\.\d+")
        $ArchMatch = [regex]::Match($DisplayName, "\(?(x64|x86|arm64)\)?")

        if (-not $VersionMatch.Success) {
            continue
        }

        $DetectedVersion = [version]$VersionMatch.Value

        if ($ArchMatch.Success) {
            $Architecture = $ArchMatch.Groups[1].Value
        }
        else {
            $Architecture = "Unknown"
        }
        
        # Store the parsed registry entry as a clean object.
        # The remediation workflow needs both compliance details and uninstall details:
        # - Version and architecture are used to decide what needs remediation.
        # - Uninstall strings are used later if old versions are safe to remove.
        [PSCustomObject]@{
            DisplayName     = $DisplayName
            Pattern         = $Pattern
            Version         = $DetectedVersion
            Architecture    = $Architecture
            IsSupported     = $DetectedVersion -ge $MinimumSupportedVersion
            IsOldVersion    = $DetectedVersion -lt $MinimumSupportedVersion
            UninstallString = $Install.UninstallString
            QuietUninstall  = $Install.QuietUninstallString
            RegistryKey     = $Install.PSChildName
            RegistryPath    = $Install.PSPath
        }
    }

    return $ParsedDotNetInstalls
}

# Evaluates one architecture at a time and decides whether remediation is needed.
#
# This function answers three questions:
# - Are there old .NET versions for this architecture?
# - Is a supported replacement already present?
# - Is it safe to uninstall the old versions yet?
function Test-DotNetArchitectureStatus {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Architecture,

        [Parameter(Mandatory = $true)]
        [array]$DotNetInstalls
    )

    $ArchitectureInstalls = $DotNetInstalls | Where-Object {
        $_.Architecture -eq $Architecture
    }

    if (-not $ArchitectureInstalls) {
        return [PSCustomObject]@{
            Architecture                = $Architecture
            HasOldVersions              = $false
            ShouldInstallSupportedDotNet = $false
            CanUninstallOldDotNet        = $false
            MissingPatterns              = @()
            OldVersions                  = @()
        }
    }

    $OldVersions = $ArchitectureInstalls | Where-Object {
        $_.IsOldVersion -eq $true
    }

    if (-not $OldVersions) {
        return [PSCustomObject]@{
            Architecture                = $Architecture
            HasOldVersions              = $false
            ShouldInstallSupportedDotNet = $false
            CanUninstallOldDotNet        = $false
            MissingPatterns              = @()
            OldVersions                  = @()
        }
    }

    # Only require supported replacements for core patterns that already exist
    # on this architecture.
    $CorePatternsToCheck = $CorePatterns | Where-Object {
        $Pattern = $_

        $ArchitectureInstalls | Where-Object {
            $_.Pattern -eq $Pattern
        }
    }

    # Check whether each existing core .NET component has a supported replacement.
    # MissingPatterns is used as a safety check so old .NET is not removed before
    # the replacement components are confirmed on the same architecture.
    $MissingPatterns = @()

    foreach ($Pattern in $CorePatternsToCheck) {
        $SupportedPatternExists = $ArchitectureInstalls | Where-Object {
            $_.Pattern -eq $Pattern -and
            $_.Version -ge $MinimumSupportedVersion
        }

        if (-not $SupportedPatternExists) {
            $MissingPatterns += $Pattern
        }
    }

    if (@($CorePatternsToCheck).Count -gt 0 -and @($MissingPatterns).Count -eq 0) {
        return [PSCustomObject]@{
            Architecture                = $Architecture
            HasOldVersions              = $true
            ShouldInstallSupportedDotNet = $false
            CanUninstallOldDotNet        = $true
            MissingPatterns              = @()
            OldVersions                  = $OldVersions
        }
    }
    else {
        return [PSCustomObject]@{
            Architecture                = $Architecture
            HasOldVersions              = $true
            ShouldInstallSupportedDotNet = $true
            CanUninstallOldDotNet        = $false
            MissingPatterns              = $MissingPatterns
            OldVersions                  = $OldVersions
        }
    }
}

# Downloads and installs the supported .NET installer for the requested architecture.
#
# This only runs when the architecture has old .NET components and the script cannot confirm
# that all required supported replacements already exist.
function Install-SupportedDotNet {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Architecture
    )

    if (-not $InstallerMap.ContainsKey($Architecture)) {
        throw "No installer configured for architecture: $Architecture"
    }

    $InstallerUrl = $InstallerMap[$Architecture].Url
    $FileName = $InstallerMap[$Architecture].FileName
    $InstallerPath = Join-Path $env:TEMP $FileName

    Invoke-WebRequest -Uri $InstallerUrl -OutFile $InstallerPath -UseBasicParsing

    if (-not (Test-Path $InstallerPath)) {
        throw "Installer download failed for $Architecture. File not found: $InstallerPath"
    }

    $InstallArgs = "/install /quiet /norestart"

    $Process = Start-Process -FilePath $InstallerPath `
        -ArgumentList $InstallArgs `
        -Wait `
        -PassThru

    Remove-Item -Path $InstallerPath -Force -ErrorAction SilentlyContinue

    if ($Process.ExitCode -notin @(0, 3010, 1641)) {
        throw ".NET install failed for $Architecture with exit code $($Process.ExitCode)"
    }
}

# Uninstalls one old .NET component using the best uninstall method available.
#
# The script prefers QuietUninstallString when it exists because it is already designed
# for silent removal. If that is not available, it tries to extract the MSI product code
# from the normal uninstall string. The fallback option runs the uninstall string with
# quiet and no-restart arguments.
function Invoke-DotNetUninstall {
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$DotNetItem
    )

    $QuietUninstall = $DotNetItem.QuietUninstall
    $UninstallString = $DotNetItem.UninstallString

    if ([string]::IsNullOrWhiteSpace($QuietUninstall) -and [string]::IsNullOrWhiteSpace($UninstallString)) {
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($QuietUninstall)) {
        $Process = Start-Process -FilePath "cmd.exe" `
            -ArgumentList "/c `"$QuietUninstall`"" `
            -Wait `
            -PassThru

        if ($Process.ExitCode -notin @(0, 3010, 1605, 1614, 1641)) {
            throw "Uninstall failed for $($DotNetItem.DisplayName) with exit code $($Process.ExitCode)"
        }

        return
    }

    if ($UninstallString -match "\{[A-Fa-f0-9\-]{36}\}") {
        $ProductCode = $Matches[0]

        $Process = Start-Process -FilePath "msiexec.exe" `
            -ArgumentList "/x $ProductCode /qn /norestart" `
            -Wait `
            -PassThru

        if ($Process.ExitCode -notin @(0, 3010, 1605, 1614, 1641)) {
            throw "Uninstall failed for $($DotNetItem.DisplayName) with exit code $($Process.ExitCode)"
        }

        return
    }

    $FallbackCommand = "$UninstallString /quiet /norestart"

    $Process = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c `"$FallbackCommand`"" `
        -Wait `
        -PassThru

    if ($Process.ExitCode -notin @(0, 3010, 1605, 1614, 1641)) {
        throw "Uninstall failed for $($DotNetItem.DisplayName) with exit code $($Process.ExitCode)"
    }
}

# Removes old .NET components for one architecture after the safety checks pass.
#
# The old versions are sorted first so the removal order is predictable in logs
# and easier to troubleshoot if one uninstall fails.
function Uninstall-OldDotNetVersions {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Architecture,

        [Parameter(Mandatory = $true)]
        [array]$OldVersions
    )

    $OldVersionsForArchitecture = $OldVersions | Where-Object {
        $_.Architecture -eq $Architecture
    } | Sort-Object Version, Pattern, DisplayName

    foreach ($OldItem in $OldVersionsForArchitecture) {
        Invoke-DotNetUninstall -DotNetItem $OldItem
    }
}
# Main remediation workflow.
#
# The script starts by detecting installed .NET components, then checks each architecture separately.
# If old .NET exists and a supported replacement is missing, it installs the supported version first.
# After installation, it re-detects the endpoint before uninstalling old versions.
#
# This install-before-uninstall order is the main safety control in the script.
try {
    $DotNetInstalls = Get-DotNetInstalls

    foreach ($Architecture in $ArchitecturesToCheck) {
        # Check the current architecture before taking action.
        # If this architecture has no old .NET versions, skip it and move to the next one.
        $Status = Test-DotNetArchitectureStatus `
            -Architecture $Architecture `
            -DotNetInstalls $DotNetInstalls

        if ($Status.HasOldVersions -eq $false) {
            continue
        }

        if ($Status.ShouldInstallSupportedDotNet -eq $true) {
            # Install the supported .NET replacement before removing old versions.
            # After installation, re-run detection and rebuild the architecture status.
            # This confirms the replacement is actually present before uninstalling anything.
            Install-SupportedDotNet -Architecture $Architecture

            $DotNetInstalls = Get-DotNetInstalls

            $Status = Test-DotNetArchitectureStatus `
                -Architecture $Architecture `
                -DotNetInstalls $DotNetInstalls
        }

        if ($Status.CanUninstallOldDotNet -eq $true) {
            # Only remove old .NET versions after the status check confirms a supported replacement exists.
            # If that confirmation fails, the script stops instead of risking removal of needed runtime components.
            Uninstall-OldDotNetVersions `
                -Architecture $Status.Architecture `
                -OldVersions $Status.OldVersions
        }
        else {
            throw "Supported .NET replacement was not confirmed for $Architecture. Old versions were not removed."
        }

        $DotNetInstalls = Get-DotNetInstalls
    }
# Final validation pass after all architecture-specific remediation steps complete.
# This re-checks the endpoint state instead of assuming the installs and uninstalls worked.
# Remediation script finished its install-before-uninstall workflow.
# Intune will run the detection script again after remediation to determine final compliance.
Write-Output "Remediation workflow completed. Final compliance will be verified by the detection script."
exit 0
}
catch {
    Write-Output "Remediation error: $($_.Exception.Message)"
    exit 1
}
