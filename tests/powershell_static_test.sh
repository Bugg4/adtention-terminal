#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PS_SCRIPT="$ROOT/scripts/shell-integration.ps1"
PS_INSTALL="$ROOT/install.ps1"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  [ -f "$1" ] || fail "missing file: $1"
}

assert_contains() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "$file should contain: $text"
}

assert_not_contains() {
  local file="$1"
  local text="$2"
  if grep -Fq -- "$text" "$file"; then
    fail "$file should not contain: $text"
  fi
}

assert_file "$PS_SCRIPT"
assert_file "$PS_INSTALL"
assert_contains "$PS_SCRIPT" "Set-PSReadLineKeyHandler"
assert_contains "$PS_SCRIPT" "-Key Enter"
assert_contains "$PS_SCRIPT" "[Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()"
assert_contains "$PS_SCRIPT" "[Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState"
assert_contains "$PS_SCRIPT" "Invoke-AdtentionPromptDisplay"
assert_contains "$PS_SCRIPT" "Get-AdtentionCachedPromptLine"
assert_contains "$PS_SCRIPT" "balance_display"
assert_contains "$PS_SCRIPT" "current_ad.txt"
assert_contains "$PS_SCRIPT" "last_render_seen"
assert_contains "$PS_SCRIPT" "terminal.txt"
assert_not_contains "$PS_SCRIPT" "WindowTitle"
assert_contains "$PS_SCRIPT" "function global:prompt"
assert_contains "$PS_SCRIPT" "Start-Job"
assert_contains "$PS_SCRIPT" "adtention-terminal"
assert_contains "$PS_SCRIPT" "refresh"
assert_contains "$PS_SCRIPT" "update"
assert_contains "$PS_SCRIPT" "Start-AdtentionUpdateJob"
assert_contains "$PS_SCRIPT" "ConvertTo-Json"
assert_contains "$PS_SCRIPT" "terminal-enter"
assert_contains "$PS_SCRIPT" "powershell"
assert_not_contains "$PS_SCRIPT" "codex plugin"
assert_contains "$PS_INSTALL" "adtention-terminal.exe"
assert_contains "$PS_INSTALL" "Get-FileHash"
assert_contains "$PS_INSTALL" "Invoke-WebRequest"

if command -v pwsh >/dev/null 2>&1; then
  ps_home="$(mktemp -d)"
  HOME="$ps_home" ADTENTION_PS_SCRIPT="$PS_SCRIPT" pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command '
    $ErrorActionPreference = "Stop"
    $env:ADTENTION_DISABLE_KEYBINDING = "1"
    $env:ADTENTION_AUTO_UPDATE = "0"
    . $env:ADTENTION_PS_SCRIPT

    $falseCases = @("", "   ", "# comment", "adtention-open", "adtention-refresh", "adtention-terminal refresh .", "learn-more")
    foreach ($case in $falseCases) {
      if (Test-AdtentionShouldTriggerEnter $case) {
        throw "Expected no refresh for [$case]"
      }
    }

    $trueCases = @("npm test", "Write-Host hello")
    foreach ($case in $trueCases) {
      if (-not (Test-AdtentionShouldTriggerEnter $case)) {
        throw "Expected refresh for [$case]"
      }
    }

    $event = New-AdtentionEnterEvent -CommandText "npm test" -Cwd "/tmp/project"
    if ($event.source -ne "terminal-enter") { throw "wrong source" }
    if ($event.shell -ne "powershell") { throw "wrong shell" }
    if ($event.command -ne "npm test") { throw "wrong command" }
    if ($event.cwd -ne "/tmp/project") { throw "wrong cwd" }

    $json = ConvertTo-AdtentionJson $event
    if (-not $json.Contains([char]34 + "source" + [char]34 + ":" + [char]34 + "terminal-enter" + [char]34)) { throw "missing source json" }
    if (-not $json.Contains([char]34 + "shell" + [char]34 + ":" + [char]34 + "powershell" + [char]34)) { throw "missing shell json" }

    $homePath = $HOME
    New-Item -ItemType Directory -Force -Path (Join-Path $homePath ".adtention") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $homePath ".codex/adtention") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $homePath ".claude/adtention") | Out-Null
    $env:ADTENTION_CACHE = Join-Path $homePath ".adtention"
    $resolvedCache = Get-AdtentionCache
    if ($resolvedCache -ne (Join-Path $homePath ".claude/adtention")) {
      throw "PowerShell cache resolver used stale built-in ADTENTION_CACHE: $resolvedCache"
    }

    $env:ADTENTION_CACHE = Join-Path $homePath ".codex/adtention"
    $resolvedCache = Get-AdtentionCache
    if ($resolvedCache -ne (Join-Path $homePath ".claude/adtention")) {
      throw "PowerShell cache resolver used legacy Codex ADTENTION_CACHE: $resolvedCache"
    }

    $rawCache = Join-Path $homePath ".claude/adtention"
    Set-Content -LiteralPath (Join-Path $rawCache "terminal.txt") -Value @("stale title", "⊕ `$0.00")
    Set-Content -LiteralPath (Join-Path $rawCache "balance_display") -Value "⊕ `$3.16"
    Set-Content -LiteralPath (Join-Path $rawCache "current_ad.txt") -Value "Linear: plan sprints in 5 min"
    $line = Get-AdtentionCachedPromptLine -Cache $rawCache
    if ($line -ne "⊕ `$3.16  Linear: plan sprints in 5 min -> learn-more") {
      throw "PowerShell prompt line did not use raw cache fields: $line"
    }
  '
fi

echo "powershell_static_test.sh: ok"
