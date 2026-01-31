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
SERVER_DIR="${SERVER_DIR:-/home/container/Server}"

# ============================================================================
# PELICAN PANEL VARIABLE MAPPING
# ============================================================================
# Convert memory value to JVM format
# Supports: "4G", "4096M", "4096" (plain integer = MB), "0" (skip)
normalize_memory() {
  val="$1"
  # Skip if empty or zero
  case "${val}" in
    ""|0) return 1 ;;
  esac
  case "${val}" in
    *[Gg]) printf '%s' "${val}" ;;  # Already has G suffix
    *[Mm]) printf '%s' "${val}" ;;  # Already has M suffix
    *[0-9])
      # Plain integer - treat as MB
      printf '%sM' "${val}"
      ;;
    *) printf '%s' "${val}" ;;  # Unknown format, pass through
  esac
}

# JVM Min Memory - skip if 0 or empty
if [ -n "${HYTALE_JVM_XMS:-}" ] && [ -z "${JVM_XMS:-}" ]; then
  normalized="$(normalize_memory "${HYTALE_JVM_XMS}")" && JVM_XMS="${normalized}" && export JVM_XMS
fi

# JVM Max Memory
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
    log "ERROR: See https://github.com/scotthowson/hytale-server-pelican/blob/main/docs/image/troubleshooting.md"
    exit 1
  fi
}

check_dir_writable() {
  dir="$1"
  if [ ! -w "${dir}" ]; then
    log "ERROR: Cannot write to ${dir}"
    log "ERROR: Current owner: $(ls -ld "${dir}" 2>/dev/null | awk '{print $3":"$4}')"
    log "ERROR: See https://github.com/scotthowson/hytale-server-pelican/blob/main/docs/image/troubleshooting.md"
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
HYTALE_UNIVERSE_DOWNLOAD_URLS="${HYTALE_UNIVERSE_DOWNLOAD_URLS:-}"
HYTALE_MODS_DOWNLOAD_URLS="${HYTALE_MODS_DOWNLOAD_URLS:-}"

# AOT settings - default to auto which will auto-generate if missing
ENABLE_AOT="${ENABLE_AOT:-auto}"
HYTALE_AOT_AUTO_GENERATE="${HYTALE_AOT_AUTO_GENERATE:-true}"

user_args="$*"

mkdir -p "${SERVER_DIR}"
check_dir_writable "${SERVER_DIR}"

log "Thank you for using the Hytale Server Docker Image by Hybrowse!"
log "- GitHub: https://github.com/scotthowson/hytale-server-pelican"
log ""

if is_true "${HYTALE_AUTO_DOWNLOAD}"; then
  log "Auto-download: enabled"
fi

missing=0
if [ ! -f "${HYTALE_SERVER_JAR}" ]; then
  if is_true "${HYTALE_AUTO_DOWNLOAD}"; then
    log "Missing server jar: ${HYTALE_SERVER_JAR}"
  else
    log "ERROR: Missing server jar: ${HYTALE_SERVER_JAR}"
  fi
  missing=1
fi
if [ ! -f "${HYTALE_ASSETS_PATH}" ]; then
  if is_true "${HYTALE_AUTO_DOWNLOAD}"; then
    log "Missing assets: ${HYTALE_ASSETS_PATH}"
  else
    log "ERROR: Missing assets: ${HYTALE_ASSETS_PATH}"
  fi
  missing=1
fi

if is_true "${HYTALE_AUTO_DOWNLOAD}"; then
  if [ "${missing}" -ne 0 ]; then
    log "Attempting auto-download via official Hytale Downloader"
    /usr/local/bin/hytale-auto-download

    missing=0
    if [ ! -f "${HYTALE_SERVER_JAR}" ]; then
      log "ERROR: Missing server jar: ${HYTALE_SERVER_JAR}"
      missing=1
    fi
    if [ ! -f "${HYTALE_ASSETS_PATH}" ]; then
      log "ERROR: Missing assets: ${HYTALE_ASSETS_PATH}"
      missing=1
    fi
  else
    if is_true "${HYTALE_AUTO_UPDATE}"; then
      log "Attempting auto-download via official Hytale Downloader"
      /usr/local/bin/hytale-auto-download
    fi
  fi
fi

if [ "${missing}" -ne 0 ]; then
  log ""
  log "Expected volume layout:"
  log "  ${DATA_DIR}/Assets.zip"
  log "  ${SERVER_DIR}/HytaleServer.jar"
  log ""
  log "- Set HYTALE_AUTO_DOWNLOAD=true for automatic download"
  log "- See https://github.com/scotthowson/hytale-server-pelican/blob/main/docs/image/server-files.md"
  exit 1
fi

if [ -n "${HYTALE_CURSEFORGE_MODS:-}" ]; then
  if [ -z "${HYTALE_MODS_PATH:-}" ]; then
    HYTALE_MODS_PATH="${DATA_DIR}/Server/mods-curseforge"
  fi
  mkdir -p "${HYTALE_MODS_PATH}"
  check_dir_writable "${HYTALE_MODS_PATH}"
  /usr/local/bin/hytale-curseforge-mods || true
fi

export DATA_DIR SERVER_DIR

/usr/local/bin/hytale-prestart-downloads || true
/usr/local/bin/hytale-cfg-interpolate || true

log "Starting Hytale dedicated server"
log "- Assets: ${HYTALE_ASSETS_PATH}"
log "- Bind: ${HYTALE_BIND}"
log "- Auth mode: ${HYTALE_AUTH_MODE}"

if is_true "${HYTALE_DISABLE_SENTRY}"; then
  log "- Disable Sentry: enabled"
fi

if is_true "${HYTALE_ACCEPT_EARLY_PLUGINS}"; then
  log "- Accept early plugins: enabled"
fi

if is_true "${HYTALE_ENABLE_BACKUP}"; then
  if [ -z "${HYTALE_BACKUP_DIR:-}" ]; then
    HYTALE_BACKUP_DIR="${DATA_DIR}/backups"
  fi
  mkdir -p "${HYTALE_BACKUP_DIR}"
  log "- Backup: enabled"
  log "- Backup dir: ${HYTALE_BACKUP_DIR}"
fi

if [ -n "${JVM_XMS:-}" ]; then
  log "- JVM_XMS: ${JVM_XMS}"
fi

if [ -n "${JVM_XMX:-}" ]; then
  log "- JVM_XMX: ${JVM_XMX}"
fi

if [ -n "${HYTALE_SERVER_SESSION_TOKEN:-}" ]; then
  log "- Session token: [set]"
fi

if [ -n "${HYTALE_SERVER_IDENTITY_TOKEN:-}" ]; then
  log "- Identity token: [set]"
fi

# ============================================================================
# AOT CACHE HANDLING WITH AUTO-GENERATION
# ============================================================================
# The AOT cache significantly improves startup time but is tied to the JVM version.
# When the JVM updates, the cache becomes invalid and must be regenerated.
# With auto-generation enabled (default), we automatically generate the cache
# on first run or when it becomes stale.
# ============================================================================

validate_aot_cache() {
  aot_file="$1"
  if [ ! -f "${aot_file}" ]; then
    return 1
  fi
  
  # Test the cache by running java -version with it
  test_result="$(java -XX:AOTCache="${aot_file}" -XX:AOTMode=auto -Xlog:aot=error -version 2>&1)"
  
  # Check for AOT errors indicating cache incompatibility
  if printf '%s' "${test_result}" | grep -q "Unable to map shared spaces"; then
    return 1
  fi
  if printf '%s' "${test_result}" | grep -q "not the one used while building"; then
    return 1
  fi
  if printf '%s' "${test_result}" | grep -q "An error has occurred while processing the AOT cache"; then
    return 1
  fi
  
  return 0
}

generate_aot_cache() {
  log "- AOT: generating cache (this may take 1-2 minutes)..."
  
  # Create a temporary file for AOT generation output
  aot_log="${DATA_DIR}/.aot-generation.log"
  
  # AOT generation requires running the server in a special mode
  # The server runs with --bare --validate-assets --shutdown-after-validate
  # and -XX:AOTCacheOutput to create the cache file
  
  cd "${SERVER_DIR}"
  
  # Build command as an array for proper argument handling
  set -- java --enable-native-access=ALL-UNNAMED
  
  # Add memory settings if specified
  if [ -n "${JVM_XMX:-}" ]; then
    set -- "$@" "-Xmx${JVM_XMX}"
  else
    # Default to 4G for AOT generation if not specified
    set -- "$@" "-Xmx4G"
  fi
  
  # AOT cache output path
  set -- "$@" "-XX:AOTCacheOutput=${HYTALE_AOT_PATH}"
  
  # Server jar and required args
  set -- "$@" -jar "${HYTALE_SERVER_JAR}"
  set -- "$@" --assets "${HYTALE_ASSETS_PATH}"
  set -- "$@" --bare
  set -- "$@" --validate-assets
  set -- "$@" --shutdown-after-validate
  
  # Run AOT generation with output captured
  log "- AOT: running server in AOT generation mode..."
  if "$@" > "${aot_log}" 2>&1; then
    if [ -f "${HYTALE_AOT_PATH}" ]; then
      aot_size="$(wc -c < "${HYTALE_AOT_PATH}" 2>/dev/null | tr -d ' ')"
      log "- AOT: cache generated successfully (${aot_size} bytes)"
      rm -f "${aot_log}" 2>/dev/null || true
      return 0
    else
      log "- AOT: generation completed but cache file not found"
    fi
  else
    log "- AOT: generation process exited with error"
  fi
  
  # Show the last few lines of the log on failure
  if [ -f "${aot_log}" ]; then
    log "- AOT: generation output (last 10 lines):"
    tail -10 "${aot_log}" 2>/dev/null | while IFS= read -r line; do
      log "  ${line}"
    done
    rm -f "${aot_log}" 2>/dev/null || true
  fi
  
  log "- AOT: cache generation failed (server will start without AOT)"
  return 1
}

aot_enabled=0

case "$(lower "${ENABLE_AOT}")" in
  generate|create)
    # Explicit generation mode - just generate, don't start server
    log "- AOT: generating cache (explicit mode)"
    generate_aot_cache
    exit 0
    ;;
  auto|"")
    if [ -f "${HYTALE_AOT_PATH}" ]; then
      if validate_aot_cache "${HYTALE_AOT_PATH}"; then
        log "- AOT: enabled (cache valid)"
        aot_enabled=1
      else
        log "- AOT: cache incompatible with current JVM, removing"
        rm -f "${HYTALE_AOT_PATH}" 2>/dev/null || true
        
        # Auto-generate if enabled
        if is_true "${HYTALE_AOT_AUTO_GENERATE}"; then
          if generate_aot_cache; then
            aot_enabled=1
          fi
        else
          log "- AOT: disabled (set HYTALE_AOT_AUTO_GENERATE=true to auto-generate)"
        fi
      fi
    else
      # No cache exists - auto-generate if enabled
      if is_true "${HYTALE_AOT_AUTO_GENERATE}"; then
        if generate_aot_cache; then
          aot_enabled=1
        fi
      else
        log "- AOT: disabled (cache missing, set HYTALE_AOT_AUTO_GENERATE=true to auto-generate)"
      fi
    fi
    ;;
  true|1|yes|on)
    if [ -f "${HYTALE_AOT_PATH}" ]; then
      if validate_aot_cache "${HYTALE_AOT_PATH}"; then
        log "- AOT: enabled"
        aot_enabled=1
      else
        log "ERROR: ENABLE_AOT=true but AOT cache is incompatible"
        log "ERROR: Set ENABLE_AOT=auto to auto-handle, or ENABLE_AOT=generate to regenerate"
        exit 1
      fi
    else
      log "ERROR: ENABLE_AOT=true but AOT cache does not exist"
      log "ERROR: Set ENABLE_AOT=auto to auto-generate"
      exit 1
    fi
    ;;
  false|0|no|off)
    log "- AOT: disabled"
    ;;
  *)
    log "ERROR: Invalid ENABLE_AOT value: ${ENABLE_AOT}"
    exit 1
    ;;
esac

# Build Java arguments
set -- java

# Enable native access for Netty and other libraries (Java 21+)
set -- "$@" "--enable-native-access=ALL-UNNAMED"

if [ -n "${JVM_XMS:-}" ]; then
  set -- "$@" "-Xms${JVM_XMS}"
fi

if [ -n "${JVM_XMX:-}" ]; then
  set -- "$@" "-Xmx${JVM_XMX}"
fi

if [ -n "${TZ:-}" ]; then
  set -- "$@" "-Duser.timezone=${TZ}"
fi

# Hardware UUID Java properties
if [ -n "${HYTALE_RUNTIME_MACHINE_ID:-}" ]; then
  set -- "$@" "-Dmachine.id=${HYTALE_RUNTIME_MACHINE_ID}"
  set -- "$@" "-Djna.platform.uuid=${HYTALE_RUNTIME_MACHINE_ID}"
fi

if [ -n "${HYTALE_HARDWARE_UUID:-}" ]; then
  set -- "$@" "-Dhardware.uuid=${HYTALE_HARDWARE_UUID}"
  set -- "$@" "-Dsystem.uuid=${HYTALE_HARDWARE_UUID}"
  set -- "$@" "-Djna.system.uuid=${HYTALE_HARDWARE_UUID}"
  set -- "$@" "-Dcom.sun.management.jmxremote.machine.id=${HYTALE_HARDWARE_UUID}"
fi

# Add AOT cache if enabled
if [ "${aot_enabled}" -eq 1 ] && [ -f "${HYTALE_AOT_PATH}" ]; then
  set -- "$@" "-XX:AOTCache=${HYTALE_AOT_PATH}" "-XX:AOTMode=auto"
fi

if is_true "${HYTALE_JAVA_TERMINAL_PROPS}"; then
  terminal_jline="${JVM_TERMINAL_JLINE:-false}"
  terminal_ansi="${JVM_TERMINAL_ANSI:-true}"
  set -- "$@" "-Dterminal.jline=${terminal_jline}" "-Dterminal.ansi=${terminal_ansi}"
fi

if [ -n "${JVM_EXTRA_ARGS:-}" ]; then
  set -- "$@" ${JVM_EXTRA_ARGS}
fi

set -- "$@" -jar "${HYTALE_SERVER_JAR}" --assets "${HYTALE_ASSETS_PATH}"

if [ -n "${HYTALE_BIND}" ]; then
  set -- "$@" --bind "${HYTALE_BIND}"
fi

if [ -n "${HYTALE_AUTH_MODE}" ]; then
  set -- "$@" --auth-mode "${HYTALE_AUTH_MODE}"
fi

if is_true "${HYTALE_DISABLE_SENTRY}"; then
  set -- "$@" --disable-sentry
fi

if is_true "${HYTALE_ACCEPT_EARLY_PLUGINS}"; then
  set -- "$@" --accept-early-plugins
fi

if is_true "${HYTALE_ENABLE_BACKUP}"; then
  set -- "$@" --backup
fi

if [ -n "${HYTALE_BACKUP_DIR:-}" ]; then
  set -- "$@" --backup-dir "${HYTALE_BACKUP_DIR}"
fi

if [ -n "${HYTALE_BACKUP_FREQUENCY_MINUTES:-}" ]; then
  set -- "$@" --backup-frequency "${HYTALE_BACKUP_FREQUENCY_MINUTES}"
fi

if [ -n "${HYTALE_BACKUP_MAX_COUNT:-}" ]; then
  set -- "$@" --backup-max-count "${HYTALE_BACKUP_MAX_COUNT}"
fi

if is_true "${HYTALE_ALLOW_OP}"; then
  set -- "$@" --allow-op
fi

if is_true "${HYTALE_BARE}"; then
  set -- "$@" --bare
fi

if [ -n "${HYTALE_BOOT_COMMAND:-}" ]; then
  set -- "$@" --boot-command "${HYTALE_BOOT_COMMAND}"
fi

if is_true "${HYTALE_DISABLE_ASSET_COMPARE}"; then
  set -- "$@" --disable-asset-compare
fi

if is_true "${HYTALE_DISABLE_CPB_BUILD}"; then
  set -- "$@" --disable-cpb-build
fi

if is_true "${HYTALE_DISABLE_FILE_WATCHER}"; then
  set -- "$@" --disable-file-watcher
fi

if [ -n "${HYTALE_EARLY_PLUGINS_PATH:-}" ]; then
  set -- "$@" --early-plugins "${HYTALE_EARLY_PLUGINS_PATH}"
fi

if is_true "${HYTALE_EVENT_DEBUG}"; then
  set -- "$@" --event-debug
fi

if [ -n "${HYTALE_FORCE_NETWORK_FLUSH:-}" ]; then
  set -- "$@" --force-network-flush "${HYTALE_FORCE_NETWORK_FLUSH}"
fi

if is_true "${HYTALE_GENERATE_SCHEMA}"; then
  set -- "$@" --generate-schema
fi

if [ -n "${HYTALE_LOG:-}" ]; then
  set -- "$@" --log "${HYTALE_LOG}"
fi

if [ -n "${HYTALE_MODS_PATH:-}" ]; then
  set -- "$@" --mods "${HYTALE_MODS_PATH}"
fi

if [ -n "${HYTALE_OWNER_NAME:-}" ]; then
  set -- "$@" --owner-name "${HYTALE_OWNER_NAME}"
fi

if [ -n "${HYTALE_OWNER_UUID:-}" ]; then
  set -- "$@" --owner-uuid "${HYTALE_OWNER_UUID}"
fi

if [ -n "${HYTALE_PREFAB_CACHE_PATH:-}" ]; then
  set -- "$@" --prefab-cache "${HYTALE_PREFAB_CACHE_PATH}"
fi

if is_true "${HYTALE_SHUTDOWN_AFTER_VALIDATE}"; then
  set -- "$@" --shutdown-after-validate
fi

if is_true "${HYTALE_SINGLEPLAYER}"; then
  set -- "$@" --singleplayer
fi

if [ -n "${HYTALE_TRANSPORT:-}" ]; then
  set -- "$@" --transport "${HYTALE_TRANSPORT}"
fi

if [ -n "${HYTALE_UNIVERSE_PATH:-}" ]; then
  set -- "$@" --universe "${HYTALE_UNIVERSE_PATH}"
fi

if is_true "${HYTALE_VALIDATE_ASSETS}"; then
  set -- "$@" --validate-assets
fi

if [ -n "${HYTALE_VALIDATE_PREFABS:-}" ]; then
  if is_true "${HYTALE_VALIDATE_PREFABS}"; then
    set -- "$@" --validate-prefabs
  else
    set -- "$@" --validate-prefabs "${HYTALE_VALIDATE_PREFABS}"
  fi
fi

if is_true "${HYTALE_VALIDATE_WORLD_GEN}"; then
  set -- "$@" --validate-world-gen
fi

if [ -n "${HYTALE_WORLD_GEN_PATH:-}" ]; then
  set -- "$@" --world-gen "${HYTALE_WORLD_GEN_PATH}"
fi

if [ -n "${EXTRA_SERVER_ARGS:-}" ]; then
  set -- "$@" ${EXTRA_SERVER_ARGS}
fi

if [ -n "${user_args}" ]; then
  set -- "$@" ${user_args}
fi

if [ -n "${HYTALE_SERVER_SESSION_TOKEN:-}" ]; then
  set -- "$@" --session-token "${HYTALE_SERVER_SESSION_TOKEN}"
fi

if [ -n "${HYTALE_SERVER_IDENTITY_TOKEN:-}" ]; then
  set -- "$@" --identity-token "${HYTALE_SERVER_IDENTITY_TOKEN}"
fi

if is_true "${HYTALE_CONSOLE_PIPE}"; then
  CONSOLE_FIFO="${HYTALE_CONSOLE_FIFO:-/tmp/hytale-console.fifo}"

  if [ -e "${CONSOLE_FIFO}" ] && [ ! -p "${CONSOLE_FIFO}" ]; then
    rm -f "${CONSOLE_FIFO}" 2>/dev/null || true
  fi

  if [ ! -p "${CONSOLE_FIFO}" ]; then
    rm -f "${CONSOLE_FIFO}" 2>/dev/null || true
    mkfifo "${CONSOLE_FIFO}"
    chown hytale "${CONSOLE_FIFO}" 2>/dev/null || true
    chmod 0600 "${CONSOLE_FIFO}" 2>/dev/null || true
  fi

  exec 4<&0
  exec 3<> "${CONSOLE_FIFO}"
  (
    while IFS= read -r line <&4; do
      printf '%s\n' "${line}" >&3
    done
  ) &
  cd "${SERVER_DIR}"
  exec "$@" <&3
fi

cd "${SERVER_DIR}"
exec "$@"