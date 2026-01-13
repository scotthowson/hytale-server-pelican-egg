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

DATA_DIR="${DATA_DIR:-/data}"
SERVER_DIR="${SERVER_DIR:-/data/server}"

HYTALE_SERVER_JAR="${HYTALE_SERVER_JAR:-${SERVER_DIR}/HytaleServer.jar}"
HYTALE_ASSETS_PATH="${HYTALE_ASSETS_PATH:-${DATA_DIR}/Assets.zip}"

HYTALE_DOWNLOADER_URL="${HYTALE_DOWNLOADER_URL:-https://downloader.hytale.com/hytale-downloader.zip}"
HYTALE_DOWNLOADER_DIR="${HYTALE_DOWNLOADER_DIR:-${DATA_DIR}/.hytale-downloader}"
HYTALE_GAME_ZIP_PATH="${HYTALE_GAME_ZIP_PATH:-${DATA_DIR}/game.zip}"
HYTALE_DOWNLOADER_PATCHLINE="${HYTALE_DOWNLOADER_PATCHLINE:-}"
HYTALE_DOWNLOADER_SKIP_UPDATE_CHECK="${HYTALE_DOWNLOADER_SKIP_UPDATE_CHECK:-false}"
HYTALE_DOWNLOADER_CREDENTIALS_SRC="${HYTALE_DOWNLOADER_CREDENTIALS_SRC:-}"
HYTALE_KEEP_GAME_ZIP="${HYTALE_KEEP_GAME_ZIP:-false}"
HYTALE_DOWNLOAD_LOCK="${HYTALE_DOWNLOAD_LOCK:-true}"
HYTALE_AUTO_UPDATE="${HYTALE_AUTO_UPDATE:-true}"

mkdir -p "${SERVER_DIR}"
mkdir -p "${HYTALE_DOWNLOADER_DIR}"

# Lock to avoid multiple containers downloading into the same volume simultaneously.
LOCK_DIR="${DATA_DIR}/.hytale-download-lock"
LOCK_CREATED_AT_PATH="${LOCK_DIR}/created_at_epoch"
LOCK_TTL_SECONDS=300

lock_acquired=0

cleanup() {
  if [ "${lock_acquired}" -eq 1 ]; then
    rm -rf "${LOCK_DIR}" 2>/dev/null || true
  fi
}

if is_true "${HYTALE_DOWNLOAD_LOCK}"; then
  trap cleanup EXIT INT TERM

  for _i in 1 2 3 4 5 6 7 8 9 10; do
    if mkdir "${LOCK_DIR}" 2>/dev/null; then
      lock_acquired=1
      now_epoch="$(date +%s 2>/dev/null || echo 0)"
      printf '%s\n' "${now_epoch}" >"${LOCK_CREATED_AT_PATH}" 2>/dev/null || true
      printf '%s\n' "$$" >"${LOCK_DIR}/pid" 2>/dev/null || true
      break
    fi

    if [ -f "${LOCK_CREATED_AT_PATH}" ]; then
      created_epoch="$(cat "${LOCK_CREATED_AT_PATH}" 2>/dev/null || echo 0)"
      now_epoch="$(date +%s 2>/dev/null || echo 0)"
      if [ "${created_epoch}" -gt 0 ] && [ $((now_epoch - created_epoch)) -ge "${LOCK_TTL_SECONDS}" ]; then
        log "Auto-download: stale lock detected at ${LOCK_DIR} (older than ${LOCK_TTL_SECONDS}s); removing"
        rm -rf "${LOCK_DIR}" 2>/dev/null || true
        continue
      fi
    fi

    log "Auto-download: another container may be downloading into ${DATA_DIR}; waiting for lock (${LOCK_DIR})"
    log "Auto-download: if this gets stuck, delete ${LOCK_DIR} or set HYTALE_DOWNLOAD_LOCK=false (power users)"
    sleep 3
  done

  if [ "${lock_acquired}" -ne 1 ]; then
    log "ERROR: Auto-download: could not acquire lock ${LOCK_DIR}"
    log "ERROR: If no other container is running, the lock may be stale. You can delete ${LOCK_DIR} and try again."
    log "ERROR: Power users can disable the lock with HYTALE_DOWNLOAD_LOCK=false (risk: concurrent downloads may corrupt /data)."
    exit 1
  fi
else
  log "Auto-download: download lock disabled via HYTALE_DOWNLOAD_LOCK=false"
fi

if [ -f "${HYTALE_SERVER_JAR}" ] && [ -f "${HYTALE_ASSETS_PATH}" ]; then
  if ! is_true "${HYTALE_AUTO_UPDATE}"; then
    log "Auto-download: server files already present; skipping"
    exit 0
  fi
  log "Auto-download: server files already present; checking for updates"
fi

case "${HYTALE_DOWNLOADER_URL}" in
  https://downloader.hytale.com/*) ;;
  *)
    log "ERROR: HYTALE_DOWNLOADER_URL must start with https://downloader.hytale.com/"
    exit 1
    ;;
esac

ZIP_PATH="${HYTALE_DOWNLOADER_DIR}/hytale-downloader.zip"
arch="$(uname -m)"
case "${arch}" in
  x86_64|amd64)
    bin_name="hytale-downloader-linux-amd64"
    ;;
  aarch64|arm64)
    log "ERROR: Auto-download is not supported on arm64 because the official downloader archive does not include a linux-arm64 binary."
    log "ERROR: Please provide server files and Assets.zip manually on arm64."
    exit 1
    ;;
  *)
    log "ERROR: Unsupported architecture for downloader in container: ${arch}"
    exit 1
    ;;
esac

DOWNLOADER_BIN="${HYTALE_DOWNLOADER_DIR}/hytale-downloader"

if [ ! -x "${DOWNLOADER_BIN}" ]; then
  log "Auto-download: downloading official Hytale Downloader"
  curl -fsSL "${HYTALE_DOWNLOADER_URL}" -o "${ZIP_PATH}"

  if ! unzip -p "${ZIP_PATH}" "${bin_name}" >"${DOWNLOADER_BIN}" 2>/dev/null; then
    log "ERROR: Could not find ${bin_name} in official downloader archive"
    exit 1
  fi

  chmod 0755 "${DOWNLOADER_BIN}"
else
  log "Auto-download: reusing existing downloader binary"
fi

log "Auto-download: running downloader"
log "Auto-download: first-time auth may require opening a URL and entering a device code (see logs)"

# Persist downloader credentials on the /data volume by running in DATA_DIR.
cd "${DATA_DIR}"

if [ -n "${HYTALE_DOWNLOADER_CREDENTIALS_SRC}" ]; then
  if [ ! -f "${HYTALE_DOWNLOADER_CREDENTIALS_SRC}" ]; then
    log "ERROR: HYTALE_DOWNLOADER_CREDENTIALS_SRC is set but file does not exist: ${HYTALE_DOWNLOADER_CREDENTIALS_SRC}"
    exit 1
  fi

  log "Auto-download: seeding downloader credentials from mounted file"
  cp -f "${HYTALE_DOWNLOADER_CREDENTIALS_SRC}" "${DATA_DIR}/.hytale-downloader-credentials.json"
fi

set -- "${DOWNLOADER_BIN}" -download-path "${HYTALE_GAME_ZIP_PATH}"

if [ -n "${HYTALE_DOWNLOADER_PATCHLINE}" ]; then
  set -- "$@" -patchline "${HYTALE_DOWNLOADER_PATCHLINE}"
fi

if is_true "${HYTALE_DOWNLOADER_SKIP_UPDATE_CHECK}"; then
  set -- "$@" -skip-update-check
fi

"$@"

if [ ! -f "${HYTALE_GAME_ZIP_PATH}" ]; then
  log "ERROR: Auto-download: expected download zip not found: ${HYTALE_GAME_ZIP_PATH}"
  exit 1
fi

log "Auto-download: extracting Assets.zip and Server/ from game package"

unzip -o "${HYTALE_GAME_ZIP_PATH}" 'Assets.zip' -d "${DATA_DIR}" >/dev/null
tmp_extract_dir="$(mktemp -d /tmp/hytale-server-extract.XXXXXX 2>/dev/null || mktemp -d)"
unzip -o "${HYTALE_GAME_ZIP_PATH}" 'Server/*' -d "${tmp_extract_dir}" >/dev/null

if [ -d "${tmp_extract_dir}/Server" ]; then
  mkdir -p "${SERVER_DIR}"
  cp -a "${tmp_extract_dir}/Server/." "${SERVER_DIR}/"
fi

rm -rf "${tmp_extract_dir}" 2>/dev/null || true

if [ ! -f "${HYTALE_ASSETS_PATH}" ]; then
  log "ERROR: Auto-download: Assets.zip not found after extraction at ${HYTALE_ASSETS_PATH}"
  exit 1
fi

if [ ! -f "${HYTALE_SERVER_JAR}" ]; then
  log "ERROR: Auto-download: HytaleServer.jar not found after extraction at ${HYTALE_SERVER_JAR}"
  exit 1
fi

if ! is_true "${HYTALE_KEEP_GAME_ZIP}"; then
  rm -f "${HYTALE_GAME_ZIP_PATH}" || true
fi

log "Auto-download: done"
