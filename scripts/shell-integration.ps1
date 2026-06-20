# ADtention Terminal PowerShell integration.
# This file is intended to be dot-sourced from a PowerShell profile.

function Get-AdtentionCache {
    if ($env:ADTENTION_CACHE -and -not (Test-AdtentionBuiltInCache $env:ADTENTION_CACHE)) {
        return $env:ADTENTION_CACHE
    }

    $claudeCache = Join-Path $HOME ".claude/adtention"
    if (Test-Path -LiteralPath $claudeCache) {
        return $claudeCache
    }

    return (Join-Path $HOME ".adtention")
}

function Test-AdtentionBuiltInCache {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Cache
    )

    return @(
        (Join-Path $HOME ".adtention"),
        (Join-Path $HOME ".claude/adtention"),
        (Join-Path $HOME ".codex/adtention")
    ) -contains $Cache
}

function Test-AdtentionShouldTriggerEnter {
    param(
        [AllowNull()]
        [string] $CommandText
    )

    if ([string]::IsNullOrWhiteSpace($CommandText)) {
        return $false
    }

    $trimmed = $CommandText.Trim()
    if ($trimmed.StartsWith("#")) {
        return $false
    }

    $firstToken = ($trimmed -split '\s+', 2)[0].Trim('"', "'")
    $commandName = Split-Path -Leaf $firstToken
    $ownCommands = @(
        "adtention-open",
        "adtention-open.exe",
        "adtention-refresh",
        "adtention-refresh.exe",
        "adtention-terminal",
        "adtention-terminal.exe",
        "learn-more"
    )

    return $ownCommands -notcontains $commandName
}

function Add-AdtentionLearnMoreHint {
    param(
        [AllowEmptyString()]
        [string] $Ad
    )

    if ($Ad.EndsWith(" -> learn-more")) {
        return $Ad
    }

    return "$Ad -> learn-more"
}

function Limit-AdtentionPromptLine {
    param(
        [AllowEmptyString()]
        [string] $Line
    )

    [int] $maxWidth = 120
    if ($env:ADTENTION_MAX_WIDTH) {
        $parsedWidth = 0
        if ([int]::TryParse($env:ADTENTION_MAX_WIDTH, [ref] $parsedWidth)) {
            $maxWidth = $parsedWidth
        }
    } elseif ($Host.UI.RawUI.BufferSize.Width -gt 0) {
        $maxWidth = $Host.UI.RawUI.BufferSize.Width
    }

    if ($Line.Length -gt $maxWidth -and $maxWidth -gt 3) {
        return $Line.Substring(0, $maxWidth - 3) + "..."
    }

    return $Line
}

function Get-AdtentionCachedPromptLine {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Cache
    )

    $balanceFile = Join-Path $Cache "balance_display"
    $adFile = Join-Path $Cache "current_ad.txt"
    if ((Test-Path -LiteralPath $balanceFile) -or (Test-Path -LiteralPath $adFile)) {
        $balance = ""
        $ad = ""
        try {
            $balance = [string] (Get-Content -LiteralPath $balanceFile -TotalCount 1 -ErrorAction SilentlyContinue)
        } catch {
        }
        try {
            $ad = [string] (Get-Content -LiteralPath $adFile -TotalCount 1 -ErrorAction SilentlyContinue)
        } catch {
        }

        if (-not $balance) {
            $balance = '⊕ $0.00'
        }

        if ($ad) {
            return Limit-AdtentionPromptLine "$balance  $(Add-AdtentionLearnMoreHint $ad)"
        }

        return Limit-AdtentionPromptLine $balance
    }

    $terminalFile = Join-Path $Cache "terminal.txt"
    if (-not (Test-Path -LiteralPath $terminalFile)) {
        return ""
    }

    $rows = @(Get-Content -LiteralPath $terminalFile -TotalCount 2 -ErrorAction SilentlyContinue)
    if ($rows.Count -ge 2) {
        return [string] $rows[1]
    }

    return ""
}

function New-AdtentionEnterEvent {
    param(
        [Parameter(Mandatory = $true)]
        [string] $CommandText,

        [string] $Cwd = (Get-Location).ProviderPath
    )

    [ordered] @{
        source = "terminal-enter"
        shell = "powershell"
        command = $CommandText
        cwd = $Cwd
    }
}

function ConvertTo-AdtentionJson {
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        $Event
    )

    process {
        $Event | ConvertTo-Json -Compress -Depth 6
    }
}

function Get-AdtentionCurrentLine {
    [string] $line = ""
    [int] $cursor = 0

    try {
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref] $line, [ref] $cursor)
        return $line
    } catch {
        return ""
    }
}

function Start-AdtentionRefreshJob {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Json,

        [Parameter(Mandatory = $true)]
        [string] $Cwd
    )

    $binary = if ($env:ADTENTION_BINARY) { $env:ADTENTION_BINARY } else { "adtention-terminal" }

    try {
        Start-Job -Name "adtention-terminal-refresh" -ArgumentList $binary, $Cwd, $Json -ScriptBlock {
            param(
                [string] $Binary,
                [string] $WorkingDirectory,
                [string] $Payload
            )

            try {
                $Payload | & $Binary refresh $WorkingDirectory *> $null
            } catch {
            }
        } | Out-Null
    } catch {
    }
}

function Start-AdtentionUpdateJob {
    if ($env:ADTENTION_AUTO_UPDATE -eq "0") {
        return
    }

    $binary = if ($env:ADTENTION_BINARY) { $env:ADTENTION_BINARY } else { "adtention-terminal" }

    try {
        Start-Job -Name "adtention-terminal-update" -ArgumentList $binary -ScriptBlock {
            param(
                [string] $Binary
            )

            try {
                & $Binary update *> $null
            } catch {
            }
        } | Out-Null
    } catch {
    }
}

function Invoke-AdtentionEnterRefresh {
    $commandText = Get-AdtentionCurrentLine
    if (-not (Test-AdtentionShouldTriggerEnter $commandText)) {
        return
    }

    $cwd = (Get-Location).ProviderPath
    if ([string]::IsNullOrWhiteSpace($cwd)) {
        $cwd = (Get-Location).Path
    }

    $event = New-AdtentionEnterEvent -CommandText $commandText -Cwd $cwd
    $json = ConvertTo-AdtentionJson $event
    Start-AdtentionRefreshJob -Json $json -Cwd $cwd
}

function Invoke-AdtentionPromptDisplay {
    $cache = Get-AdtentionCache
    $line = Get-AdtentionCachedPromptLine -Cache $cache
    if (-not $line) { return }

    try {
        New-Item -ItemType Directory -Force -Path $cache | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $cache "last_render_seen"),
            [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString(),
            [System.Text.Encoding]::ASCII
        )
    } catch {
    }

    if ($line -and $env:ADTENTION_PROMPT_LINE -ne "0") {
        Write-Host $line
    }
}

function Enable-AdtentionPowerShellIntegration {
    if ($env:ADTENTION_DISABLE_KEYBINDING -eq "1") {
        return
    }

    if (-not (Get-Command Set-PSReadLineKeyHandler -ErrorAction SilentlyContinue)) {
        return
    }

    try {
        $null = [Microsoft.PowerShell.PSConsoleReadLine]
    } catch {
        return
    }

    try {
        Set-PSReadLineKeyHandler -Key Enter -ScriptBlock {
            param($key, $arg)

            try {
                Invoke-AdtentionEnterRefresh
            } catch {
            }

            [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
        }
    } catch {
    }
}

function Enable-AdtentionPromptDisplay {
    if (-not $Global:AdtentionTerminalOriginalPrompt) {
        $Global:AdtentionTerminalOriginalPrompt = if (Test-Path Function:\prompt) {
            (Get-Command prompt).ScriptBlock
        } else {
            { "PS $($executionContext.SessionState.Path.CurrentLocation)> " }
        }
    }

    function global:prompt {
        Invoke-AdtentionPromptDisplay
        & $Global:AdtentionTerminalOriginalPrompt
    }
}

Start-AdtentionUpdateJob
Enable-AdtentionPromptDisplay
Enable-AdtentionPowerShellIntegration

function global:learn-more {
    & adtention-terminal learn-more @args
}
