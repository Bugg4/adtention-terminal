#!/usr/bin/env sh
set -eu

START_MARKER="# >>> adtention-terminal >>>"
END_MARKER="# <<< adtention-terminal <<<"
LEGACY_CODEX_START_MARKER="# >>> ADtention Codex >>>"
LEGACY_CODEX_END_MARKER="# <<< ADtention Codex <<<"

default_profiles() {
  if [ -n "${ADTENTION_PROFILE:-}" ]; then
    printf '%s\n' "$ADTENTION_PROFILE"
    return
  fi

  printf '%s/.zshrc\n' "$HOME"
  printf '%s/.bashrc\n' "$HOME"
}

remove_managed_block() {
  profile="$1"
  tmp="${profile}.adtention.$$"

  [ -f "$profile" ] || return 0
  awk \
    -v start="$START_MARKER" \
    -v end="$END_MARKER" \
    -v legacy_start="$LEGACY_CODEX_START_MARKER" \
    -v legacy_end="$LEGACY_CODEX_END_MARKER" '
    $0 == start || $0 == legacy_start { skip = 1; next }
    $0 == end || $0 == legacy_end { skip = 0; next }
    skip != 1 { print }
  ' "$profile" >"$tmp"
  mv "$tmp" "$profile"
}

install_root="${ADTENTION_INSTALL_ROOT:-}"
default_profiles | while IFS= read -r profile; do
  [ -n "$profile" ] || continue
  remove_managed_block "$profile"
  printf 'ADtention Terminal shell integration removed from %s\n' "$profile"
done

if [ -n "$install_root" ]; then
  :
fi
