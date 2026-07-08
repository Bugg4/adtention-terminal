# Bash Enter wrapping is experimental because Readline does not expose a clean
# "run this, then accept the line" hook. Enable with ADTENTION_BASH_ENTER_EXPERIMENTAL=1.

__adtention_is_builtin_cache() {
  [[ "${1-}" == "$HOME/.adtention" || "${1-}" == "$HOME/.claude/adtention" || "${1-}" == "$HOME/.codex/adtention" ]]
}

__adtention_cache_dir() {
  if [[ -n "${ADTENTION_CACHE:-}" ]] && ! __adtention_is_builtin_cache "$ADTENTION_CACHE"; then
    printf '%s\n' "$ADTENTION_CACHE"
  elif [[ -d "$HOME/.claude/adtention" || -f "$HOME/.claude/adtention/identity.json" ]]; then
    printf '%s/.claude/adtention\n' "$HOME"
  else
    printf '%s/.adtention\n' "$HOME"
  fi
}

__adtention_trim() {
  local value="${1-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

__adtention_with_learn_more_hint() {
  local ad="${1-}"
  case "$ad" in
    *" -> learn-more") printf '%s\n' "$ad" ;;
    *) printf '%s -> learn-more\n' "$ad" ;;
  esac
}

__adtention_truncate_line() {
  local line="${1-}"
  local max_width="${ADTENTION_MAX_WIDTH:-${COLUMNS:-120}}"

  case "$max_width" in
    *[!0-9]*|'') max_width=120 ;;
  esac

  if (( ${#line} > max_width && max_width > 3 )); then
    printf '%s...\n' "${line:0:$((max_width - 3))}"
  else
    printf '%s\n' "$line"
  fi
}

__adtention_cached_prompt_line() {
  local cache_dir="$1"
  local terminal_file="$cache_dir/terminal.txt"
  local balance_file="$cache_dir/balance_display"
  local ad_file="$cache_dir/current_ad.txt"
  local ignored_title line_text balance ad

  if [[ -r "$balance_file" || -r "$ad_file" ]]; then
    if [[ -r "$balance_file" ]]; then
      IFS= read -r balance <"$balance_file" || true
    fi
    if [[ -r "$ad_file" ]]; then
      IFS= read -r ad <"$ad_file" || true
    fi
    [[ -n "$balance" ]] || balance='⊕ $0.00'
    if [[ -n "$ad" ]]; then
      line_text="$balance  $(__adtention_with_learn_more_hint "$ad")"
    else
      line_text="$balance"
    fi
    __adtention_truncate_line "$line_text"
    return 0
  fi

  [[ -r "$terminal_file" ]] || return 1
  {
    IFS= read -r ignored_title || ignored_title=""
    IFS= read -r line_text || line_text=""
  } <"$terminal_file"

  [[ -n "$line_text" ]] || return 1
  printf '%s\n' "$line_text"
}

__adtention_prompt_display() {
  local cache_dir line_text now
  cache_dir="$(__adtention_cache_dir)"

  line_text="$(__adtention_cached_prompt_line "$cache_dir")" || return 0
  [[ -n "$line_text" ]] || return 0

  mkdir -p "$cache_dir" 2>/dev/null || true
  now="$(date +%s 2>/dev/null || printf '')"
  printf '%s\n' "$now" >"$cache_dir/last_render_seen" 2>/dev/null || true

  if [[ "${ADTENTION_PROMPT_LINE:-1}" != "0" && -n "$line_text" ]]; then
    printf '%s\n' "$line_text"
  fi
}

__adtention_install_prompt_display() {
  [[ $- == *i* ]] || return 0
  case ";${PROMPT_COMMAND:-};" in
    *";__adtention_prompt_display;"*) ;;
    *) PROMPT_COMMAND="__adtention_prompt_display${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
  esac
}

__adtention_should_trigger_enter() {
  local trimmed
  trimmed="$(__adtention_trim "${1-}")"

  [[ -n "$trimmed" ]] || return 1
  [[ "$trimmed" != \#* ]] || return 1

  case "$trimmed" in
    adtention-open | adtention-open[[:space:]]* | \
      adtention-refresh | adtention-refresh[[:space:]]* | \
      adtention-terminal | adtention-terminal[[:space:]]* | \
      learn-more | learn-more[[:space:]]*)
      return 1
      ;;
  esac

  return 0
}

learn-more() {
  command adtention-terminal learn-more "$@"
}

__adtention_update_async() {
  [[ "${ADTENTION_AUTO_UPDATE:-1}" != "0" ]] || return 0

  (
    command adtention-terminal update </dev/null &
  ) >/dev/null 2>&1

  return 0
}

__adtention_json_escape() {
  local value="${1-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

__adtention_build_enter_event() {
  local command_text="${1-}"
  local cwd
  local escaped_command
  local escaped_cwd

  cwd="$(pwd 2>/dev/null || printf '%s' "${PWD:-}")"
  escaped_command="$(__adtention_json_escape "$command_text")"
  escaped_cwd="$(__adtention_json_escape "$cwd")"

  printf '{"source":"terminal-enter","shell":"bash","command":"%s","cwd":"%s"}\n' \
    "$escaped_command" \
    "$escaped_cwd"
}

__adtention_enter_refresh_async() {
  local command_text="${1-}"
  local cwd

  __adtention_should_trigger_enter "$command_text" || return 0

  cwd="$(pwd 2>/dev/null || printf '%s' "${PWD:-}")"
  (
    __adtention_build_enter_event "$command_text" | command adtention-terminal refresh "$cwd" &
  ) >/dev/null 2>&1

  return 0
}

__adtention_bash_enter_hook() {
  __adtention_enter_refresh_async "${READLINE_LINE-}"
  return 0
}

__adtention_install_bash_enter_binding() {
  [[ $- == *i* ]] || return 0
  [[ "${ADTENTION_BASH_ENTER_EXPERIMENTAL:-0}" == "1" ]] || return 0

  bind -x '"\C-x\C-a": __adtention_bash_enter_hook' 2>/dev/null || return 0
  bind '"\C-m": "\C-x\C-a\C-j"' 2>/dev/null || return 0
}

__adtention_update_async
__adtention_install_prompt_display
__adtention_install_bash_enter_binding
