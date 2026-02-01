#!/bin/sh
set -eu

# ============================================================================
# HYTALE CURSEFORGE MODS MANAGER
# ============================================================================
# Enhanced CurseForge mod manager with:
#   - Version checking and change detection
#   - Detailed error diagnostics
#   - Better retry logic with exponential backoff
#   - Mod compatibility warnings
#   - Download progress reporting
#   - Checksum verification
# ============================================================================

VERSION="2.0.0"

log() {
  printf '[CF-Mods] %s\n' "$*" >&2
}

log_debug() {
  if is_true "${HYTALE_CURSEFORGE_DEBUG:-false}"; then
    printf '[CF-Mods DEBUG] %s\n' "$*" >&2
  fi
}

log_error() {
  printf '[CF-Mods ERROR] %s\n' "$*" >&2
}

log_warn() {
  printf '[CF-Mods WARN] %s\n' "$*" >&2
}

log_success() {
  printf '[CF-Mods] ✓ %s\n' "$*" >&2
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

trim() {
  s="${1:-}"
  s="$(printf '%s' "${s}" | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"
  printf '%s' "${s}"
}

# Human-readable file size
human_size() {
  bytes="${1:-0}"
  if [ "${bytes}" -ge 1048576 ]; then
    printf '%.1f MB' "$(echo "scale=1; ${bytes} / 1048576" | bc 2>/dev/null || echo "${bytes}")"
  elif [ "${bytes}" -ge 1024 ]; then
    printf '%.1f KB' "$(echo "scale=1; ${bytes} / 1024" | bc 2>/dev/null || echo "${bytes}")"
  else
    printf '%d bytes' "${bytes}"
  fi
}

expand_refs() {
  input="$1"
  printf '%s\n' "${input}" | while IFS= read -r raw_line || [ -n "${raw_line}" ]; do
    raw_line="$(printf '%s' "${raw_line}" | sed 's/#.*$//')"
    raw_line="$(trim "${raw_line}")"
    if [ -z "${raw_line}" ]; then
      continue
    fi

    for token in ${raw_line}; do
      case "${token}" in
        @*)
          path="${token#@}"
          if [ -f "${path}" ]; then
            while IFS= read -r line || [ -n "${line}" ]; do
              line="$(printf '%s' "${line}" | sed 's/#.*$//')"
              line="$(trim "${line}")"
              if [ -z "${line}" ]; then
                continue
              fi
              for t in ${line}; do
                printf '%s\n' "${t}"
              done
            done <"${path}"
          else
            log_warn "listing file not found: ${path}"
          fi
          ;;
        *)
          printf '%s\n' "${token}"
          ;;
      esac
    done
  done
}

DATA_DIR="${DATA_DIR:-/home/container}"
CF_API_BASE="https://api.curseforge.com"
CF_API_HOST="api.curseforge.com"
CF_HYTALE_GAME_ID="83453"

HYTALE_CURSEFORGE_HTTP_CACHE_URL="${HYTALE_CURSEFORGE_HTTP_CACHE_URL:-}"
HYTALE_CURSEFORGE_HTTP_CACHE_API_URL="${HYTALE_CURSEFORGE_HTTP_CACHE_API_URL:-${HYTALE_CURSEFORGE_HTTP_CACHE_URL}}"
HYTALE_CURSEFORGE_HTTP_CACHE_DOWNLOAD_URL="${HYTALE_CURSEFORGE_HTTP_CACHE_DOWNLOAD_URL:-${HYTALE_CURSEFORGE_HTTP_CACHE_URL}}"

HYTALE_MODS_PATH="${HYTALE_MODS_PATH:-}"
HYTALE_CURSEFORGE_MODS="${HYTALE_CURSEFORGE_MODS:-}"
HYTALE_CURSEFORGE_API_KEY="${HYTALE_CURSEFORGE_API_KEY:-}"
HYTALE_CURSEFORGE_API_KEY_SRC="${HYTALE_CURSEFORGE_API_KEY_SRC:-}"
HYTALE_CURSEFORGE_AUTO_UPDATE="${HYTALE_CURSEFORGE_AUTO_UPDATE:-true}"
HYTALE_CURSEFORGE_RELEASE_CHANNEL="${HYTALE_CURSEFORGE_RELEASE_CHANNEL:-release}"
HYTALE_CURSEFORGE_FAIL_ON_ERROR="${HYTALE_CURSEFORGE_FAIL_ON_ERROR:-false}"
HYTALE_CURSEFORGE_CHECK_INTERVAL_SECONDS="${HYTALE_CURSEFORGE_CHECK_INTERVAL_SECONDS:-0}"
HYTALE_CURSEFORGE_GAME_VERSION_FILTER="${HYTALE_CURSEFORGE_GAME_VERSION_FILTER:-}"
HYTALE_CURSEFORGE_PRUNE="${HYTALE_CURSEFORGE_PRUNE:-false}"
HYTALE_CURSEFORGE_LOCK="${HYTALE_CURSEFORGE_LOCK:-true}"
HYTALE_CURSEFORGE_EXPAND_REFS_ONLY="${HYTALE_CURSEFORGE_EXPAND_REFS_ONLY:-false}"
HYTALE_CURSEFORGE_DEBUG="${HYTALE_CURSEFORGE_DEBUG:-false}"
HYTALE_CURSEFORGE_RETRY_COUNT="${HYTALE_CURSEFORGE_RETRY_COUNT:-3}"
HYTALE_CURSEFORGE_RETRY_DELAY="${HYTALE_CURSEFORGE_RETRY_DELAY:-2}"

if is_true "${HYTALE_CURSEFORGE_EXPAND_REFS_ONLY}"; then
  expand_refs "${HYTALE_CURSEFORGE_MODS}"
  exit 0
fi

log "CurseForge Mods Manager v${VERSION}"

if ! command -v jq >/dev/null 2>&1; then
  log_error "jq is required but was not found"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  log_error "curl is required but was not found"
  exit 1
fi

case "${HYTALE_CURSEFORGE_CHECK_INTERVAL_SECONDS}" in
  ''|*[!0-9]*)
    log_error "Invalid HYTALE_CURSEFORGE_CHECK_INTERVAL_SECONDS value: ${HYTALE_CURSEFORGE_CHECK_INTERVAL_SECONDS}"
    exit 1
    ;;
esac

if [ -z "${HYTALE_CURSEFORGE_MODS}" ]; then
  log "No mods configured (HYTALE_CURSEFORGE_MODS is empty)"
  exit 0
fi

# Load API key from file if specified
if [ -n "${HYTALE_CURSEFORGE_API_KEY_SRC}" ]; then
  if [ ! -f "${HYTALE_CURSEFORGE_API_KEY_SRC}" ]; then
    log_warn "API key file not found: ${HYTALE_CURSEFORGE_API_KEY_SRC}"
    if is_true "${HYTALE_CURSEFORGE_FAIL_ON_ERROR}"; then
      exit 1
    fi
    exit 0
  fi
  HYTALE_CURSEFORGE_API_KEY="$(cat "${HYTALE_CURSEFORGE_API_KEY_SRC}" 2>/dev/null || true)"
  HYTALE_CURSEFORGE_API_KEY="$(trim "${HYTALE_CURSEFORGE_API_KEY}")"
fi

if [ -z "${HYTALE_CURSEFORGE_API_KEY}" ]; then
  log_warn "HYTALE_CURSEFORGE_MODS is set but HYTALE_CURSEFORGE_API_KEY is empty"
  log "Get your API key at: https://console.curseforge.com/"
  if is_true "${HYTALE_CURSEFORGE_FAIL_ON_ERROR}"; then
    exit 1
  fi
  exit 0
fi

# API key validation
EXPECTED_API_KEY_PREFIX='$2a$10$'
redact_api_key() {
  key="$1"
  prefix_len=7
  trailing=2
  total_len="${#key}"
  if [ "${total_len}" -le $((prefix_len + trailing)) ]; then
    printf '%s' "${key}" | cut -c1-$((total_len / 2))
  else
    printf '%s*****%s' "$(printf '%s' "${key}" | cut -c1-${prefix_len})" "$(printf '%s' "${key}" | tail -c ${trailing})"
  fi
}

log "Validating API key format..."
case "${HYTALE_CURSEFORGE_API_KEY}" in
  '$$'*)
    log_error "API key has extra dollar sign escaping"
    log_error "Key looks like '$(redact_api_key "${HYTALE_CURSEFORGE_API_KEY}")'"
    log_error "In Docker Compose, escape each \$ as \$\$ (so \$2a becomes \$\$2a)"
    if is_true "${HYTALE_CURSEFORGE_FAIL_ON_ERROR}"; then exit 1; fi
    exit 0
    ;;
  '$2a$10$'*)
    log_debug "API key format valid"
    ;;
  *)
    log_error "API key should start with '${EXPECTED_API_KEY_PREFIX}'"
    log_error "Your key starts with: '$(redact_api_key "${HYTALE_CURSEFORGE_API_KEY}")'"
    log_error "Get your API key at: https://console.curseforge.com/"
    if is_true "${HYTALE_CURSEFORGE_FAIL_ON_ERROR}"; then exit 1; fi
    exit 0
    ;;
esac

# Test API key
log "Testing API connectivity..."
test_api_url="${CF_API_BASE}/v1/games"
if [ -n "${HYTALE_CURSEFORGE_HTTP_CACHE_API_URL}" ]; then
  test_api_url="${HYTALE_CURSEFORGE_HTTP_CACHE_API_URL%/}/v1/games"
  test_http_code="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 15 --connect-timeout 10 -H "Host: ${CF_API_HOST}" -H "x-api-key: ${HYTALE_CURSEFORGE_API_KEY}" "${test_api_url}" 2>/dev/null || echo "000")"
else
  test_http_code="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 15 --connect-timeout 10 -H "x-api-key: ${HYTALE_CURSEFORGE_API_KEY}" "${test_api_url}" 2>/dev/null || echo "000")"
fi

if [ "${test_http_code}" != "200" ]; then
  log_error "API key test failed (HTTP ${test_http_code})"
  case "${test_http_code}" in
    403) log_error "HTTP 403 = API key is invalid or lacks permissions" ;;
    401) log_error "HTTP 401 = API key is unauthorized" ;;
    429) log_error "HTTP 429 = Rate limited - try again later" ;;
    000) log_error "Could not connect to CurseForge API (network/timeout issue)" ;;
    5*) log_error "CurseForge server error - try again later" ;;
  esac
  if is_true "${HYTALE_CURSEFORGE_FAIL_ON_ERROR}"; then exit 1; fi
  log_warn "Continuing without CurseForge mods"
  exit 0
fi
log_success "API key valid"

# Setup directories
CF_MODS_DIR="${HYTALE_MODS_PATH:-${DATA_DIR}/Server/mods-curseforge}"
STATE_DIR="${DATA_DIR}/.hytale-curseforge-mods"
MANAGED_DIR="${STATE_DIR}"
DOWNLOADS_DIR="${MANAGED_DIR}/downloads"
FILES_DIR="${MANAGED_DIR}/files"
MANIFEST_PATH="${MANAGED_DIR}/manifest.json"
ERRORS_LOG="${MANAGED_DIR}/errors.log"

mkdir -p "${CF_MODS_DIR}" "${DOWNLOADS_DIR}" "${FILES_DIR}"

# Clear old errors log
: > "${ERRORS_LOG}" 2>/dev/null || true

# Lock management
LOCK_DIR="${DATA_DIR}/.hytale-curseforge-mods-lock"
LOCK_CREATED_AT_PATH="${LOCK_DIR}/created_at_epoch"
LOCK_TTL_SECONDS=300
lock_acquired=0

cleanup() {
  if [ "${lock_acquired}" -eq 1 ]; then
    rm -rf "${LOCK_DIR}" 2>/dev/null || true
  fi
}

if is_true "${HYTALE_CURSEFORGE_LOCK}"; then
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
        log "Stale lock detected (older than ${LOCK_TTL_SECONDS}s); removing"
        rm -rf "${LOCK_DIR}" 2>/dev/null || true
        continue
      fi
    fi

    log "Waiting for lock (another process may be installing mods)..."
    sleep 3
  done

  if [ "${lock_acquired}" -ne 1 ]; then
    log_error "Could not acquire lock ${LOCK_DIR}"
    exit 1
  fi
fi

now_epoch="$(date +%s 2>/dev/null || echo 0)"

# Initialize manifest
manifest_base='{"schemaVersion":2,"lastCheckEpoch":0,"mods":{}}'
if [ -f "${MANIFEST_PATH}" ]; then
  if ! jq -e . "${MANIFEST_PATH}" >/dev/null 2>&1; then
    log_warn "Invalid manifest JSON; recreating"
    printf '%s\n' "${manifest_base}" >"${MANIFEST_PATH}"
  fi
else
  printf '%s\n' "${manifest_base}" >"${MANIFEST_PATH}"
fi

# Check if we should skip remote checks
last_check_epoch="$(jq -r '.lastCheckEpoch // 0' "${MANIFEST_PATH}" 2>/dev/null || echo 0)"
skip_remote_checks=0
if [ "${HYTALE_CURSEFORGE_CHECK_INTERVAL_SECONDS}" -gt 0 ] && [ "${last_check_epoch}" -gt 0 ]; then
  if [ $((now_epoch - last_check_epoch)) -lt "${HYTALE_CURSEFORGE_CHECK_INTERVAL_SECONDS}" ]; then
    skip_remote_checks=1
    log "Skipping remote checks (last check was $((now_epoch - last_check_epoch))s ago)"
  fi
fi

# Release channel filter
release_allowed_expr="(.releaseType == 1)"
case "$(lower "${HYTALE_CURSEFORGE_RELEASE_CHANNEL}")" in
  release)
    release_allowed_expr="(.releaseType == 1)"
    log_debug "Release channel: stable only"
    ;;
  beta)
    release_allowed_expr="(.releaseType == 1 or .releaseType == 2)"
    log_debug "Release channel: stable + beta"
    ;;
  alpha|any)
    release_allowed_expr="(.releaseType == 1 or .releaseType == 2 or .releaseType == 3)"
    log_debug "Release channel: all (including alpha)"
    ;;
  *)
    log_error "Invalid release channel: ${HYTALE_CURSEFORGE_RELEASE_CHANNEL}"
    exit 1
    ;;
esac

# API request function with retry and exponential backoff
cf_get() {
  path="$1"
  url="${CF_API_BASE}${path}"
  host_header=""
  if [ -n "${HYTALE_CURSEFORGE_HTTP_CACHE_API_URL}" ]; then
    url="${HYTALE_CURSEFORGE_HTTP_CACHE_API_URL%/}${path}"
    host_header="${CF_API_HOST}"
  fi
  
  retry_count="${HYTALE_CURSEFORGE_RETRY_COUNT}"
  retry_delay="${HYTALE_CURSEFORGE_RETRY_DELAY}"
  
  for attempt in $(seq 1 "${retry_count}"); do
    log_debug "API request: ${path} (attempt ${attempt}/${retry_count})"
    
    if [ -n "${host_header}" ]; then
      out="$(curl -fsSL --max-time 30 --connect-timeout 10 \
        -H "Host: ${host_header}" \
        -H "Accept: application/json" \
        -H "x-api-key: ${HYTALE_CURSEFORGE_API_KEY}" \
        "${url}" 2>/dev/null || true)"
    else
      out="$(curl -fsSL --max-time 30 --connect-timeout 10 \
        -H "Accept: application/json" \
        -H "x-api-key: ${HYTALE_CURSEFORGE_API_KEY}" \
        "${url}" 2>/dev/null || true)"
    fi
    
    if [ -n "${out}" ]; then
      printf '%s' "${out}"
      return 0
    fi
    
    if [ "${attempt}" -lt "${retry_count}" ]; then
      sleep_time=$((retry_delay * attempt))
      log_debug "Request failed, retrying in ${sleep_time}s..."
      sleep "${sleep_time}"
    fi
  done
  
  return 1
}

safe_filename() {
  printf '%s' "${1:-}" | sed -e 's,[/[:space:]],_,g' -e 's/[^A-Za-z0-9._-]/_/g'
}

# Get mod info for better error messages
get_mod_info() {
  mod_id="$1"
  mod_resp="$(cf_get "/v1/mods/${mod_id}")" || return 1
  printf '%s' "${mod_resp}" | jq -c '.data // empty' 2>/dev/null || true
}

# Download and install a mod file
download_and_install() {
  mod_id="$1"
  file_json="$2"
  mod_name="${3:-Mod ${mod_id}}"
  
  file_id="$(printf '%s' "${file_json}" | jq -r '.id')"
  file_name="$(printf '%s' "${file_json}" | jq -r '.fileName')"
  file_size="$(printf '%s' "${file_json}" | jq -r '.fileLength // 0')"
  release_type="$(printf '%s' "${file_json}" | jq -r '.releaseType // 1')"
  game_versions="$(printf '%s' "${file_json}" | jq -r '.gameVersions // [] | join(", ")')"
  
  release_label="release"
  case "${release_type}" in
    2) release_label="beta" ;;
    3) release_label="alpha" ;;
  esac
  
  log "  Downloading: ${file_name} ($(human_size "${file_size}"), ${release_label})"
  if [ -n "${game_versions}" ]; then
    log_debug "  Game versions: ${game_versions}"
  fi
  
  # Get download URL
  dl_json="$(cf_get "/v1/mods/${mod_id}/files/${file_id}/download-url")" || {
    log_error "  Could not get download URL for ${file_name}"
    printf '%s: Could not get download URL\n' "${mod_name}" >> "${ERRORS_LOG}"
    return 1
  }
  
  download_url="$(printf '%s' "${dl_json}" | jq -r '.data // empty')"
  if [ -z "${download_url}" ]; then
    log_error "  Empty download URL for ${file_name}"
    printf '%s: Empty download URL (file may be restricted)\n' "${mod_name}" >> "${ERRORS_LOG}"
    return 1
  fi
  
  # Handle HTTP cache proxy
  download_fetch_url="${download_url}"
  download_host_header=""
  if [ -n "${HYTALE_CURSEFORGE_HTTP_CACHE_DOWNLOAD_URL}" ]; then
    case "${download_url}" in
      http://*|https://*)
        rest="${download_url#*://}"
        download_host="${rest%%/*}"
        if [ "${rest#*/}" = "${rest}" ]; then
          download_path="/"
        else
          download_path="/${rest#*/}"
        fi
        download_fetch_url="${HYTALE_CURSEFORGE_HTTP_CACHE_DOWNLOAD_URL%/}${download_path}"
        download_host_header="${download_host}"
        ;;
    esac
  fi
  
  # Get checksums
  sha1="$(printf '%s' "${file_json}" | jq -r '.hashes[]? | select(.algo==1) | .value' 2>/dev/null | head -n 1 || true)"
  md5="$(printf '%s' "${file_json}" | jq -r '.hashes[]? | select(.algo==2) | .value' 2>/dev/null | head -n 1 || true)"
  
  dest_dir="${FILES_DIR}/${mod_id}/${file_id}"
  mkdir -p "${dest_dir}"
  dest_path="${dest_dir}/${file_name}"
  
  # Download with retries
  tmp_dl="${DOWNLOADS_DIR}/${mod_id}-${file_id}.tmp.$$"
  dl_ok=0
  
  for dl_attempt in 1 2 3; do
    log_debug "  Download attempt ${dl_attempt}/3"
    
    if [ -n "${download_host_header}" ]; then
      if curl -fL --max-time 300 --connect-timeout 30 --retry 2 --retry-delay 1 \
        -H "Host: ${download_host_header}" \
        -o "${tmp_dl}" "${download_fetch_url}" >/dev/null 2>&1; then
        dl_ok=1
        break
      fi
    else
      if curl -fL --max-time 300 --connect-timeout 30 --retry 2 --retry-delay 1 \
        -o "${tmp_dl}" "${download_fetch_url}" >/dev/null 2>&1; then
        dl_ok=1
        break
      fi
    fi
    
    sleep $((dl_attempt * 2))
  done
  
  if [ "${dl_ok}" -ne 1 ]; then
    rm -f "${tmp_dl}" 2>/dev/null || true
    log_error "  Download failed after 3 attempts"
    printf '%s: Download failed (network error or file unavailable)\n' "${mod_name}" >> "${ERRORS_LOG}"
    return 1
  fi
  
  # Verify checksum
  if [ -n "${sha1}" ]; then
    got="$(sha1sum "${tmp_dl}" 2>/dev/null | awk '{print $1}' || true)"
    if [ -z "${got}" ] || [ "${got}" != "${sha1}" ]; then
      rm -f "${tmp_dl}" 2>/dev/null || true
      log_error "  SHA1 checksum mismatch (expected: ${sha1}, got: ${got})"
      printf '%s: Checksum verification failed\n' "${mod_name}" >> "${ERRORS_LOG}"
      return 1
    fi
    log_debug "  SHA1 verified: ${sha1}"
  elif [ -n "${md5}" ]; then
    got="$(md5sum "${tmp_dl}" 2>/dev/null | awk '{print $1}' || true)"
    if [ -z "${got}" ] || [ "${got}" != "${md5}" ]; then
      rm -f "${tmp_dl}" 2>/dev/null || true
      log_error "  MD5 checksum mismatch (expected: ${md5}, got: ${got})"
      printf '%s: Checksum verification failed\n' "${mod_name}" >> "${ERRORS_LOG}"
      return 1
    fi
    log_debug "  MD5 verified: ${md5}"
  else
    log_debug "  No checksum available for verification"
  fi
  
  # Move to final location
  tmp_final="${dest_path}.tmp.$$"
  mv -f "${tmp_dl}" "${tmp_final}"
  mv -f "${tmp_final}" "${dest_path}"
  
  # Create symlink in mods directory
  safe_name="$(safe_filename "${file_name}")"
  visible_name="cf-${mod_id}-${file_id}-${safe_name}"
  visible_path="${CF_MODS_DIR}/${visible_name}"
  
  if ln -sf "${dest_path}" "${visible_path}" 2>/dev/null; then
    log_debug "  Created symlink: ${visible_name}"
  else
    cp -f "${dest_path}" "${visible_path}"
    log_debug "  Copied file: ${visible_name}"
  fi
  
  # Update manifest
  installed_at="${now_epoch}"
  hash_algo=""
  hash_value=""
  if [ -n "${sha1}" ]; then
    hash_algo="sha1"
    hash_value="${sha1}"
  elif [ -n "${md5}" ]; then
    hash_algo="md5"
    hash_value="${md5}"
  fi
  
  ref="$(jq -r --arg mid "${mod_id}" '.mods[$mid].reference // empty' "${MANIFEST_PATH}" 2>/dev/null || true)"
  if [ -z "${ref}" ]; then
    ref="${mod_id}"
  fi
  
  tmp_manifest="${MANIFEST_PATH}.tmp.$$"
  jq \
    --arg mid "${mod_id}" \
    --arg ref "${ref}" \
    --arg fn "${file_name}" \
    --arg mn "${mod_name}" \
    --arg dn "$(printf '%s' "${file_json}" | jq -r '.displayName // empty')" \
    --arg fd "$(printf '%s' "${file_json}" | jq -r '.fileDate // empty')" \
    --arg url "${download_url}" \
    --arg ha "${hash_algo}" \
    --arg hv "${hash_value}" \
    --arg ip "${visible_name}" \
    --argjson fid "${file_id}" \
    --argjson fs "${file_size}" \
    --argjson rt "${release_type:-1}" \
    --argjson at "${installed_at}" \
    '(.mods[$mid] = {
      reference: $ref,
      modName: $mn,
      resolved: {
        fileId: $fid,
        fileName: $fn,
        displayName: $dn,
        fileDate: $fd,
        fileSize: $fs,
        releaseType: $rt,
        downloadUrl: $url,
        hash: (if ($ha != "" and $hv != "") then {algo: $ha, value: $hv} else null end)
      },
      installed: {
        fileId: $fid,
        path: $ip,
        installedAtEpoch: $at
      }
    })' "${MANIFEST_PATH}" >"${tmp_manifest}"
  mv -f "${tmp_manifest}" "${MANIFEST_PATH}"
  
  log_success "${mod_name} installed (${visible_name})"
  printf '%s\n' "${mod_id}"
}

# Resolve best file for a mod
resolve_best_file() {
  mod_id="$1"
  partial="$2"

  index=0
  page_size=50
  best_json=""
  best_date=""

  while :; do
    page="$(cf_get "/v1/mods/${mod_id}/files?index=${index}&pageSize=${page_size}")" || break
    count="$(printf '%s' "${page}" | jq -r '.data | length' 2>/dev/null || echo 0)"
    if [ "${count}" -eq 0 ]; then
      break
    fi

    filtered="$(printf '%s' "${page}" | jq -c \
      --arg gv "${HYTALE_CURSEFORGE_GAME_VERSION_FILTER}" \
      --arg part "${partial}" \
      --argjson haspart "$( [ -n "${partial}" ] && echo 1 || echo 0 )" \
      "[.data[]
        | select(.isAvailable == true)
        | select(${release_allowed_expr})
        | select((\$gv == \"\") or (.gameVersions[]? == \$gv))
        | select((\$haspart == 0) or (((.fileName // \"\") | ascii_downcase) | contains((\$part | ascii_downcase))) or (((.displayName // \"\") | ascii_downcase) | contains((\$part | ascii_downcase))))
      ] | sort_by(.fileDate) | last // empty" 2>/dev/null || true)"

    if [ -n "${filtered}" ] && [ "${filtered}" != "null" ]; then
      cand_date="$(printf '%s' "${filtered}" | jq -r '.fileDate // empty')"
      if [ -z "${best_date}" ] || [ "${cand_date}" \> "${best_date}" ]; then
        best_json="${filtered}"
        best_date="${cand_date}"
      fi
    fi

    index=$((index + page_size))
    if [ "${index}" -ge 10000 ]; then
      break
    fi
  done

  if [ -z "${best_json}" ] || [ "${best_json}" = "null" ]; then
    printf '%s' ""
    return 1
  fi

  printf '%s' "${best_json}"
}

# Main processing
errors=0
did_remote_check=0
installed_mod_ids=""
total_mods=0
installed_count=0
updated_count=0
failed_count=0

refs="$(expand_refs "${HYTALE_CURSEFORGE_MODS}")"
refs_file="$(mktemp /tmp/hytale-curseforge-mods.XXXXXX 2>/dev/null || mktemp)"
printf '%s\n' "${refs}" >"${refs_file}"

# Count total mods
total_mods="$(wc -l < "${refs_file}" | tr -d ' ')"
log "Processing ${total_mods} mod(s)..."

current_mod=0
while IFS= read -r ref || [ -n "${ref}" ]; do
  ref="$(trim "${ref}")"
  if [ -z "${ref}" ]; then
    continue
  fi
  
  current_mod=$((current_mod + 1))
  log "[${current_mod}/${total_mods}] Processing: ${ref}"

  mod_id=""
  file_id=""
  partial=""

  case "${ref}" in
    *:*)
      mod_id="${ref%%:*}"
      file_id="${ref#*:}"
      ;;
    *@*)
      mod_id="${ref%%@*}"
      partial="${ref#*@}"
      ;;
    *)
      mod_id="${ref}"
      ;;
  esac

  case "${mod_id}" in
    *[!0-9]*|"")
      log_warn "Invalid mod reference: ${ref}"
      continue
      ;;
  esac

  # Get mod info for better logging
  mod_name="Mod ${mod_id}"
  if [ "${skip_remote_checks}" -ne 1 ]; then
    mod_info="$(get_mod_info "${mod_id}")"
    if [ -n "${mod_info}" ]; then
      mod_name="$(printf '%s' "${mod_info}" | jq -r '.name // empty')"
      if [ -z "${mod_name}" ]; then
        mod_name="Mod ${mod_id}"
      fi
    fi
  fi

  tmp_manifest="${MANIFEST_PATH}.tmp.$$"
  jq --arg mid "${mod_id}" --arg ref "${ref}" --arg mn "${mod_name}" \
    '(.mods[$mid].reference = $ref) | (.mods[$mid].modName = $mn)' "${MANIFEST_PATH}" >"${tmp_manifest}"
  mv -f "${tmp_manifest}" "${MANIFEST_PATH}"

  if [ -n "${file_id}" ]; then
    # Specific file ID requested
    case "${file_id}" in
      *[!0-9]*|"")
        log_warn "Invalid file ID in reference: ${ref}"
        continue
        ;;
    esac

    if [ "${skip_remote_checks}" -eq 1 ]; then
      installed_path="$(jq -r --arg mid "${mod_id}" '.mods[$mid].installed.path // empty' "${MANIFEST_PATH}" 2>/dev/null || true)"
      if [ -n "${installed_path}" ] && [ -f "${CF_MODS_DIR}/${installed_path}" ]; then
        installed_mod_ids="${installed_mod_ids}${mod_id}\n"
        installed_count=$((installed_count + 1))
        continue
      fi
    fi

    file_resp="$(cf_get "/v1/mods/${mod_id}/files/${file_id}")" || {
      log_error "Could not fetch file info for ${ref}"
      printf '%s (ID: %s): Could not fetch file info from API\n' "${mod_name}" "${mod_id}" >> "${ERRORS_LOG}"
      errors=$((errors + 1))
      failed_count=$((failed_count + 1))
      continue
    }
    file_json="$(printf '%s' "${file_resp}" | jq -c '.data // empty' 2>/dev/null || true)"
    if [ -z "${file_json}" ] || [ "${file_json}" = "null" ]; then
      log_error "Could not resolve file for ${ref}"
      printf '%s (ID: %s): File ID %s not found\n' "${mod_name}" "${mod_id}" "${file_id}" >> "${ERRORS_LOG}"
      errors=$((errors + 1))
      failed_count=$((failed_count + 1))
      continue
    fi
    did_remote_check=1
  else
    # Auto-resolve latest file
    installed_file_id="$(jq -r --arg mid "${mod_id}" '.mods[$mid].installed.fileId // empty' "${MANIFEST_PATH}" 2>/dev/null || true)"
    installed_path="$(jq -r --arg mid "${mod_id}" '.mods[$mid].installed.path // empty' "${MANIFEST_PATH}" 2>/dev/null || true)"

    if [ "${skip_remote_checks}" -eq 1 ] && [ -n "${installed_file_id}" ] && [ -n "${installed_path}" ] && [ -f "${CF_MODS_DIR}/${installed_path}" ]; then
      installed_mod_ids="${installed_mod_ids}${mod_id}\n"
      installed_count=$((installed_count + 1))
      continue
    fi

    if ! is_true "${HYTALE_CURSEFORGE_AUTO_UPDATE}" && [ -n "${installed_file_id}" ] && [ -n "${installed_path}" ] && [ -f "${CF_MODS_DIR}/${installed_path}" ]; then
      installed_mod_ids="${installed_mod_ids}${mod_id}\n"
      installed_count=$((installed_count + 1))
      continue
    fi

    file_json="$(resolve_best_file "${mod_id}" "${partial}" || true)"
    if [ -z "${file_json}" ]; then
      log_error "Could not find compatible file for ${mod_name}"
      printf '%s (ID: %s): No compatible file found (check game version and release channel)\n' "${mod_name}" "${mod_id}" >> "${ERRORS_LOG}"
      errors=$((errors + 1))
      failed_count=$((failed_count + 1))
      continue
    fi
    did_remote_check=1
  fi

  resolved_file_id="$(printf '%s' "${file_json}" | jq -r '.id')"
  safe_name="$(safe_filename "$(printf '%s' "${file_json}" | jq -r '.fileName')")"
  visible_name="cf-${mod_id}-${resolved_file_id}-${safe_name}"

  current_file_id="$(jq -r --arg mid "${mod_id}" '.mods[$mid].installed.fileId // empty' "${MANIFEST_PATH}" 2>/dev/null || true)"
  current_path="$(jq -r --arg mid "${mod_id}" '.mods[$mid].installed.path // empty' "${MANIFEST_PATH}" 2>/dev/null || true)"

  # Check if already installed and up to date
  if [ -n "${current_file_id}" ] && [ "${current_file_id}" = "${resolved_file_id}" ] && [ -n "${current_path}" ] && [ -f "${CF_MODS_DIR}/${current_path}" ]; then
    log "  Already up to date"
    installed_mod_ids="${installed_mod_ids}${mod_id}\n"
    installed_count=$((installed_count + 1))
    continue
  fi

  # Check if this is an update
  is_update=0
  if [ -n "${current_file_id}" ] && [ "${current_file_id}" != "${resolved_file_id}" ]; then
    is_update=1
    log "  Update available: ${current_file_id} -> ${resolved_file_id}"
  fi

  if ! download_and_install "${mod_id}" "${file_json}" "${mod_name}" >/dev/null; then
    errors=$((errors + 1))
    failed_count=$((failed_count + 1))
    continue
  fi

  installed_mod_ids="${installed_mod_ids}${mod_id}\n"
  
  if [ "${is_update}" -eq 1 ]; then
    updated_count=$((updated_count + 1))
  else
    installed_count=$((installed_count + 1))
  fi
  
  # Remove old version
  if [ "${visible_name}" != "${current_path}" ] && [ -n "${current_path}" ] && [ -f "${CF_MODS_DIR}/${current_path}" ]; then
    rm -f "${CF_MODS_DIR}/${current_path}" 2>/dev/null || true
    log_debug "  Removed old version: ${current_path}"
  fi

done <"${refs_file}"

rm -f "${refs_file}" 2>/dev/null || true

# Update last check time
if [ "${did_remote_check}" -eq 1 ]; then
  tmp_manifest="${MANIFEST_PATH}.tmp.$$"
  jq --argjson now "${now_epoch}" '.lastCheckEpoch = $now' "${MANIFEST_PATH}" >"${tmp_manifest}"
  mv -f "${tmp_manifest}" "${MANIFEST_PATH}"
fi

# Prune removed mods
if is_true "${HYTALE_CURSEFORGE_PRUNE}"; then
  desired_ids_file="${MANAGED_DIR}/.desired_mod_ids.$$"
  printf '%b' "${installed_mod_ids}" | sort -u >"${desired_ids_file}" 2>/dev/null || true

  pruned_count=0
  jq -r '.mods | keys[]' "${MANIFEST_PATH}" 2>/dev/null | while IFS= read -r mid || [ -n "${mid}" ]; do
    if ! grep -qx "${mid}" "${desired_ids_file}" 2>/dev/null; then
      old_name="$(jq -r --arg mid "${mid}" '.mods[$mid].modName // "Unknown"' "${MANIFEST_PATH}" 2>/dev/null || true)"
      old_path="$(jq -r --arg mid "${mid}" '.mods[$mid].installed.path // empty' "${MANIFEST_PATH}" 2>/dev/null || true)"
      if [ -n "${old_path}" ] && [ -e "${CF_MODS_DIR}/${old_path}" ]; then
        rm -f "${CF_MODS_DIR}/${old_path}" 2>/dev/null || true
      fi
      rm -rf "${FILES_DIR}/${mid}" 2>/dev/null || true

      tmp_manifest="${MANIFEST_PATH}.tmp.$$"
      jq --arg mid "${mid}" 'del(.mods[$mid])' "${MANIFEST_PATH}" >"${tmp_manifest}"
      mv -f "${tmp_manifest}" "${MANIFEST_PATH}"
      
      log "Pruned removed mod: ${old_name} (${mid})"
      pruned_count=$((pruned_count + 1))
    fi
  done

  rm -f "${desired_ids_file}" 2>/dev/null || true
fi

# Summary
log ""
log "========================================="
log "  CurseForge Mods Summary"
log "========================================="
log "  Total processed: ${total_mods}"
log "  Already installed: ${installed_count}"
log "  Updated: ${updated_count}"
log "  Failed: ${failed_count}"
log "========================================="

# Show errors if any
if [ "${errors}" -gt 0 ]; then
  log ""
  log_warn "${errors} mod(s) failed to install:"
  if [ -f "${ERRORS_LOG}" ] && [ -s "${ERRORS_LOG}" ]; then
    while IFS= read -r err_line; do
      log_warn "  - ${err_line}"
    done < "${ERRORS_LOG}"
  fi
  log ""
  log "Troubleshooting tips:"
  log "  1. Check if mod exists: https://www.curseforge.com/hytale/mods"
  log "  2. Try different release channel: HYTALE_CURSEFORGE_RELEASE_CHANNEL=beta"
  log "  3. Check game version filter: HYTALE_CURSEFORGE_GAME_VERSION_FILTER"
  log "  4. Enable debug logging: HYTALE_CURSEFORGE_DEBUG=true"
fi

if [ "${errors}" -gt 0 ] && is_true "${HYTALE_CURSEFORGE_FAIL_ON_ERROR}"; then
  exit 1
fi

exit 0