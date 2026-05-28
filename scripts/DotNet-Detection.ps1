<#
.SYNOPSIS
Detects unsupported Microsoft .NET components for Intune Proactive Remediations.

.DESCRIPTION
This script checks Windows registry uninstall paths for installed Microsoft .NET components,
compares detected versions against the approved minimum supported version, and exits with
code 1 when remediation is needed.

The detection output is kept short because Intune Proactive Remediations works best with
clear single-line status output.

.NOTES
Portfolio case study script.
Sanitized for public GitHub use.

Exit codes:
- 1 = Unsupported .NET detected; remediation needed.
- 0 = No unsupported .NET detected; remediation not needed.
#>

$ErrorActionPreference = "Stop"

# Minimum approved .NET version for this case study.
# Any detected .NET component below this version is treated as unsupported
# and will trigger Intune remediation.
$MinimumSupportedVersion = [version]"8.0.27"

$Separator = " | "

# Check 64-bit and 32-bit installs,
# and per-user installs. This helps catch both x64 and x86 .NET components
# that may appear in different uninstall registry locations. My favorite place to get apps info.
$RegistryPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
)

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

        [PSCustomObject]@{
            DisplayName  = $DisplayName
            Pattern      = $Pattern
            Version      = $DetectedVersion
            Architecture = $Architecture
            IsSupported  = $DetectedVersion -ge $MinimumSupportedVersion
            IsOldVersion = $DetectedVersion -lt $MinimumSupportedVersion
        }
    }

    $UnsupportedDotNet = $ParsedDotNetInstalls | Where-Object {
        $_.IsOldVersion -eq $true
    } | Sort-Object Architecture, Pattern, Version, DisplayName

    $SupportedDotNet = $ParsedDotNetInstalls | Where-Object {
        $_.IsSupported -eq $true
    } | Sort-Object Architecture, Pattern, Version, DisplayName

    if ($UnsupportedDotNet) {
        $UnsupportedList = ($UnsupportedDotNet | ForEach-Object {
            "[$($_.Architecture)] $($_.DisplayName)"
        }) -join $Separator

        Write-Output "Unsupported .NET detected: $UnsupportedList"
        exit 1
    }
    else {
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
    Write-Output "Detection error: $($_.Exception.Message)"
    exit 1
}
