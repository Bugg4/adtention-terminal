#!/usr/bin/env sh
set -eu

START_MARKER="# >>> adtention-terminal >>>"
END_MARKER="# <<< adtention-terminal <<<"
LEGACY_CODEX_START_MARKER="# >>> ADtention Codex >>>"
LEGACY_CODEX_END_MARKER="# <<< ADtention Codex <<<"

script_dir() {
  cd "$(dirname "$0")" >/dev/null 2>&1 && pwd
}

default_install_root() {
  if [ -n "${ADTENTION_INSTALL_ROOT:-}" ]; then
    printf '%s\n' "$ADTENTION_INSTALL_ROOT"
    return
  fi

  cd "$(script_dir)/.." >/dev/null 2>&1 && pwd
}

shared_cache_default() {
  if [ -d "$HOME/.claude/adtention" ] || [ -f "$HOME/.claude/adtention/identity.json" ]; then
    printf '%s/.claude/adtention\n' "$HOME"
  else
    printf '%s/.adtention\n' "$HOME"
  fi
}

cache_override() {
  [ -n "${ADTENTION_CACHE:-}" ] || return 0

  case "$ADTENTION_CACHE" in
    "$HOME/.adtention"|"$HOME/.claude/adtention"|"$HOME/.codex/adtention")
      return 0
      ;;
  esac

  printf '%s\n' "$ADTENTION_CACHE"
}

default_cache() {
  override="$(cache_override || true)"
  if [ -n "$override" ]; then
    printf '%s\n' "$override"
  else
    shared_cache_default
  fi
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

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

  [ -f "$profile" ] || : >"$profile"
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

write_managed_block() {
  profile="$1"
  install_root="$2"
  cache_override_value="$3"

  {
    printf '%s\n' "$START_MARKER"
    printf 'export ADTENTION_INSTALL_ROOT='
    shell_quote "$install_root"
    printf '\n'
    if [ -n "$cache_override_value" ]; then
      printf 'export ADTENTION_CACHE='
      shell_quote "$cache_override_value"
      printf '\n'
    fi
    printf 'case ":$PATH:" in\n'
    printf '  *":$ADTENTION_INSTALL_ROOT/bin:"*) ;;\n'
    printf '  *) export PATH="$ADTENTION_INSTALL_ROOT/bin:$PATH" ;;\n'
    printf 'esac\n'
    printf '# Diagnostic: if refreshes do not appear, run: adtention-terminal doctor\n'
    printf 'if [ -n "${ZSH_VERSION:-}" ] && [ -r "$ADTENTION_INSTALL_ROOT/scripts/shell-integration.zsh" ]; then\n'
    printf '  . "$ADTENTION_INSTALL_ROOT/scripts/shell-integration.zsh"\n'
    printf 'elif [ -n "${BASH_VERSION:-}" ] && [ -r "$ADTENTION_INSTALL_ROOT/scripts/shell-integration.bash" ]; then\n'
    printf '  . "$ADTENTION_INSTALL_ROOT/scripts/shell-integration.bash"\n'
    printf 'fi\n'
    printf '%s\n' "$END_MARKER"
  } >>"$profile"
}

file_age_seconds() {
  file="$1"
  [ -f "$file" ] || {
    printf 'missing\n'
    return
  }

  mtime="$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null || true)"
  if [ -z "$mtime" ]; then
    printf 'unknown\n'
    return
  fi

  now="$(date +%s)"
  printf '%ss\n' "$((now - mtime))"
}

migrate_legacy_cache() {
  cache="$1"

  for legacy in "$HOME/.codex/adtention" "$HOME/.adtention/terminal" "$HOME/.adtention"; do
    [ "$legacy" != "$cache" ] || continue
    [ -d "$legacy" ] || continue
    mkdir -p "$cache"
    for file in identity.json balance balance_display current_ad.txt current_click.txt title.txt prompt_line.txt terminal.txt category.txt source.txt ref; do
      [ -e "$legacy/$file" ] || continue
      [ ! -e "$cache/$file" ] || continue
      cp -p "$legacy/$file" "$cache/$file" 2>/dev/null || cp "$legacy/$file" "$cache/$file" 2>/dev/null || true
    done
  done
}

diagnose() {
  cache="$(default_cache)"

  default_profiles | while IFS= read -r profile; do
    [ -n "$profile" ] || continue
    printf 'profile: %s\n' "$profile"
    if [ -f "$profile" ] && grep -Fq "$START_MARKER" "$profile"; then
      printf 'integration: installed\n'
    else
      printf 'integration: missing\n'
    fi
  done

  if command -v adtention-terminal >/dev/null 2>&1; then
    printf 'client: found (%s)\n' "$(command -v adtention-terminal)"
  else
    printf 'client: missing\n'
  fi

  printf 'cache: %s\n' "$cache"
  printf 'last render age: %s\n' "$(file_age_seconds "$cache/last_render_seen")"
  printf 'last serve age: %s\n' "$(file_age_seconds "$cache/last_serve")"

  if [ -s "$cache/last_skipped" ]; then
    printf 'last skipped reason: recorded\n'
  else
    printf 'last skipped reason: missing\n'
  fi
}

install_integration() {
  install_root="$(default_install_root)"
  cache="$(default_cache)"
  cache_override_value="$(cache_override || true)"

  mkdir -p "$cache"
  migrate_legacy_cache "$cache"
  default_profiles | while IFS= read -r profile; do
    [ -n "$profile" ] || continue
    mkdir -p "$(dirname "$profile")"
    remove_managed_block "$profile"
    write_managed_block "$profile" "$install_root" "$cache_override_value"
    printf 'ADtention Terminal shell integration installed in %s\n' "$profile"
  done
}

case "${1:-}" in
  --diagnose)
    diagnose
    ;;
  -h|--help)
    printf 'usage: install-shell-integration.sh [--diagnose]\n'
    ;;
  "")
    install_integration
    ;;
  *)
    printf 'unknown option: %s\n' "$1" >&2
    printf 'usage: install-shell-integration.sh [--diagnose]\n' >&2
    exit 2
    ;;
esac
