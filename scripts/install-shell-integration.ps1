param(
    [switch] $Diagnose
)

$ErrorActionPreference = "Stop"

$StartMarker = "# >>> adtention-terminal >>>"
$EndMarker = "# <<< adtention-terminal <<<"

function Get-AdtentionInstallRoot {
    if ($env:ADTENTION_INSTALL_ROOT) {
        return $env:ADTENTION_INSTALL_ROOT
    }

    return (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

function Get-AdtentionCache {
    if ($env:ADTENTION_CACHE) {
        return $env:ADTENTION_CACHE
    }

    return (Join-Path $HOME ".adtention/terminal")
}

function Get-AdtentionPowerShellProfile {
    if ($env:ADTENTION_PS_PROFILE) {
        return $env:ADTENTION_PS_PROFILE
    }

    if ($PROFILE.CurrentUserAllHosts) {
        return $PROFILE.CurrentUserAllHosts
    }

    return [string] $PROFILE
}

function ConvertTo-AdtentionSingleQuotedLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    return "'" + $Value.Replace("'", "''") + "'"
}

function Remove-AdtentionManagedBlock {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProfilePath
    )

    if (-not (Test-Path -LiteralPath $ProfilePath)) {
        return @()
    }

    $output = [System.Collections.Generic.List[string]]::new()
    $skip = $false
    foreach ($line in Get-Content -LiteralPath $ProfilePath) {
        if ($line -eq $StartMarker) {
            $skip = $true
            continue
        }

        if ($line -eq $EndMarker) {
            $skip = $false
            continue
        }

        if (-not $skip) {
            $output.Add($line)
        }
    }

    return $output
}

function Get-AdtentionManagedBlock {
    param(
        [Parameter(Mandatory = $true)]
        [string] $InstallRoot,

        [Parameter(Mandatory = $true)]
        [string] $Cache
    )

    $rootLiteral = ConvertTo-AdtentionSingleQuotedLiteral $InstallRoot
    $cacheLiteral = ConvertTo-AdtentionSingleQuotedLiteral $Cache

    return @(
        $StartMarker,
        "`$env:ADTENTION_INSTALL_ROOT = $rootLiteral",
        "`$env:ADTENTION_CACHE = $cacheLiteral",
        "# Diagnostic: if refreshes do not appear, run: adtention-terminal doctor",
        "`$adtentionIntegration = Join-Path `$env:ADTENTION_INSTALL_ROOT 'scripts/shell-integration.ps1'",
        "if (Test-Path -LiteralPath `$adtentionIntegration) {",
        "    . `$adtentionIntegration",
        "}",
        $EndMarker
    )
}

function Get-AdtentionFileAge {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return "missing"
    }

    $item = Get-Item -LiteralPath $Path
    $age = [int] ((Get-Date) - $item.LastWriteTime).TotalSeconds
    return "${age}s"
}

function Invoke-AdtentionDiagnose {
    $profilePath = Get-AdtentionPowerShellProfile
    $cache = Get-AdtentionCache

    Write-Output "profile: $profilePath"
    if ((Test-Path -LiteralPath $profilePath) -and (Select-String -LiteralPath $profilePath -SimpleMatch $StartMarker -Quiet)) {
        Write-Output "integration: installed"
    } else {
        Write-Output "integration: missing"
    }

    $client = Get-Command adtention-terminal -ErrorAction SilentlyContinue
    if ($client) {
        Write-Output "client: found ($($client.Source))"
    } else {
        Write-Output "client: missing"
    }

    Write-Output "cache: $cache"
    Write-Output "last render age: $(Get-AdtentionFileAge (Join-Path $cache 'last_render_seen'))"
    Write-Output "last serve age: $(Get-AdtentionFileAge (Join-Path $cache 'last_serve'))"

    $reasonPath = Join-Path $cache "last_skipped"
    if ((Test-Path -LiteralPath $reasonPath) -and ((Get-Item -LiteralPath $reasonPath).Length -gt 0)) {
        Write-Output "last skipped reason: recorded"
    } else {
        Write-Output "last skipped reason: missing"
    }
}

function Install-AdtentionPowerShellIntegration {
    $profilePath = Get-AdtentionPowerShellProfile
    $installRoot = Get-AdtentionInstallRoot
    $cache = Get-AdtentionCache

    $profileDir = Split-Path -Parent $profilePath
    if ($profileDir) {
        New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
    }
    New-Item -ItemType Directory -Force -Path $cache | Out-Null

    $lines = @(Remove-AdtentionManagedBlock -ProfilePath $profilePath)
    $block = Get-AdtentionManagedBlock -InstallRoot $installRoot -Cache $cache
    $newLines = $lines + $block
    Set-Content -LiteralPath $profilePath -Value $newLines -Encoding UTF8

    Write-Output "ADtention Terminal PowerShell integration installed in $profilePath"
}

if ($Diagnose) {
    Invoke-AdtentionDiagnose
    exit 0
}

# usage: install-shell-integration.ps1 [-Diagnose]
Install-AdtentionPowerShellIntegration
