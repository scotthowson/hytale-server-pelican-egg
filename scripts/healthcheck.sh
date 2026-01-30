#!/bin/sh
set -eu

log() {
  printf '%s\n' "$*" >&2
}

lower() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

is_true() {
  case "$(lower "${1:-}")" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

if is_true "${HYTALE_HEALTHCHECK_DISABLED:-false}"; then
  exit 0
fi

DATA_DIR="${DATA_DIR:-/home/container}"
# Use consistent path - capital S to match entrypoint
SERVER_DIR="${SERVER_DIR:-${DATA_DIR}/Server}"

HYTALE_SERVER_JAR="${HYTALE_SERVER_JAR:-${SERVER_DIR}/HytaleServer.jar}"
HYTALE_ASSETS_PATH="${HYTALE_ASSETS_PATH:-${DATA_DIR}/Assets.zip}"

if is_true "${HYTALE_HEALTHCHECK_REQUIRE_FILES:-true}"; then
  if [ ! -f "${HYTALE_SERVER_JAR}" ]; then
    log "Healthcheck: missing server jar: ${HYTALE_SERVER_JAR}"
    exit 1
  fi

  if [ ! -f "${HYTALE_ASSETS_PATH}" ]; then
    log "Healthcheck: missing assets: ${HYTALE_ASSETS_PATH}"
    exit 1
  fi
fi

if is_true "${HYTALE_HEALTHCHECK_REQUIRE_PROCESS:-true}"; then
  found=0
  for f in /proc/[0-9]*/cmdline; do
    if [ ! -r "${f}" ]; then
      continue
    fi
    cmdline="$(tr '\\000' ' ' < "${f}" 2>/dev/null || true)"
    case "${cmdline}" in
      *HytaleServer.jar*)
        found=1
        break
        ;;
      *)
        ;;
    esac
  done

  if [ "${found}" -ne 1 ]; then
    log "Healthcheck: server process not detected"
    exit 1
  fi
fi

if is_true "${HYTALE_HEALTHCHECK_SKIP_PORT:-false}"; then
  exit 0
fi

bind="${HYTALE_BIND:-0.0.0.0:5520}"
port="${HYTALE_HEALTHCHECK_PORT:-${bind##*:}}"

case "${port}" in
  ""|*[!0-9]*)
    log "Healthcheck: invalid port: ${port}"
    exit 1
    ;;
  *)
    ;;
esac

port_hex="$(printf '%04x' "${port}")"

check_udp_port() {
  proc_file="$1"

  if [ ! -r "${proc_file}" ]; then
    return 1
  fi

  grep -i -E "[0-9a-f]{8,32}:${port_hex}[[:space:]]" "${proc_file}" 2>/dev/null | grep -q -E "[[:space:]]07[[:space:]]" 2>/dev/null
}

if check_udp_port /proc/net/udp || check_udp_port /proc/net/udp6; then
  exit 0
fi

log "Healthcheck: UDP port not listening: ${port}"
exit 1
