<#
.SYNOPSIS
Detects unsupported Microsoft .NET components for Intune Proactive Remediations.

.DESCRIPTION
Checks common Windows uninstall registry locations for Microsoft .NET components.
Detected versions are compared against the minimum approved version.

Exit codes:
  1 = Unsupported .NET detected; remediation needed
  0 = No unsupported .NET detected

.NOTES
Portfolio case study script.
Sanitized for public GitHub use.

The detection output is kept short because Intune Proactive Remediations works best with
clear single-line status output.
#>

$ErrorActionPreference = "Stop"

# Minimum approved .NET version for this case study.
# Anything below this version is treated as unsupported.
$MinimumSupportedVersion = [version]"8.0.27"
$Separator = " | "


# Windows can store installed application information in multiple locations.
# Checking all common uninstall registry paths helps detect:
#
# - 64-bit applications
# - 32-bit applications on 64-bit systems
# - Per-user installs
#
# This matters in enterprise environments because different .NET components
# may appear in different registry locations depending on how they were installed.
$RegistryPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
)

# Normalizes different .NET display names into component categories.
# This makes the final output easier to read and helps avoid matching
# unrelated Microsoft entries that only contain ".NET" in the name.
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

# Main detection workflow:
# 1. Read installed software entries from Windows uninstall registry paths.
# 2. Keep only Microsoft .NET and ASP.NET Core Runtime entries.
# 3. Ignore unrelated entries by matching known .NET component naming patterns.
# 4. Extract the version and architecture from each display name.
# 5. Compare each detected version against the approved minimum version.
# 6. Return exit code 1 if old .NET is found so Intune can run remediation.
try {
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
        # Store the cleaned detection result as an object.
        # This makes it easier to sort, filter, and report unsupported .NET installs later
        # instead of working with raw registry entries.
        [PSCustomObject]@{
            DisplayName  = $DisplayName
            Pattern      = $Pattern
            Version      = $DetectedVersion
            Architecture = $Architecture
            IsSupported  = $DetectedVersion -ge $MinimumSupportedVersion
            IsOldVersion = $DetectedVersion -lt $MinimumSupportedVersion
        }
    }
    # Split the parsed .NET results into unsupported and supported groups.
    #
    # Unsupported items are below the approved minimum version and should trigger remediation.
    # Supported items are kept so the detection output can still show what was found
    # when the endpoint does not need remediation.
    $UnsupportedDotNet = $ParsedDotNetInstalls | Where-Object {
        $_.IsOldVersion -eq $true
    } | Sort-Object Architecture, Pattern, Version, DisplayName

    $SupportedDotNet = $ParsedDotNetInstalls | Where-Object {
        $_.IsSupported -eq $true
    } | Sort-Object Architecture, Pattern, Version, DisplayName
    
    # If any unsupported .NET components were found, return exit code 1.
    # Intune Proactive Remediations uses this as the signal that remediation should run.
    # The output includes the architecture and display name to make troubleshooting easier.
    if ($UnsupportedDotNet) {
        $UnsupportedList = ($UnsupportedDotNet | ForEach-Object {
            "[$($_.Architecture)] $($_.DisplayName)"
        }) -join $Separator

        Write-Output "Unsupported .NET detected: $UnsupportedList"
        exit 1
    }
    else {
        # If no unsupported .NET components were found, return exit code 0.
        # When supported .NET components exist, include them in the output so the result shows what was checked.
        # If no matching .NET components were found, the device is still compliant because there is nothing unsupported to remove.
        if ($SupportedDotNet) {
            $SupportedList = ($SupportedDotNet | ForEach-Object {
                "[$($_.Architecture)] $($_.DisplayName)"
            }) -join $Separator

            Write-Output "No unsupported .NET detected. Supported .NET installed: $SupportedList"
            exit 0
        }
        else {
            Write-Output "No unsupported .NET detected. No matching .NET components found."
            exit 0
        }
    }
}
catch {
    # If detection fails, do not trigger remediation automatically.
    # A detection error means the script could not confirm whether unsupported .NET exists.
    # Return exit code 0 so remediation does not run based on an unknown state,
    # but still write the error message so it can be reviewed in Intune detection output.
    Write-Output "Detection error. Unable to confirm .NET compliance status: $($_.Exception.Message)"
    exit 0
}
