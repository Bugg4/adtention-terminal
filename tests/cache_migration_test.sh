#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/client/target/debug/adtention-terminal"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "$file should contain: $text"
}

cargo build --manifest-path "$ROOT/client/Cargo.toml" >/dev/null

tmp="$(mktemp -d "${TMPDIR:-/tmp}/adtention-cache-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

test_setup_uses_claude_cache_when_present() {
  local home="$tmp/home-claude"
  mkdir -p "$home/.claude/adtention"

  env -u ADTENTION_CACHE HOME="$home" "$BIN" setup

  [[ -f "$home/.claude/adtention/terminal.txt" ]] || fail "setup did not use existing Claude cache"
  [[ ! -e "$home/.adtention/terminal.txt" ]] || fail "setup created ~/.adtention even though Claude cache exists"
}

test_setup_uses_shared_cache_for_new_installs() {
  local home="$tmp/home-shared"
  mkdir -p "$home"

  env -u ADTENTION_CACHE HOME="$home" "$BIN" setup

  [[ -f "$home/.adtention/terminal.txt" ]] || fail "setup did not use ~/.adtention for new installs"
}

test_setup_migrates_legacy_codex_without_overwriting_identity() {
  local home="$tmp/home-legacy"
  mkdir -p "$home/.codex/adtention" "$home/.adtention"
  printf '{"publisher_id":"pub_legacy"}' >"$home/.codex/adtention/identity.json"
  printf '⊕ $4.20' >"$home/.codex/adtention/balance_display"
  printf '{"publisher_id":"pub_existing"}' >"$home/.adtention/identity.json"

  env -u ADTENTION_CACHE HOME="$home" "$BIN" setup

  assert_contains "$home/.adtention/identity.json" "pub_existing"
  assert_contains "$home/.adtention/balance_display" '⊕ $4.20'
}

test_installer_migrates_legacy_codex_without_overwriting_identity() {
  local home="$tmp/home-installer"
  mkdir -p "$home/.codex/adtention" "$home/.adtention"
  printf '{"publisher_id":"pub_legacy"}' >"$home/.codex/adtention/identity.json"
  printf '⊕ $8.88' >"$home/.codex/adtention/balance_display"
  printf '{"publisher_id":"pub_existing"}' >"$home/.adtention/identity.json"

  env -u ADTENTION_CACHE HOME="$home" "$ROOT/scripts/install-shell-integration.sh" >/dev/null

  assert_contains "$home/.adtention/identity.json" "pub_existing"
  assert_contains "$home/.adtention/balance_display" '⊕ $8.88'
  assert_contains "$home/.zshrc" "$home/.adtention"
}

test_setup_uses_claude_cache_when_present
test_setup_uses_shared_cache_for_new_installs
test_setup_migrates_legacy_codex_without_overwriting_identity
test_installer_migrates_legacy_codex_without_overwriting_identity

printf 'cache_migration_test.sh: ok\n'
