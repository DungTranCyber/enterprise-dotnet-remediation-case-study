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

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$MinimumSupportedVersion = [version]"8.0.27"
$Separator = " | "

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

$ArchitecturesToCheck = @(
    "x64",
    "x86"
)

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

try {
    $DotNetInstalls = Get-DotNetInstalls

    foreach ($Architecture in $ArchitecturesToCheck) {
        $Status = Test-DotNetArchitectureStatus `
            -Architecture $Architecture `
            -DotNetInstalls $DotNetInstalls

        if ($Status.HasOldVersions -eq $false) {
            continue
        }

        if ($Status.ShouldInstallSupportedDotNet -eq $true) {
            Install-SupportedDotNet -Architecture $Architecture

            $DotNetInstalls = Get-DotNetInstalls

            $Status = Test-DotNetArchitectureStatus `
                -Architecture $Architecture `
                -DotNetInstalls $DotNetInstalls
        }

        if ($Status.CanUninstallOldDotNet -eq $true) {
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
        $RemainingList = ($RemainingUnsupported | ForEach-Object {
            "[$($_.Architecture)] $($_.DisplayName)"
        }) -join $Separator

        Write-Output "Remediation completed but unsupported .NET remains: $RemainingList"
        exit 1
    }
    else {
        $SupportedFinal = $FinalInstalls | Where-Object {
            $_.IsSupported -eq $true
        } | Sort-Object Architecture, Pattern, Version, DisplayName

        $SupportedList = ($SupportedFinal | ForEach-Object {
            "[$($_.Architecture)] $($_.DisplayName)"
        }) -join $Separator

        Write-Output "Remediation completed. Supported .NET installed: $SupportedList"
        exit 0
    }
}
catch {
    Write-Output "Remediation error: $($_.Exception.Message)"
    exit 1
}
