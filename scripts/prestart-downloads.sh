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

trim() {
  s="${1:-}"
  s="$(printf '%s' "${s}" | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"
  printf '%s' "${s}"
}

safe_filename() {
  printf '%s' "${1:-}" | sed -e 's,[/[:space:]],_,g' -e 's/[^A-Za-z0-9._-]/_/g'
}

redact_url() {
  u="${1:-}"
  u="$(printf '%s' "${u}" | sed -e 's/[?#].*$//')"
  u="$(printf '%s' "${u}" | sed -e 's,://[^/@]*@,://[redacted]@,')"
  printf '%s' "${u}"
}

url_without_query() {
  printf '%s' "${1:-}" | sed -e 's/[?#].*$//'
}

check_dir_writable() {
  dir="$1"
  if [ ! -w "${dir}" ]; then
    log "ERROR: Cannot write to ${dir}"
    log "ERROR: Directory exists but is not writable by UID $(id -u)."
    log "ERROR: Current owner: $(ls -ld "${dir}" 2>/dev/null | awk '{print $3":"$4}')"
    log "ERROR: Fix: 'sudo chown -R $(id -u):$(id -g) <host-path>'"
    log "ERROR: Or delete the directory and let the container recreate it."
    log "ERROR: See https://github.com/Hybrowse/hytale-server-docker/blob/main/docs/image/troubleshooting.md"
    exit 1
  fi
}

expand_refs() {
  input="$1"

  printf '%s\n' "${input}" | while IFS= read -r line || [ -n "${line}" ]; do
    line="$(printf '%s' "${line}" | sed 's/#.*$//')"
    line="$(trim "${line}")"
    if [ -z "${line}" ]; then
      continue
    fi

    line="$(printf '%s' "${line}" | tr ',' ' ')"
    for token in ${line}; do
      case "${token}" in
        @*)
          path="${token#@}"
          if [ -f "${path}" ]; then
            while IFS= read -r file_line || [ -n "${file_line}" ]; do
              file_line="$(printf '%s' "${file_line}" | sed 's/#.*$//')"
              file_line="$(trim "${file_line}")"
              if [ -z "${file_line}" ]; then
                continue
              fi
              file_line="$(printf '%s' "${file_line}" | tr ',' ' ')"
              for tok in ${file_line}; do
                printf '%s\n' "${tok}"
              done
            done <"${path}"
          else
            log "WARNING: download listing file not found: ${path}"
          fi
          ;;
        *)
          printf '%s\n' "${token}"
          ;;
      esac
    done
  done
}

download_url_list() {
  label="$1"
  urls_input="$2"
  dest_dir="$3"
  limit_rate="$4"
  force="$5"
  fail_on_error="$6"
  state_dir="$7"
  extract_zip="$8"

  mkdir -p "${dest_dir}" "${state_dir}"
  chmod 0777 "${DATA_DIR}/.hytale-prestart-downloads" "${state_dir}" 2>/dev/null || true
  check_dir_writable "${dest_dir}"
  check_dir_writable "${state_dir}"

  urls_file="$(mktemp /tmp/hytale-${label}-downloads.XXXXXX 2>/dev/null || mktemp)"
  expand_refs "${urls_input}" >"${urls_file}"

  errors=0

  while IFS= read -r url || [ -n "${url}" ]; do
    url="$(trim "${url}")"
    if [ -z "${url}" ]; then
      continue
    fi

    case "${url}" in
      http://*|https://*) ;;
      *)
        log "ERROR: ${label} download: unsupported URL scheme (expected http/https): $(redact_url "${url}")"
        errors=$((errors + 1))
        continue
        ;;
    esac

    url_noq="$(url_without_query "${url}")"
    marker_id="$(printf '%s' "${url}" | cksum | awk '{print $1}' 2>/dev/null || echo "")"
    if [ -z "${marker_id}" ]; then
      marker_id="$(safe_filename "${url_noq}")"
    fi
    marker_path="${state_dir}/${marker_id}.done"

    if [ -f "${marker_path}" ] && ! is_true "${force}"; then
      continue
    fi

    log "${label} download: downloading $(redact_url "${url}")"

    tmp_dl="${state_dir}/${marker_id}.tmp.$$"
    curl_args="-fL --max-time 900 --connect-timeout 20 --retry 3 --retry-delay 1"
    if [ -n "${limit_rate}" ]; then
      curl_args="${curl_args} --limit-rate ${limit_rate}"
    fi

    if ! curl ${curl_args} -o "${tmp_dl}" "${url}" >/dev/null 2>&1; then
      rm -f "${tmp_dl}" 2>/dev/null || true
      log "ERROR: ${label} download: failed for $(redact_url "${url}")"
      errors=$((errors + 1))
      continue
    fi

    if is_true "${extract_zip}"; then
      is_zip=0
      case "${url_noq}" in
        *.zip|*.ZIP) is_zip=1 ;;
        *)
          if unzip -tq "${tmp_dl}" >/dev/null 2>&1; then
            is_zip=1
          fi
          ;;
      esac

      if [ "${is_zip}" -eq 1 ]; then
        if ! unzip -o "${tmp_dl}" -d "${dest_dir}" >/dev/null 2>&1; then
          rm -f "${tmp_dl}" 2>/dev/null || true
          log "ERROR: ${label} download: failed to extract zip from $(redact_url "${url}")"
          errors=$((errors + 1))
          continue
        fi
        rm -f "${tmp_dl}" 2>/dev/null || true
      else
        bn="$(printf '%s' "${url_noq}" | sed 's,.*[/],,')"
        if [ -z "${bn}" ]; then
          bn="download"
        fi
        bn="$(safe_filename "${bn}")"
        dest_path="${dest_dir}/${bn}"
        tmp_final="${dest_path}.tmp.$$"
        mv -f "${tmp_dl}" "${tmp_final}"
        mv -f "${tmp_final}" "${dest_path}"
      fi
    else
      bn="$(printf '%s' "${url_noq}" | sed 's,.*[/],,')"
      if [ -z "${bn}" ]; then
        bn="download"
      fi
      bn="$(safe_filename "${bn}")"
      dest_path="${dest_dir}/${bn}"
      tmp_final="${dest_path}.tmp.$$"
      mv -f "${tmp_dl}" "${tmp_final}"
      mv -f "${tmp_final}" "${dest_path}"
    fi

    now_epoch="$(date +%s 2>/dev/null || echo 0)"
    printf '%s\n' "${now_epoch}" >"${marker_path}" 2>/dev/null || true
  done <"${urls_file}"

  rm -f "${urls_file}" 2>/dev/null || true

  if [ "${errors}" -gt 0 ] && is_true "${fail_on_error}"; then
    exit 1
  fi
}

DATA_DIR="${DATA_DIR:-/home/container}"
SERVER_DIR="${SERVER_DIR:-/home/container/server}"

HYTALE_UNIVERSE_DOWNLOAD_URLS="${HYTALE_UNIVERSE_DOWNLOAD_URLS:-}"
HYTALE_UNIVERSE_DOWNLOAD_PATH="${HYTALE_UNIVERSE_DOWNLOAD_PATH:-}"
HYTALE_UNIVERSE_DOWNLOAD_LIMIT_RATE="${HYTALE_UNIVERSE_DOWNLOAD_LIMIT_RATE:-}"
HYTALE_UNIVERSE_DOWNLOAD_FORCE="${HYTALE_UNIVERSE_DOWNLOAD_FORCE:-false}"
HYTALE_UNIVERSE_DOWNLOAD_FAIL_ON_ERROR="${HYTALE_UNIVERSE_DOWNLOAD_FAIL_ON_ERROR:-true}"

HYTALE_MODS_DOWNLOAD_URLS="${HYTALE_MODS_DOWNLOAD_URLS:-}"
HYTALE_MODS_DOWNLOAD_PATH="${HYTALE_MODS_DOWNLOAD_PATH:-}"
HYTALE_MODS_DOWNLOAD_LIMIT_RATE="${HYTALE_MODS_DOWNLOAD_LIMIT_RATE:-}"
HYTALE_MODS_DOWNLOAD_FORCE="${HYTALE_MODS_DOWNLOAD_FORCE:-false}"
HYTALE_MODS_DOWNLOAD_FAIL_ON_ERROR="${HYTALE_MODS_DOWNLOAD_FAIL_ON_ERROR:-true}"

HYTALE_UNIVERSE_PATH="${HYTALE_UNIVERSE_PATH:-}"
HYTALE_MODS_PATH="${HYTALE_MODS_PATH:-}"

if [ -n "${HYTALE_UNIVERSE_DOWNLOAD_URLS}" ]; then
  dest_dir="${HYTALE_UNIVERSE_DOWNLOAD_PATH:-${HYTALE_UNIVERSE_PATH:-${SERVER_DIR}/universe}}"
  state_dir="${DATA_DIR}/.hytale-prestart-downloads/universe"
  download_url_list "universe" "${HYTALE_UNIVERSE_DOWNLOAD_URLS}" "${dest_dir}" "${HYTALE_UNIVERSE_DOWNLOAD_LIMIT_RATE}" "${HYTALE_UNIVERSE_DOWNLOAD_FORCE}" "${HYTALE_UNIVERSE_DOWNLOAD_FAIL_ON_ERROR}" "${state_dir}" "true"
fi

if [ -n "${HYTALE_MODS_DOWNLOAD_URLS}" ]; then
  dest_dir="${HYTALE_MODS_DOWNLOAD_PATH:-${HYTALE_MODS_PATH:-${SERVER_DIR}/mods}}"
  state_dir="${DATA_DIR}/.hytale-prestart-downloads/mods"
  download_url_list "mods" "${HYTALE_MODS_DOWNLOAD_URLS}" "${dest_dir}" "${HYTALE_MODS_DOWNLOAD_LIMIT_RATE}" "${HYTALE_MODS_DOWNLOAD_FORCE}" "${HYTALE_MODS_DOWNLOAD_FAIL_ON_ERROR}" "${state_dir}" "false"
fi
