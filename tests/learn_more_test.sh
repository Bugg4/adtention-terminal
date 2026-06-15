#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/client/target/debug/adtention-terminal"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cargo build --manifest-path "$ROOT/client/Cargo.toml" >/dev/null

tmp="$(mktemp -d "${TMPDIR:-/tmp}/adtention-learn-more-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

cache="$tmp/cache"
mkdir -p "$cache"
printf 'https://example.com/sponsor\n' >"$cache/current_click.txt"

cat >"$tmp/fake-open" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >"$ADTENTION_OPEN_LOG"
SH
chmod +x "$tmp/fake-open"

ADTENTION_CACHE="$cache" \
ADTENTION_OPEN_COMMAND="$tmp/fake-open" \
ADTENTION_OPEN_LOG="$tmp/open.log" \
  "$BIN" learn-more >/tmp/adtention-learn-more.out

grep -Fq 'https://example.com/sponsor' "$tmp/open.log" || fail "learn-more did not open cached sponsor URL"
grep -Fq 'opened the sponsor' /tmp/adtention-learn-more.out || fail "learn-more did not report success"

printf 'learn_more_test.sh: ok\n'

