#!/bin/sh
set -eu

lower() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

is_true() {
  case "$(lower "${1:-}")" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

log() {
  printf '%s\n' "$*" >&2
}

DATA_DIR="${DATA_DIR:-/home/container}"
SERVER_DIR="${SERVER_DIR:-/home/container/server}"

cfg_interpolation_enabled() {
  if ! is_true "${HYTALE_CFG_INTERPOLATION:-true}"; then
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    log "WARNING: Config interpolation is enabled but 'jq' is missing; skipping CFG_* interpolation"
    return 1
  fi

  env | grep -q '^CFG_'
}

cfg_interpolation_mode() {
  lower "${HYTALE_CFG_INTERPOLATION_MODE:-server-only}"
}

cfg_resolve_path() {
  p="${1:-}"
  if [ -z "${p}" ]; then
    return 1
  fi
  case "${p}" in
    /*) printf '%s\n' "${p}" ;;
    *) printf '%s\n' "${SERVER_DIR}/${p}" ;;
  esac
}

cfg_path_is_excluded() {
  file="$1"

  if [ -z "${HYTALE_CFG_INTERPOLATION_EXCLUDE_PATHS:-}" ]; then
    return 1
  fi

  printf '%s\n' "${HYTALE_CFG_INTERPOLATION_EXCLUDE_PATHS}" | tr ' ' '\n' | while IFS= read -r pat; do
    [ -n "${pat}" ] || continue
    case "${file}" in
      ${pat}) exit 0 ;;
    esac
  done

  return 1
}

cfg_file_has_placeholders() {
  file="$1"
  if [ ! -f "${file}" ]; then
    return 1
  fi
  grep -q -e '\${CFG_' -e '\$CFG_' "${file}" 2>/dev/null
}

cfg_file_too_large() {
  file="$1"
  max_bytes="${HYTALE_CFG_INTERPOLATION_MAX_BYTES:-}"

  if [ -z "${max_bytes}" ]; then
    return 1
  fi
  case "${max_bytes}" in
    0) return 1 ;;
    *[!0-9]*) return 1 ;;
  esac

  size="$(wc -c <"${file}" 2>/dev/null | tr -d ' ' || echo 0)"
  case "${size}" in
    *[!0-9]*) size=0 ;;
  esac

  [ "${size}" -gt "${max_bytes}" ]
}

cfg_interpolate_file() {
  file="$1"

  if [ ! -f "${file}" ]; then
    return 0
  fi

  if cfg_path_is_excluded "${file}"; then
    return 0
  fi

  if cfg_file_too_large "${file}"; then
    log "Config interpolation: skipping large JSON file: ${file}"
    return 0
  fi

  if ! cfg_file_has_placeholders "${file}"; then
    return 0
  fi

  tmp="${file}.tmp.$$"
  rm -f "${tmp}" 2>/dev/null || true

  if jq -e '
    def walk(f):
      . as $in
      | if type == "object" then
          reduce keys_unsorted[] as $key
            ({}; . + { ($key): ($in[$key] | walk(f)) })
          | f
        elif type == "array" then
          map(walk(f))
          | f
        else
          f
        end;

    def cfg_env:
      env
      | to_entries
      | map(select(.key | startswith("CFG_")))
      | from_entries;

    def parse_or_string($s):
      try ($s | fromjson) catch $s;

    def safe_repl($s):
      ($s | tostring | gsub("\\\\"; "\\\\\\\\"));

    def interp_string($cfg; $s):
      reduce ($cfg | to_entries[]) as $e ({v: $s, done: false};
        if .done or (.v | type) != "string" then
          .
        else
          if .v == ("${" + $e.key + "}") or .v == ("$" + $e.key) then
            {v: (parse_or_string($e.value)), done: true}
          else
            {v: (.v
              | gsub(("\\$\\{" + $e.key + "\\}"); safe_repl($e.value))
              | gsub(("\\$" + $e.key + "(?![A-Za-z0-9_])"); safe_repl($e.value))
            ), done: false}
          end
        end
      )
      | .v;

    (cfg_env) as $cfg
    | if ($cfg | length) == 0 then
        .
      else
        walk(
          if type == "string" then
            interp_string($cfg; .)
          else
            .
          end
        )
      end
  ' "${file}" >"${tmp}" 2>/dev/null; then
    mv "${tmp}" "${file}"
  else
    rm -f "${tmp}" 2>/dev/null || true
    log "WARNING: Config interpolation failed for JSON file: ${file}"
  fi
}

cfg_interpolate_paths() {
  if ! cfg_interpolation_enabled; then
    return 0
  fi

  log "Config interpolation: applying CFG_* variables to JSON config files"

  mode="$(cfg_interpolation_mode)"

  cfg_interpolate_file "${SERVER_DIR}/config.json"

  case "${mode}" in
    all|server-only|explicit) ;;
    *)
      log "WARNING: Unknown HYTALE_CFG_INTERPOLATION_MODE=${mode}; using 'server-only'"
      mode="server-only"
      ;;
  esac

  if [ "${mode}" = "server-only" ]; then
    return 0
  fi

  if [ "${mode}" = "explicit" ]; then
    if [ -n "${HYTALE_CFG_INTERPOLATION_PATHS:-}" ]; then
      printf '%s\n' "${HYTALE_CFG_INTERPOLATION_PATHS}" | tr ' ' '\n' | while IFS= read -r p; do
        [ -n "${p}" ] || continue
        resolved="$(cfg_resolve_path "${p}" 2>/dev/null || true)"
        [ -n "${resolved}" ] || continue

        if [ -d "${resolved}" ]; then
          find "${resolved}" -type f -name '*.json' 2>/dev/null | while IFS= read -r f; do
            cfg_interpolate_file "${f}"
          done
        else
          cfg_interpolate_file "${resolved}"
        fi
      done
    fi
    return 0
  fi

  if [ -d "${SERVER_DIR}/mods" ]; then
    find "${SERVER_DIR}/mods" -type f -name '*.json' 2>/dev/null | while IFS= read -r f; do
      cfg_interpolate_file "${f}"
    done
  fi

  if [ -n "${HYTALE_MODS_PATH:-}" ] && [ -d "${HYTALE_MODS_PATH}" ]; then
    find "${HYTALE_MODS_PATH}" -type f -name '*.json' 2>/dev/null | while IFS= read -r f; do
      cfg_interpolate_file "${f}"
    done
  fi
}

cfg_interpolate_paths
