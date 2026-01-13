#!/bin/sh
set -eu

IMAGE_NAME="${IMAGE_NAME:-hytale-server:test}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*" >&2
}

# Test 1: runs as non-root by default
uid="$(docker run --rm --entrypoint id "${IMAGE_NAME}" -u)"
[ "${uid}" = "1000" ] || fail "expected uid 1000, got ${uid}"
pass "default user is non-root (uid=${uid})"

# Test 2: fails fast with clear errors when files are missing
workdir="$(mktemp -d)"
chmod 0777 "${workdir}"
set +e
out="$(docker run --rm -v "${workdir}:/data" "${IMAGE_NAME}" 2>&1)"
status=$?
set -e
[ ${status} -ne 0 ] || fail "expected non-zero exit status when files missing"
echo "${out}" | grep -q "Missing server jar" || fail "missing server jar error not present"
echo "${out}" | grep -q "Missing assets" || fail "missing assets error not present"
echo "${out}" | grep -q "Expected volume layout:" || fail "expected volume layout help not present"
echo "${out}" | grep -q "docs/image/server-files.md" || fail "expected docs link to server-files.md"
if echo "${out}" | grep -q "docs/hytale/"; then
  fail "output should not reference docs/hytale"
fi
pass "fails fast when Assets.zip / jar missing"

rm -rf "${workdir}"

# Test 3: AOT strict mode fails when cache missing
workdir="$(mktemp -d)"
chmod 0777 "${workdir}"
mkdir -p "${workdir}/server"
chmod 0777 "${workdir}/server"
: > "${workdir}/Assets.zip"
: > "${workdir}/server/HytaleServer.jar"
set +e
out="$(docker run --rm -e ENABLE_AOT=true -v "${workdir}:/data" "${IMAGE_NAME}" 2>&1)"
status=$?
set -e
[ ${status} -ne 0 ] || fail "expected non-zero exit status when ENABLE_AOT=true and cache missing"
echo "${out}" | grep -q "ENABLE_AOT=true" || fail "AOT strict error not present"
pass "ENABLE_AOT=true fails fast when cache missing"

# Test 3b: backup flag is recognized by the entrypoint
set +e
out="$(docker run --rm -e HYTALE_ENABLE_BACKUP=true -v "${workdir}:/data" "${IMAGE_NAME}" 2>&1)"
status=$?
set -e
[ ${status} -ne 0 ] || fail "expected non-zero exit status due to dummy jar"
echo "${out}" | grep -q "Backup: enabled" || fail "expected backup enabled log"
pass "backup can be enabled via HYTALE_ENABLE_BACKUP"

# Test 4: auto-download must refuse non-official downloader URLs (no network)
workdir2="$(mktemp -d)"
chmod 0777 "${workdir2}"
set +e
out="$(docker run --rm \
  -e HYTALE_AUTO_DOWNLOAD=true \
  -e HYTALE_DOWNLOADER_URL=https://example.com/hytale-downloader.zip \
  -v "${workdir2}:/data" "${IMAGE_NAME}" 2>&1)"
status=$?
set -e
[ ${status} -ne 0 ] || fail "expected non-zero exit status when HYTALE_DOWNLOADER_URL is not official"
echo "${out}" | grep -q "Attempting auto-download via official Hytale Downloader" || fail "expected entrypoint to attempt auto-download"
if echo "${out}" | grep -q "ERROR: Missing server jar"; then
  fail "auto-download mode should not prefix missing server jar with ERROR"
fi
if echo "${out}" | grep -q "ERROR: Missing assets"; then
  fail "auto-download mode should not prefix missing assets with ERROR"
fi
echo "${out}" | grep -q "must start with https://downloader.hytale.com/" || fail "expected downloader URL allowlist error"
pass "auto-download rejects non-official downloader URL"
rm -rf "${workdir2}"

# Test 4b: auto-update is enabled by default when files are present
workdir2b="$(mktemp -d)"
chmod 0777 "${workdir2b}"
mkdir -p "${workdir2b}/server"
: > "${workdir2b}/Assets.zip"
: > "${workdir2b}/server/HytaleServer.jar"
set +e
out="$(docker run --rm \
  -e HYTALE_AUTO_DOWNLOAD=true \
  -e HYTALE_DOWNLOADER_URL=https://example.com/hytale-downloader.zip \
  -v "${workdir2b}:/data" "${IMAGE_NAME}" 2>&1)"
status=$?
set -e
[ ${status} -ne 0 ] || fail "expected non-zero exit status when auto-update attempts downloader with invalid URL"
echo "${out}" | grep -q "Attempting auto-download via official Hytale Downloader" || fail "expected entrypoint to attempt auto-download when files exist"
echo "${out}" | grep -q "server files already present; checking for updates" || fail "expected auto-download to check for updates when files exist"
echo "${out}" | grep -q "must start with https://downloader.hytale.com/" || fail "expected downloader URL allowlist error"
pass "auto-update runs downloader when files exist"
rm -rf "${workdir2b}"

# Test 4c: auto-update can be disabled via HYTALE_AUTO_UPDATE=false
workdir2c="$(mktemp -d)"
chmod 0777 "${workdir2c}"
mkdir -p "${workdir2c}/server"
: > "${workdir2c}/Assets.zip"
: > "${workdir2c}/server/HytaleServer.jar"
set +e
out="$(docker run --rm \
  -e HYTALE_AUTO_DOWNLOAD=true \
  -e HYTALE_AUTO_UPDATE=false \
  -e HYTALE_DOWNLOADER_URL=https://example.com/hytale-downloader.zip \
  -v "${workdir2c}:/data" "${IMAGE_NAME}" 2>&1)"
status=$?
set -e
[ ${status} -ne 0 ] || fail "expected non-zero exit status due to dummy jar"
if echo "${out}" | grep -q "Attempting auto-download via official Hytale Downloader"; then
  fail "did not expect entrypoint to attempt auto-download when HYTALE_AUTO_UPDATE=false"
fi
if echo "${out}" | grep -q "must start with https://downloader.hytale.com/"; then
  fail "did not expect downloader URL allowlist error when HYTALE_AUTO_UPDATE=false"
fi
echo "${out}" | grep -q "Starting Hytale dedicated server" || fail "expected server start log when auto-update disabled"
pass "auto-update can be disabled"
rm -rf "${workdir2c}"

# Test 5: auto-download must fail fast on arm64 without attempting network calls
# Use HYTALE_TEST_ARCH to simulate arm64 on any runner.
workdir3="$(mktemp -d)"
chmod 0777 "${workdir3}"
set +e
out="$(docker run --rm \
  --entrypoint /usr/local/bin/hytale-auto-download \
  -e HYTALE_TEST_ARCH=aarch64 \
  -v "${workdir3}:/data" \
  "${IMAGE_NAME}" 2>&1)"
status=$?
set -e
[ ${status} -ne 0 ] || fail "expected non-zero exit status when auto-download is forced to arm64"
echo "${out}" | grep -q "Auto-download is not supported on arm64" || fail "expected arm64 unsupported error"
echo "${out}" | grep -q "provide server files and Assets.zip manually" || fail "expected manual provisioning hint on arm64"
pass "auto-download fails fast on arm64"
rm -rf "${workdir3}"

# Test 6: stale auto-download lock must be removed automatically
workdir4="$(mktemp -d)"
chmod 0777 "${workdir4}"
mkdir -p "${workdir4}/.hytale-download-lock"
now_epoch="$(date +%s)"
stale_epoch=$((now_epoch - 600))
printf '%s\n' "${stale_epoch}" >"${workdir4}/.hytale-download-lock/created_at_epoch"

set +e
out="$(docker run --rm \
  --entrypoint /usr/local/bin/hytale-auto-download \
  -v "${workdir4}:/data" \
  -e HYTALE_DOWNLOADER_URL=https://example.com/hytale-downloader.zip \
  "${IMAGE_NAME}" 2>&1)"
status=$?
set -e

[ ${status} -ne 0 ] || fail "expected non-zero exit status due to invalid HYTALE_DOWNLOADER_URL"
echo "${out}" | grep -q "stale lock detected" || fail "expected stale lock removal log"
pass "stale lock is removed automatically"
rm -rf "${workdir4}"

# Test 7: tokens must never be logged as values
TOKEN_VALUE="super-secret-token"
: > "${workdir}/server/HytaleServer.aot" || true
set +e
out="$(docker run --rm \
  -e HYTALE_SERVER_SESSION_TOKEN="${TOKEN_VALUE}" \
  -e HYTALE_SERVER_IDENTITY_TOKEN="${TOKEN_VALUE}" \
  -v "${workdir}:/data" "${IMAGE_NAME}" 2>&1)"
status=$?
set -e
[ ${status} -ne 0 ] || fail "expected java to fail with dummy jar, but got status 0"
echo "${out}" | grep -q "\[set\]" || fail "expected token placeholders in logs"
if echo "${out}" | grep -q "${TOKEN_VALUE}"; then
  fail "token value was logged"
fi
pass "token values are not logged"

# Test 8: machine-id is generated and persisted
workdir5="$(mktemp -d)"
chmod 0777 "${workdir5}"
mkdir -p "${workdir5}/server"
: > "${workdir5}/Assets.zip"
: > "${workdir5}/server/HytaleServer.jar"
set +e
out="$(docker run --rm -v "${workdir5}:/data" "${IMAGE_NAME}" 2>&1)"
status=$?
set -e
[ ${status} -ne 0 ] || fail "expected java to fail with dummy jar"
[ -f "${workdir5}/.machine-id" ] || fail "expected .machine-id to be created"
machine_id="$(cat "${workdir5}/.machine-id")"
[ "${#machine_id}" -eq 32 ] || fail "expected machine-id to be 32 characters, got ${#machine_id}"
echo "${machine_id}" | grep -qE '^[0-9a-f]{32}$' || fail "expected machine-id to be lowercase hex"
if echo "${out}" | grep -q "${machine_id}"; then
  fail "machine-id value should not be logged"
fi
pass "machine-id is generated and persisted"

# Test 8b: machine-id is stable across restarts
set +e
out2="$(docker run --rm -v "${workdir5}:/data" "${IMAGE_NAME}" 2>&1)"
status=$?
set -e
[ ${status} -ne 0 ] || fail "expected java to fail with dummy jar"
machine_id2="$(cat "${workdir5}/.machine-id")"
[ "${machine_id}" = "${machine_id2}" ] || fail "expected machine-id to be stable, got ${machine_id} vs ${machine_id2}"
pass "machine-id is stable across restarts"

# Test 8c: HYTALE_MACHINE_ID can override machine-id
CUSTOM_MACHINE_ID="0123456789abcdef0123456789abcdef"
set +e
out3="$(docker run --rm -e HYTALE_MACHINE_ID="${CUSTOM_MACHINE_ID}" -v "${workdir5}:/data" "${IMAGE_NAME}" 2>&1)"
status=$?
set -e
[ ${status} -ne 0 ] || fail "expected java to fail with dummy jar"
machine_id3="$(cat "${workdir5}/.machine-id")"
[ "${machine_id3}" = "${CUSTOM_MACHINE_ID}" ] || fail "expected custom machine-id to be used, got ${machine_id3}"
if echo "${out3}" | grep -q "${CUSTOM_MACHINE_ID}"; then
  fail "custom machine-id value should not be logged"
fi
pass "HYTALE_MACHINE_ID can override machine-id"

rm -rf "${workdir5}"

rm -rf "${workdir}"
pass "all tests"
