#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/client/target/debug/adtention-terminal"
INSTALL_SH="$ROOT/scripts/install-shell-integration.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
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

test_setup_ignores_stale_builtin_cache_when_claude_exists() {
  local home="$tmp/home-claude-stale-env"
  mkdir -p "$home/.claude/adtention" "$home/.adtention"

  HOME="$home" ADTENTION_CACHE="$home/.adtention" "$BIN" setup

  [[ -f "$home/.claude/adtention/terminal.txt" ]] || fail "setup did not use Claude cache when stale built-in ADTENTION_CACHE was set"
  [[ ! -e "$home/.adtention/terminal.txt" ]] || fail "setup used stale built-in ADTENTION_CACHE"
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

test_setup_migrates_fallback_shared_state_to_claude_without_overwriting_identity() {
  local home="$tmp/home-fallback-to-claude"
  mkdir -p "$home/.adtention" "$home/.claude/adtention"
  printf '{"publisher_id":"pub_fallback"}' >"$home/.adtention/identity.json"
  printf '⊕ $12.34' >"$home/.adtention/balance_display"
  printf '{"publisher_id":"pub_claude"}' >"$home/.claude/adtention/identity.json"

  env -u ADTENTION_CACHE HOME="$home" "$BIN" setup

  assert_contains "$home/.claude/adtention/identity.json" "pub_claude"
  assert_contains "$home/.claude/adtention/balance_display" '⊕ $12.34'
}

test_installer_migrates_legacy_codex_without_overwriting_identity() {
  local home="$tmp/home-installer"
  mkdir -p "$home/.codex/adtention" "$home/.adtention"
  printf '{"publisher_id":"pub_legacy"}' >"$home/.codex/adtention/identity.json"
  printf '⊕ $8.88' >"$home/.codex/adtention/balance_display"
  printf '{"publisher_id":"pub_existing"}' >"$home/.adtention/identity.json"

  env -u ADTENTION_CACHE HOME="$home" "$INSTALL_SH" >/dev/null

  assert_contains "$home/.adtention/identity.json" "pub_existing"
  assert_contains "$home/.adtention/balance_display" '⊕ $8.88'
  assert_not_contains "$home/.zshrc" "export ADTENTION_CACHE="
}

test_installer_ignores_stale_builtin_cache_when_claude_exists() {
  local home="$tmp/home-stale-cache-env"
  mkdir -p "$home/.adtention" "$home/.claude/adtention"
  printf '{"publisher_id":"pub_fallback"}' >"$home/.adtention/identity.json"
  printf '⊕ $9.99' >"$home/.adtention/balance_display"
  printf '{"publisher_id":"pub_claude"}' >"$home/.claude/adtention/identity.json"

  HOME="$home" ADTENTION_CACHE="$home/.adtention" "$INSTALL_SH" >/dev/null

  assert_contains "$home/.claude/adtention/identity.json" "pub_claude"
  assert_contains "$home/.claude/adtention/balance_display" '⊕ $9.99'
  assert_not_contains "$home/.zshrc" "export ADTENTION_CACHE="
}

test_setup_uses_claude_cache_when_present
test_setup_ignores_stale_builtin_cache_when_claude_exists
test_setup_uses_shared_cache_for_new_installs
test_setup_migrates_legacy_codex_without_overwriting_identity
test_setup_migrates_fallback_shared_state_to_claude_without_overwriting_identity
test_installer_migrates_legacy_codex_without_overwriting_identity
test_installer_ignores_stale_builtin_cache_when_claude_exists

printf 'cache_migration_test.sh: ok\n'
