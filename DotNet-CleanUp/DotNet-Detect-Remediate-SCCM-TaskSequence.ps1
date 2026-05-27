# ============================================================
# SCCM Task Sequence Script - .NET Detect + Install + Uninstall
#
# Purpose:
# - Detect unsupported .NET components below 8.0.27.
# - For each architecture, x64 and x86:
#   - If old .NET exists and supported replacement exists, uninstall old.
#   - If old .NET exists but supported replacement is missing, install supported .NET first.
#   - Re-detect after install.
#   - Only uninstall old versions after supported replacement is confirmed.
#
# Log:
# - C:\Windows\CCM\Logs\DotNet-Install-Uninstall.log
# ============================================================

$ErrorActionPreference = "Stop"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# -----------------------------
# Config
# -----------------------------

$MinimumSupportedVersion = [version]"8.0.27"

$LogPath = "C:\Windows\CCM\Logs\DotNet-Install-Uninstall.log"

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

$CorePatterns = @(
    ".NET SDK",
    ".NET Runtime",
    ".NET Host FX Resolver",
    ".NET Host -",
    "ASP.NET Core Runtime"
)

$OptionalRemovalPatterns = @(
    ".NET AppHost Pack",
    ".NET Targeting Pack",
    ".NET Templates",
    ".NET Toolset"
)

$ArchitecturesToCheck = @(
    "x64",
    "x86"
)

$RegistryPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
)

# -----------------------------
# Logging
# -----------------------------

function Write-Log {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Line = "$Timestamp [$Level] $Message"

    Write-Output $Line

    $LogFolder = Split-Path $LogPath -Parent

    if (-not (Test-Path $LogFolder)) {
        New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
    }

    Add-Content -Path $LogPath -Value $Line
}

# -----------------------------
# Pattern Detection
# -----------------------------

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

# -----------------------------
# Detect Installed .NET
# -----------------------------

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

# -----------------------------
# Check Architecture Status
# -----------------------------

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
            Architecture                 = $Architecture
            HasOldVersions               = $false
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
            Architecture                 = $Architecture
            HasOldVersions               = $false
            ShouldInstallSupportedDotNet = $false
            CanUninstallOldDotNet        = $false
            MissingPatterns              = @()
            OldVersions                  = @()
        }
    }

    # Only require supported replacements for core patterns that already exist
    # for this architecture.
    $CorePatternsToCheck = $CorePatterns | Where-Object {
        $Pattern = $_

        $ArchitectureInstalls | Where-Object {
            $_.Pattern -eq $Pattern
        }
    }

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
            Architecture                 = $Architecture
            HasOldVersions               = $true
            ShouldInstallSupportedDotNet = $false
            CanUninstallOldDotNet        = $true
            MissingPatterns              = @()
            OldVersions                  = $OldVersions
        }
    }
    else {
        return [PSCustomObject]@{
            Architecture                 = $Architecture
            HasOldVersions               = $true
            ShouldInstallSupportedDotNet = $true
            CanUninstallOldDotNet        = $false
            MissingPatterns              = $MissingPatterns
            OldVersions                  = $OldVersions
        }
    }
}

# -----------------------------
# Install Supported .NET
# -----------------------------

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

    Write-Log "Downloading supported .NET installer for $Architecture from $InstallerUrl"

    Invoke-WebRequest -Uri $InstallerUrl -OutFile $InstallerPath -UseBasicParsing

    if (-not (Test-Path $InstallerPath)) {
        throw "Installer download failed for $Architecture. File not found: $InstallerPath"
    }

    Write-Log "Installing supported .NET for $Architecture using $InstallerPath"

    $InstallArgs = "/install /quiet /norestart"

    $Process = Start-Process -FilePath $InstallerPath `
        -ArgumentList $InstallArgs `
        -Wait `
        -PassThru

    Write-Log "Installer exit code for $Architecture`: $($Process.ExitCode)"

    Remove-Item -Path $InstallerPath -Force -ErrorAction SilentlyContinue

    if ($Process.ExitCode -notin @(0, 3010, 1641)) {
        throw ".NET install failed for $Architecture with exit code $($Process.ExitCode)"
    }

    Write-Log "Supported .NET install completed for $Architecture"
}

# -----------------------------
# Uninstall Old .NET
# -----------------------------

function Invoke-DotNetUninstall {
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$DotNetItem
    )

    Write-Log "Preparing uninstall: $($DotNetItem.DisplayName)"

    $QuietUninstall = $DotNetItem.QuietUninstall
    $UninstallString = $DotNetItem.UninstallString

    if ([string]::IsNullOrWhiteSpace($QuietUninstall) -and [string]::IsNullOrWhiteSpace($UninstallString)) {
        Write-Log "No uninstall string found for $($DotNetItem.DisplayName). Skipping." "WARN"
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($QuietUninstall)) {
        Write-Log "Using QuietUninstallString for $($DotNetItem.DisplayName)"

        $Process = Start-Process -FilePath "cmd.exe" `
            -ArgumentList "/c `"$QuietUninstall`"" `
            -Wait `
            -PassThru

        Write-Log "Uninstall exit code for $($DotNetItem.DisplayName): $($Process.ExitCode)"

        if ($Process.ExitCode -notin @(0, 3010, 1605, 1614, 1641)) {
            throw "Uninstall failed for $($DotNetItem.DisplayName) with exit code $($Process.ExitCode)"
        }

        return
    }

    if ($UninstallString -match "\{[A-Fa-f0-9\-]{36}\}") {
        $ProductCode = $Matches[0]

        Write-Log "Using MSI product code uninstall for $($DotNetItem.DisplayName): $ProductCode"

        $Process = Start-Process -FilePath "msiexec.exe" `
            -ArgumentList "/x $ProductCode /qn /norestart" `
            -Wait `
            -PassThru

        Write-Log "Uninstall exit code for $($DotNetItem.DisplayName): $($Process.ExitCode)"

        if ($Process.ExitCode -notin @(0, 3010, 1605, 1614, 1641)) {
            throw "Uninstall failed for $($DotNetItem.DisplayName) with exit code $($Process.ExitCode)"
        }

        return
    }

    Write-Log "Using fallback uninstall string for $($DotNetItem.DisplayName)"

    $FallbackCommand = "$UninstallString /quiet /norestart"

    $Process = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c `"$FallbackCommand`"" `
        -Wait `
        -PassThru

    Write-Log "Uninstall exit code for $($DotNetItem.DisplayName): $($Process.ExitCode)"

    if ($Process.ExitCode -notin @(0, 3010, 1605, 1614, 1641)) {
        throw "Uninstall failed for $($DotNetItem.DisplayName) with exit code $($Process.ExitCode)"
    }
}

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

    if (-not $OldVersionsForArchitecture) {
        Write-Log "No old .NET versions found for $Architecture"
        return
    }

    foreach ($OldItem in $OldVersionsForArchitecture) {
        Invoke-DotNetUninstall -DotNetItem $OldItem
    }
}

# -----------------------------
# Main
# -----------------------------

try {
    Write-Log "========== Starting .NET SCCM task sequence remediation =========="
    Write-Log "Minimum supported .NET version: $MinimumSupportedVersion"

    $DotNetInstalls = Get-DotNetInstalls

    if ($DotNetInstalls) {
        $DetectedLine = ($DotNetInstalls | Sort-Object Architecture, Pattern, Version | ForEach-Object {
            "[$($_.Architecture)] $($_.DisplayName)"
        }) -join " | "

        Write-Log "Detected .NET components: $DetectedLine"
    }
    else {
        Write-Log "No matching .NET components detected."
    }

    foreach ($Architecture in $ArchitecturesToCheck) {
        Write-Log "Processing architecture: $Architecture"

        $Status = Test-DotNetArchitectureStatus `
            -Architecture $Architecture `
            -DotNetInstalls $DotNetInstalls

        if ($Status.HasOldVersions -eq $false) {
            Write-Log "No unsupported .NET versions detected for $Architecture. Skipping architecture."
            continue
        }

        $OldLine = ($Status.OldVersions | ForEach-Object {
            "[$($_.Architecture)] $($_.DisplayName)"
        }) -join " | "

        Write-Log "Unsupported .NET detected for $Architecture`: $OldLine" "WARN"

        if ($Status.ShouldInstallSupportedDotNet -eq $true) {
            $MissingLine = ($Status.MissingPatterns | Sort-Object -Unique) -join ", "
            Write-Log "Supported replacement missing for $Architecture. Missing core pattern(s): $MissingLine" "WARN"

            Install-SupportedDotNet -Architecture $Architecture

            Write-Log "Re-detecting .NET after install for $Architecture"

            $DotNetInstalls = Get-DotNetInstalls

            $Status = Test-DotNetArchitectureStatus `
                -Architecture $Architecture `
                -DotNetInstalls $DotNetInstalls
        }

        if ($Status.CanUninstallOldDotNet -eq $true) {
            Write-Log "Supported .NET confirmed for $Architecture. Uninstalling old unsupported versions."
            Uninstall-OldDotNetVersions `
                -Architecture $Status.Architecture `
                -OldVersions $Status.OldVersions
        }
        else {
            throw "Supported .NET replacement was not confirmed for $Architecture. Old versions were not removed."
        }

        $DotNetInstalls = Get-DotNetInstalls
    }

    $FinalInstalls = Get-DotNetInstalls

    $RemainingUnsupported = $FinalInstalls | Where-Object {
        $_.IsOldVersion -eq $true
    } | Sort-Object Architecture, Pattern, Version, DisplayName

    if ($RemainingUnsupported) {
        $RemainingLine = ($RemainingUnsupported | ForEach-Object {
            "[$($_.Architecture)] $($_.DisplayName)"
        }) -join " | "

        Write-Log "Remediation completed but unsupported .NET remains: $RemainingLine" "ERROR"
        exit 1
    }
    else {
        $SupportedFinal = $FinalInstalls | Where-Object {
            $_.IsSupported -eq $true
        } | Sort-Object Architecture, Pattern, Version, DisplayName

        $SupportedLine = ($SupportedFinal | ForEach-Object {
            "[$($_.Architecture)] $($_.DisplayName)"
        }) -join " | "

        Write-Log "Remediation successful. Supported .NET installed: $SupportedLine"
        exit 0
    }
}
catch {
    Write-Log "Remediation failed: $($_.Exception.Message)" "ERROR"
    exit 1
}