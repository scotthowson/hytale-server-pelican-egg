#!/bin/sh
set -eu

# ============================================================================
# CLEAR JAVA_TOOL_OPTIONS IMMEDIATELY
# ============================================================================
# GraalVM images set JAVA_TOOL_OPTIONS which adds extra JVM modules.
# This MUST be cleared at the very start, before any Java commands run,
# otherwise AOT cache generation and runtime will have mismatched modules.
# ============================================================================
unset JAVA_TOOL_OPTIONS 2>/dev/null || true
export JAVA_TOOL_OPTIONS=""

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
SERVER_DIR="${SERVER_DIR:-/home/container/Server}"

# Ensure /tmp is writable for Java temp files
if [ ! -d "/tmp" ] || [ ! -w "/tmp" ]; then
  mkdir -p "${DATA_DIR}/tmp" 2>/dev/null || true
  export TMPDIR="${DATA_DIR}/tmp"
  export JAVA_OPTS="${JAVA_OPTS:-} -Djava.io.tmpdir=${DATA_DIR}/tmp"
fi

# ============================================================================
# PELICAN PANEL VARIABLE MAPPING
# ============================================================================
normalize_memory() {
  val="$1"
  case "${val}" in
    ""|0) return 1 ;;
  esac
  case "${val}" in
    *[Gg]) printf '%s' "${val}" ;;
    *[Mm]) printf '%s' "${val}" ;;
    *[0-9]) printf '%sM' "${val}" ;;
    *) printf '%s' "${val}" ;;
  esac
}

if [ -n "${HYTALE_JVM_XMS:-}" ] && [ -z "${JVM_XMS:-}" ]; then
  normalized="$(normalize_memory "${HYTALE_JVM_XMS}")" && JVM_XMS="${normalized}" && export JVM_XMS
fi

if [ -n "${HYTALE_JVM_XMX:-}" ] && [ -z "${JVM_XMX:-}" ]; then
  normalized="$(normalize_memory "${HYTALE_JVM_XMX}")" && JVM_XMX="${normalized}" && export JVM_XMX
fi

if [ -n "${HYTALE_JVM_ARGS:-}" ] && [ -z "${JVM_EXTRA_ARGS:-}" ]; then
  JVM_EXTRA_ARGS="${HYTALE_JVM_ARGS}"
  export JVM_EXTRA_ARGS
fi

if [ -n "${HYTALE_USE_AOT:-}" ] && [ -z "${ENABLE_AOT:-}" ]; then
  ENABLE_AOT="${HYTALE_USE_AOT}"
  export ENABLE_AOT
fi

if [ -n "${HYTALE_PORT:-}" ] && [ -z "${HYTALE_BIND:-}" ]; then
  HYTALE_BIND="0.0.0.0:${HYTALE_PORT}"
  export HYTALE_BIND
fi

if [ -n "${HYTALE_BACKUP_RETENTION_COUNT:-}" ] && [ -z "${HYTALE_BACKUP_MAX_COUNT:-}" ]; then
  HYTALE_BACKUP_MAX_COUNT="${HYTALE_BACKUP_RETENTION_COUNT}"
  export HYTALE_BACKUP_MAX_COUNT
fi

if [ -n "${HYTALE_ALLOW_SELF_OP:-}" ] && [ -z "${HYTALE_ALLOW_OP:-}" ]; then
  HYTALE_ALLOW_OP="${HYTALE_ALLOW_SELF_OP}"
  export HYTALE_ALLOW_OP
fi

# ============================================================================
# MACHINE ID / HARDWARE UUID SETUP
# ============================================================================
setup_machine_id() {
  MACHINE_ID_PERSISTENT="${DATA_DIR}/.machine-id"
  HARDWARE_UUID_PERSISTENT="${DATA_DIR}/.hardware-uuid"
  MACHINE_ID_FILE_ETC="/etc/machine-id"
  MACHINE_ID_FILE_DBUS="/var/lib/dbus/machine-id"
  
  machine_id=""
  
  if [ -n "${HYTALE_MACHINE_ID:-}" ]; then
    machine_id="${HYTALE_MACHINE_ID}"
    log "Using HYTALE_MACHINE_ID from environment"
  fi
  
  if [ -z "${machine_id}" ] && [ -f "${MACHINE_ID_PERSISTENT}" ]; then
    machine_id="$(cat "${MACHINE_ID_PERSISTENT}" 2>/dev/null | tr -d '[:space:]' || true)"
    if [ "${#machine_id}" -eq 32 ]; then
      log "Loaded persistent machine-id from ${MACHINE_ID_PERSISTENT}"
    else
      machine_id=""
    fi
  fi
  
  if [ -z "${machine_id}" ] || [ "${#machine_id}" -ne 32 ]; then
    if command -v uuidgen >/dev/null 2>&1; then
      machine_id="$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]')"
    else
      machine_id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | tr '[:upper:]' '[:lower:]' || true)"
    fi
    log "Generated new machine-id"
  fi
  
  if [ -z "${machine_id}" ] || [ "${#machine_id}" -ne 32 ]; then
    log "ERROR: Failed to generate a valid 32-character machine-id"
    exit 1
  fi
  
  hardware_uuid="$(printf '%s-%s-%s-%s-%s' \
    "$(printf '%s' "${machine_id}" | cut -c1-8 | tr '[:lower:]' '[:upper:]')" \
    "$(printf '%s' "${machine_id}" | cut -c9-12 | tr '[:lower:]' '[:upper:]')" \
    "$(printf '%s' "${machine_id}" | cut -c13-16 | tr '[:lower:]' '[:upper:]')" \
    "$(printf '%s' "${machine_id}" | cut -c17-20 | tr '[:lower:]' '[:upper:]')" \
    "$(printf '%s' "${machine_id}" | cut -c21-32 | tr '[:lower:]' '[:upper:]')")"
  
  wrote_persistent=0
  if ( printf '%s\n' "${machine_id}" > "${MACHINE_ID_PERSISTENT}" ) >/dev/null 2>&1; then
    chmod 644 "${MACHINE_ID_PERSISTENT}" 2>/dev/null || true
    wrote_persistent=1
  fi
  
  if ( printf '%s\n' "${hardware_uuid}" > "${HARDWARE_UUID_PERSISTENT}" ) >/dev/null 2>&1; then
    chmod 644 "${HARDWARE_UUID_PERSISTENT}" 2>/dev/null || true
  fi
  
  wrote_etc=0
  if ( printf '%s\n' "${machine_id}" > "${MACHINE_ID_FILE_ETC}" ) >/dev/null 2>&1; then
    wrote_etc=1
  fi
  ( printf '%s\n' "${machine_id}" > "${MACHINE_ID_FILE_DBUS}" ) >/dev/null 2>&1 || true
  
  if [ "${wrote_persistent}" -eq 1 ]; then
    log "Machine-ID persisted to ${MACHINE_ID_PERSISTENT}"
  elif [ "${wrote_etc}" -eq 1 ]; then
    log "Machine-ID written to ${MACHINE_ID_FILE_ETC}"
  else
    log "WARNING: Could not persist machine-id to writable storage"
  fi
  
  export HYTALE_RUNTIME_MACHINE_ID="${machine_id}"
  export HYTALE_HARDWARE_UUID="${hardware_uuid}"
}

setup_machine_id

# Auto-load server tokens
HYTALE_SERVER_TOKENS_FILE="${HYTALE_SERVER_TOKENS_FILE:-${DATA_DIR}/.hytale-server-tokens}"
if [ -f "${HYTALE_SERVER_TOKENS_FILE}" ]; then
  if [ -z "${HYTALE_SERVER_SESSION_TOKEN:-}" ]; then
    HYTALE_SERVER_SESSION_TOKEN="$(grep '^session_token=' "${HYTALE_SERVER_TOKENS_FILE}" 2>/dev/null | cut -d= -f2- || true)"
    export HYTALE_SERVER_SESSION_TOKEN
  fi
  if [ -z "${HYTALE_SERVER_IDENTITY_TOKEN:-}" ]; then
    HYTALE_SERVER_IDENTITY_TOKEN="$(grep '^identity_token=' "${HYTALE_SERVER_TOKENS_FILE}" 2>/dev/null | cut -d= -f2- || true)"
    export HYTALE_SERVER_IDENTITY_TOKEN
  fi
  if [ -n "${HYTALE_SERVER_SESSION_TOKEN}" ] && [ -n "${HYTALE_SERVER_IDENTITY_TOKEN}" ]; then
    log "Auto-loaded server authentication tokens"
  fi
fi

check_data_writable() {
  if [ ! -w "${DATA_DIR}" ]; then
    log "ERROR: Cannot write to ${DATA_DIR}"
    exit 1
  fi
}

check_dir_writable() {
  dir="$1"
  if [ ! -w "${dir}" ]; then
    log "ERROR: Cannot write to ${dir}"
    exit 1
  fi
}

check_data_writable

HYTALE_SERVER_JAR="${HYTALE_SERVER_JAR:-${SERVER_DIR}/HytaleServer.jar}"
HYTALE_ASSETS_PATH="${HYTALE_ASSETS_PATH:-${DATA_DIR}/Assets.zip}"
HYTALE_AOT_PATH="${HYTALE_AOT_PATH:-${SERVER_DIR}/HytaleServer.aot}"

HYTALE_BIND="${HYTALE_BIND:-0.0.0.0:5520}"
HYTALE_AUTH_MODE="${HYTALE_AUTH_MODE:-authenticated}"
HYTALE_DISABLE_SENTRY="${HYTALE_DISABLE_SENTRY:-false}"
HYTALE_ACCEPT_EARLY_PLUGINS="${HYTALE_ACCEPT_EARLY_PLUGINS:-false}"
HYTALE_ENABLE_BACKUP="${HYTALE_ENABLE_BACKUP:-false}"
HYTALE_BACKUP_MAX_COUNT="${HYTALE_BACKUP_MAX_COUNT:-}"
HYTALE_ALLOW_OP="${HYTALE_ALLOW_OP:-false}"
HYTALE_BARE="${HYTALE_BARE:-false}"
HYTALE_BOOT_COMMAND="${HYTALE_BOOT_COMMAND:-}"
HYTALE_DISABLE_ASSET_COMPARE="${HYTALE_DISABLE_ASSET_COMPARE:-false}"
HYTALE_DISABLE_CPB_BUILD="${HYTALE_DISABLE_CPB_BUILD:-false}"
HYTALE_DISABLE_FILE_WATCHER="${HYTALE_DISABLE_FILE_WATCHER:-false}"
HYTALE_EARLY_PLUGINS_PATH="${HYTALE_EARLY_PLUGINS_PATH:-}"
HYTALE_EVENT_DEBUG="${HYTALE_EVENT_DEBUG:-false}"
HYTALE_FORCE_NETWORK_FLUSH="${HYTALE_FORCE_NETWORK_FLUSH:-}"
HYTALE_GENERATE_SCHEMA="${HYTALE_GENERATE_SCHEMA:-false}"
HYTALE_LOG="${HYTALE_LOG:-}"
HYTALE_MODS_PATH="${HYTALE_MODS_PATH:-}"
HYTALE_OWNER_NAME="${HYTALE_OWNER_NAME:-}"
HYTALE_OWNER_UUID="${HYTALE_OWNER_UUID:-}"
HYTALE_PREFAB_CACHE_PATH="${HYTALE_PREFAB_CACHE_PATH:-}"
HYTALE_SHUTDOWN_AFTER_VALIDATE="${HYTALE_SHUTDOWN_AFTER_VALIDATE:-false}"
HYTALE_SINGLEPLAYER="${HYTALE_SINGLEPLAYER:-false}"
HYTALE_TRANSPORT="${HYTALE_TRANSPORT:-}"
HYTALE_UNIVERSE_PATH="${HYTALE_UNIVERSE_PATH:-}"
HYTALE_VALIDATE_ASSETS="${HYTALE_VALIDATE_ASSETS:-false}"
HYTALE_VALIDATE_PREFABS="${HYTALE_VALIDATE_PREFABS:-}"
HYTALE_VALIDATE_WORLD_GEN="${HYTALE_VALIDATE_WORLD_GEN:-false}"
HYTALE_WORLD_GEN_PATH="${HYTALE_WORLD_GEN_PATH:-}"
HYTALE_AUTO_DOWNLOAD="${HYTALE_AUTO_DOWNLOAD:-false}"
HYTALE_AUTO_UPDATE="${HYTALE_AUTO_UPDATE:-true}"
HYTALE_CONSOLE_PIPE="${HYTALE_CONSOLE_PIPE:-true}"
HYTALE_JAVA_TERMINAL_PROPS="${HYTALE_JAVA_TERMINAL_PROPS:-true}"
HYTALE_CURSEFORGE_MODS="${HYTALE_CURSEFORGE_MODS:-}"

ENABLE_AOT="${ENABLE_AOT:-auto}"
HYTALE_AOT_AUTO_GENERATE="${HYTALE_AOT_AUTO_GENERATE:-true}"

user_args="$*"

mkdir -p "${SERVER_DIR}"
check_dir_writable "${SERVER_DIR}"

log "Hytale Server Docker Image by Hybrowse"
log "GitHub: https://github.com/scotthowson/hytale-server-pelican"
log ""

# Handle auto-download
if is_true "${HYTALE_AUTO_DOWNLOAD}"; then
  log "Auto-download: enabled"
fi

missing=0
if [ ! -f "${HYTALE_SERVER_JAR}" ]; then
  missing=1
fi
if [ ! -f "${HYTALE_ASSETS_PATH}" ]; then
  missing=1
fi

if is_true "${HYTALE_AUTO_DOWNLOAD}"; then
  if [ "${missing}" -ne 0 ] || is_true "${HYTALE_AUTO_UPDATE}"; then
    /usr/local/bin/hytale-auto-download || true
    
    missing=0
    [ -f "${HYTALE_SERVER_JAR}" ] || missing=1
    [ -f "${HYTALE_ASSETS_PATH}" ] || missing=1
  fi
fi

if [ "${missing}" -ne 0 ]; then
  log "ERROR: Missing server files"
  log "  Expected: ${HYTALE_SERVER_JAR}"
  log "  Expected: ${HYTALE_ASSETS_PATH}"
  log "Set HYTALE_AUTO_DOWNLOAD=true for automatic download"
  exit 1
fi

# CurseForge mods
if [ -n "${HYTALE_CURSEFORGE_MODS:-}" ]; then
  if [ -z "${HYTALE_MODS_PATH:-}" ]; then
    HYTALE_MODS_PATH="${SERVER_DIR}/mods-curseforge"
  fi
  mkdir -p "${HYTALE_MODS_PATH}"
  /usr/local/bin/hytale-curseforge-mods || true
fi

export DATA_DIR SERVER_DIR

/usr/local/bin/hytale-prestart-downloads || true
/usr/local/bin/hytale-cfg-interpolate || true

log "Starting Hytale dedicated server"
log "- Assets: ${HYTALE_ASSETS_PATH}"
log "- Bind: ${HYTALE_BIND}"
log "- Auth mode: ${HYTALE_AUTH_MODE}"

if is_true "${HYTALE_ENABLE_BACKUP}"; then
  HYTALE_BACKUP_DIR="${HYTALE_BACKUP_DIR:-${DATA_DIR}/backups}"
  mkdir -p "${HYTALE_BACKUP_DIR}"
  log "- Backup: enabled (${HYTALE_BACKUP_DIR})"
fi

[ -n "${JVM_XMS:-}" ] && log "- JVM_XMS: ${JVM_XMS}"
[ -n "${JVM_XMX:-}" ] && log "- JVM_XMX: ${JVM_XMX}"
[ -n "${HYTALE_SERVER_SESSION_TOKEN:-}" ] && log "- Session token: [set]"
[ -n "${HYTALE_SERVER_IDENTITY_TOKEN:-}" ] && log "- Identity token: [set]"

# ============================================================================
# AOT CACHE HANDLING
# ============================================================================
validate_aot_cache() {
  aot_file="$1"
  [ -f "${aot_file}" ] || return 1
  
  # Test the cache - if Java can load it without errors, it's valid
  if java -XX:AOTCache="${aot_file}" -XX:AOTMode=auto -version 2>&1 | grep -q "error.*aot"; then
    return 1
  fi
  return 0
}

generate_aot_cache() {
  log "- AOT: generating cache (1-2 minutes)..."
  
  aot_log="${DATA_DIR}/.aot-generation.log"
  cd "${SERVER_DIR}"
  
  # Use same JVM args as runtime
  java_mem="${JVM_XMX:-4G}"
  
  java --enable-native-access=ALL-UNNAMED \
    -Xmx${java_mem} \
    -XX:AOTCacheOutput="${HYTALE_AOT_PATH}" \
    -jar "${HYTALE_SERVER_JAR}" \
    --assets "${HYTALE_ASSETS_PATH}" \
    --bare \
    --validate-assets \
    --shutdown-after-validate \
    > "${aot_log}" 2>&1 || true
  
  # Check for success
  if [ -f "${HYTALE_AOT_PATH}" ]; then
    aot_size="$(wc -c < "${HYTALE_AOT_PATH}" 2>/dev/null | tr -d ' ')"
    if [ "${aot_size:-0}" -gt 1000000 ]; then
      log "- AOT: cache generated (${aot_size} bytes)"
      rm -f "${aot_log}" 2>/dev/null
      return 0
    fi
  fi
  
  log "- AOT: generation failed"
  [ -f "${aot_log}" ] && tail -5 "${aot_log}" | while read -r line; do log "  ${line}"; done
  rm -f "${aot_log}" 2>/dev/null
  return 1
}

aot_enabled=0

case "$(lower "${ENABLE_AOT}")" in
  auto|"")
    if [ -f "${HYTALE_AOT_PATH}" ]; then
      if validate_aot_cache "${HYTALE_AOT_PATH}"; then
        log "- AOT: enabled (cache valid)"
        aot_enabled=1
      else
        log "- AOT: cache incompatible, removing"
        rm -f "${HYTALE_AOT_PATH}" 2>/dev/null || true
        if is_true "${HYTALE_AOT_AUTO_GENERATE}"; then
          generate_aot_cache && aot_enabled=1
        fi
      fi
    else
      if is_true "${HYTALE_AOT_AUTO_GENERATE}"; then
        generate_aot_cache && aot_enabled=1
      else
        log "- AOT: disabled (no cache)"
      fi
    fi
    ;;
  true|1|yes|on)
    if [ -f "${HYTALE_AOT_PATH}" ] && validate_aot_cache "${HYTALE_AOT_PATH}"; then
      log "- AOT: enabled"
      aot_enabled=1
    else
      log "ERROR: AOT enabled but cache invalid/missing"
      exit 1
    fi
    ;;
  false|0|no|off)
    log "- AOT: disabled"
    ;;
esac

# ============================================================================
# BUILD JAVA COMMAND
# ============================================================================
set -- java
set -- "$@" "--enable-native-access=ALL-UNNAMED"

[ -n "${JVM_XMS:-}" ] && set -- "$@" "-Xms${JVM_XMS}"
[ -n "${JVM_XMX:-}" ] && set -- "$@" "-Xmx${JVM_XMX}"
[ -n "${TZ:-}" ] && set -- "$@" "-Duser.timezone=${TZ}"

# Hardware UUID properties
if [ -n "${HYTALE_RUNTIME_MACHINE_ID:-}" ]; then
  set -- "$@" "-Dmachine.id=${HYTALE_RUNTIME_MACHINE_ID}"
  set -- "$@" "-Djna.platform.uuid=${HYTALE_RUNTIME_MACHINE_ID}"
fi
if [ -n "${HYTALE_HARDWARE_UUID:-}" ]; then
  set -- "$@" "-Dhardware.uuid=${HYTALE_HARDWARE_UUID}"
  set -- "$@" "-Dsystem.uuid=${HYTALE_HARDWARE_UUID}"
fi

# AOT cache
if [ "${aot_enabled}" -eq 1 ] && [ -f "${HYTALE_AOT_PATH}" ]; then
  set -- "$@" "-XX:AOTCache=${HYTALE_AOT_PATH}" "-XX:AOTMode=auto"
fi

# Terminal properties
if is_true "${HYTALE_JAVA_TERMINAL_PROPS}"; then
  set -- "$@" "-Dterminal.jline=${JVM_TERMINAL_JLINE:-false}"
  set -- "$@" "-Dterminal.ansi=${JVM_TERMINAL_ANSI:-true}"
fi

# Extra JVM args
[ -n "${JVM_EXTRA_ARGS:-}" ] && set -- "$@" ${JVM_EXTRA_ARGS}

# Server jar and args
set -- "$@" -jar "${HYTALE_SERVER_JAR}" --assets "${HYTALE_ASSETS_PATH}"
[ -n "${HYTALE_BIND}" ] && set -- "$@" --bind "${HYTALE_BIND}"
[ -n "${HYTALE_AUTH_MODE}" ] && set -- "$@" --auth-mode "${HYTALE_AUTH_MODE}"

is_true "${HYTALE_DISABLE_SENTRY}" && set -- "$@" --disable-sentry
is_true "${HYTALE_ACCEPT_EARLY_PLUGINS}" && set -- "$@" --accept-early-plugins
is_true "${HYTALE_ENABLE_BACKUP}" && set -- "$@" --backup
[ -n "${HYTALE_BACKUP_DIR:-}" ] && set -- "$@" --backup-dir "${HYTALE_BACKUP_DIR}"
[ -n "${HYTALE_BACKUP_FREQUENCY_MINUTES:-}" ] && set -- "$@" --backup-frequency "${HYTALE_BACKUP_FREQUENCY_MINUTES}"
[ -n "${HYTALE_BACKUP_MAX_COUNT:-}" ] && set -- "$@" --backup-max-count "${HYTALE_BACKUP_MAX_COUNT}"
is_true "${HYTALE_ALLOW_OP}" && set -- "$@" --allow-op
is_true "${HYTALE_BARE}" && set -- "$@" --bare
[ -n "${HYTALE_BOOT_COMMAND:-}" ] && set -- "$@" --boot-command "${HYTALE_BOOT_COMMAND}"
is_true "${HYTALE_DISABLE_ASSET_COMPARE}" && set -- "$@" --disable-asset-compare
is_true "${HYTALE_DISABLE_CPB_BUILD}" && set -- "$@" --disable-cpb-build
is_true "${HYTALE_DISABLE_FILE_WATCHER}" && set -- "$@" --disable-file-watcher
[ -n "${HYTALE_EARLY_PLUGINS_PATH:-}" ] && set -- "$@" --early-plugins "${HYTALE_EARLY_PLUGINS_PATH}"
is_true "${HYTALE_EVENT_DEBUG}" && set -- "$@" --event-debug
[ -n "${HYTALE_FORCE_NETWORK_FLUSH:-}" ] && set -- "$@" --force-network-flush "${HYTALE_FORCE_NETWORK_FLUSH}"
is_true "${HYTALE_GENERATE_SCHEMA}" && set -- "$@" --generate-schema
[ -n "${HYTALE_LOG:-}" ] && set -- "$@" --log "${HYTALE_LOG}"
[ -n "${HYTALE_MODS_PATH:-}" ] && set -- "$@" --mods "${HYTALE_MODS_PATH}"
[ -n "${HYTALE_OWNER_NAME:-}" ] && set -- "$@" --owner-name "${HYTALE_OWNER_NAME}"
[ -n "${HYTALE_OWNER_UUID:-}" ] && set -- "$@" --owner-uuid "${HYTALE_OWNER_UUID}"
[ -n "${HYTALE_PREFAB_CACHE_PATH:-}" ] && set -- "$@" --prefab-cache "${HYTALE_PREFAB_CACHE_PATH}"
is_true "${HYTALE_SHUTDOWN_AFTER_VALIDATE}" && set -- "$@" --shutdown-after-validate
is_true "${HYTALE_SINGLEPLAYER}" && set -- "$@" --singleplayer
[ -n "${HYTALE_TRANSPORT:-}" ] && set -- "$@" --transport "${HYTALE_TRANSPORT}"
[ -n "${HYTALE_UNIVERSE_PATH:-}" ] && set -- "$@" --universe "${HYTALE_UNIVERSE_PATH}"
is_true "${HYTALE_VALIDATE_ASSETS}" && set -- "$@" --validate-assets
is_true "${HYTALE_VALIDATE_WORLD_GEN}" && set -- "$@" --validate-world-gen
[ -n "${HYTALE_WORLD_GEN_PATH:-}" ] && set -- "$@" --world-gen "${HYTALE_WORLD_GEN_PATH}"
[ -n "${EXTRA_SERVER_ARGS:-}" ] && set -- "$@" ${EXTRA_SERVER_ARGS}
[ -n "${user_args}" ] && set -- "$@" ${user_args}
[ -n "${HYTALE_SERVER_SESSION_TOKEN:-}" ] && set -- "$@" --session-token "${HYTALE_SERVER_SESSION_TOKEN}"
[ -n "${HYTALE_SERVER_IDENTITY_TOKEN:-}" ] && set -- "$@" --identity-token "${HYTALE_SERVER_IDENTITY_TOKEN}"

# Console FIFO
if is_true "${HYTALE_CONSOLE_PIPE}"; then
  CONSOLE_FIFO="${HYTALE_CONSOLE_FIFO:-/tmp/hytale-console.fifo}"
  rm -f "${CONSOLE_FIFO}" 2>/dev/null || true
  mkfifo "${CONSOLE_FIFO}" 2>/dev/null || true
  chmod 0600 "${CONSOLE_FIFO}" 2>/dev/null || true
  
  exec 4<&0
  exec 3<> "${CONSOLE_FIFO}"
  ( while IFS= read -r line <&4; do printf '%s\n' "${line}" >&3; done ) &
  cd "${SERVER_DIR}"
  exec "$@" <&3
fi

cd "${SERVER_DIR}"
exec "$@"