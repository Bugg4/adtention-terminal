#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_file() {
  [ -f "$1" ] || fail "missing file: $1"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "expected output to contain: $needle"$'\n'"actual: $haystack" ;;
  esac
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

platform_asset_name() {
  local os arch ext
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  ext=""

  case "$os" in
    darwin) os="darwin" ;;
    linux) os="linux" ;;
    mingw*|msys*|cygwin*) os="windows"; ext=".exe" ;;
    *) fail "unsupported test OS: $os" ;;
  esac

  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) fail "unsupported test architecture: $arch" ;;
  esac

  printf 'adtention-terminal-%s-%s%s\n' "$os" "$arch" "$ext"
}

cargo build --quiet --locked --manifest-path "$ROOT/client/Cargo.toml"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

release_dir="$tmp/release"
install_root="$tmp/install"
runtime_root="$tmp/runtime"
asset_name="$(platform_asset_name)"
runtime_asset="adtention-terminal-runtime.tar.gz"

mkdir -p "$release_dir" "$install_root/bin" "$install_root/scripts" "$runtime_root/scripts" "$runtime_root/bin"

printf 'old binary\n' >"$install_root/bin/$asset_name"
printf '# old installer\n' >"$install_root/scripts/install-shell-integration.sh"

printf 'new binary from release\n' >"$release_dir/$asset_name"
chmod +x "$release_dir/$asset_name"

cat >"$runtime_root/scripts/install-shell-integration.sh" <<'SH'
#!/usr/bin/env sh
set -eu
printf 'installer ran for %s\n' "$ADTENTION_INSTALL_ROOT" >>"$ADTENTION_UPDATE_TEST_INSTALL_LOG"
SH
chmod +x "$runtime_root/scripts/install-shell-integration.sh"
printf 'new runtime launcher\n' >"$runtime_root/bin/adtention-terminal"
chmod +x "$runtime_root/bin/adtention-terminal"
printf 'new readme\n' >"$runtime_root/README.md"

(
  cd "$runtime_root"
  tar -czf "$release_dir/$runtime_asset" scripts bin README.md
)

{
  printf '%s  %s\n' "$(sha256_file "$release_dir/$asset_name")" "$asset_name"
  printf '%s  %s\n' "$(sha256_file "$release_dir/$runtime_asset")" "$runtime_asset"
} >"$release_dir/SHA256SUMS"

release_url_asset="file://$release_dir/$asset_name"
release_url_runtime="file://$release_dir/$runtime_asset"
release_url_sums="file://$release_dir/SHA256SUMS"
cat >"$release_dir/latest.json" <<JSON
{
  "tag_name": "v9.9.9",
  "assets": [
    { "name": "$asset_name", "browser_download_url": "$release_url_asset" },
    { "name": "$runtime_asset", "browser_download_url": "$release_url_runtime" },
    { "name": "SHA256SUMS", "browser_download_url": "$release_url_sums" }
  ]
}
JSON

install_log="$tmp/install.log"
output="$(
  ADTENTION_INSTALL_ROOT="$install_root" \
  ADTENTION_UPDATE_API="file://$release_dir/latest.json" \
  ADTENTION_UPDATE_TEST_INSTALL_LOG="$install_log" \
    "$ROOT/client/target/debug/adtention-terminal" update
)"

assert_contains "$output" "updated to v9.9.9"
assert_contains "$(cat "$install_root/bin/$asset_name")" "new binary from release"
assert_contains "$(cat "$install_root/bin/adtention-terminal")" "new runtime launcher"
assert_contains "$(cat "$install_root/README.md")" "new readme"
assert_file "$install_root/bin/SHA256SUMS"
assert_contains "$(cat "$install_log")" "installer ran for $install_root"

cat >"$release_dir/current.json" <<JSON
{
  "tag_name": "v9.9.9",
  "assets": []
}
JSON

up_to_date_output="$(
  ADTENTION_INSTALL_ROOT="$install_root" \
  ADTENTION_UPDATE_API="file://$release_dir/current.json" \
  ADTENTION_UPDATE_CURRENT_VERSION="9.9.9" \
    "$ROOT/client/target/debug/adtention-terminal" update
)"

assert_contains "$up_to_date_output" "already up to date"

partial_root="$tmp/partial-install"
mkdir -p "$partial_root/bin" "$partial_root/scripts"
printf 'old partial runtime\n' >"$partial_root/README.md"
cat >"$release_dir/missing-binary.json" <<JSON
{
  "tag_name": "v10.0.0",
  "assets": [
    { "name": "$runtime_asset", "browser_download_url": "$release_url_runtime" },
    { "name": "SHA256SUMS", "browser_download_url": "$release_url_sums" }
  ]
}
JSON

set +e
ADTENTION_INSTALL_ROOT="$partial_root" \
ADTENTION_UPDATE_API="file://$release_dir/missing-binary.json" \
  "$ROOT/client/target/debug/adtention-terminal" update >"$tmp/update-missing.out" 2>&1
status="$?"
set -e

[ "$status" -ne 0 ] || fail "update should fail when the platform binary is missing"
assert_contains "$(cat "$partial_root/README.md")" "old partial runtime"

printf 'update_test.sh: ok\n'
