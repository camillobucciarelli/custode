#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
MANIFEST="${ROOT_DIR}/desktop/native_host/production/dev.camillobucciarelli.keyvault_native_host.json"
OUTPUT_PATH="${ROOT_DIR}/dist/keyvault-chrome-support-macos.pkg"
PACKAGE_VERSION="${NATIVE_HOST_PACKAGE_VERSION:-1.0.0}"
PACKAGE_ID="dev.camillobucciarelli.keyvault.native-host"

usage() {
  cat <<'EOF'
Usage: bash tool/package_native_host_macos.sh [--output <path>] [--version <version>]

Builds, signs, notarizes, and staples universal Custode Chrome native-host pkg.

Required environment:
  DEVELOPER_ID_APPLICATION
  DEVELOPER_ID_INSTALLER
  APP_STORE_CONNECT_API_KEY_PATH (alias: ASC_API_KEY_PATH)
  APP_STORE_CONNECT_API_KEY_ID (alias: ASC_API_KEY_ID)
  APP_STORE_CONNECT_API_ISSUER_ID (alias: ASC_API_ISSUER_ID)

Optional environment:
  DART_BIN
  NATIVE_HOST_PACKAGE_VERSION (default: 1.0.0)
EOF
}

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

retry() {
  local attempts=3
  local delay=30
  local n=1
  until "$@"; do
    if (( n >= attempts )); then
      return 1
    fi
    printf 'Command failed (attempt %d/%d), retrying in %ds: %s\n' "$n" "$attempts" "$delay" "$*" >&2
    sleep "$delay"
    n=$(( n + 1 ))
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || fail "--output requires a path."
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || fail "--version requires a value."
      PACKAGE_VERSION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS is required."
[[ "${PACKAGE_VERSION}" =~ ^[0-9]+([.][0-9]+){0,3}$ ]] || \
  fail "Invalid package version '${PACKAGE_VERSION}'; use up to four numeric components."
[[ "${OUTPUT_PATH}" == *.pkg ]] || fail "Output path must end in .pkg."

for command_name in arch codesign curl ditto install lipo pkgbuild pkgutil plutil productsign security shasum xattr xcrun; do
  command -v "${command_name}" >/dev/null 2>&1 || fail "${command_name} command not found."
done
xcrun --find notarytool >/dev/null 2>&1 || fail "notarytool not found; install current Xcode command-line tools."
xcrun --find stapler >/dev/null 2>&1 || fail "stapler not found; install current Xcode command-line tools."

[[ -f "${MANIFEST}" ]] || fail "Production manifest not found: ${MANIFEST}"
plutil -convert json -o /dev/null "${MANIFEST}" || fail "Production manifest is invalid JSON: ${MANIFEST}"

APPLICATION_IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
INSTALLER_IDENTITY="${DEVELOPER_ID_INSTALLER:-}"
[[ -n "${APPLICATION_IDENTITY}" ]] || fail "DEVELOPER_ID_APPLICATION is required."
[[ -n "${INSTALLER_IDENTITY}" ]] || fail "DEVELOPER_ID_INSTALLER is required."
[[ "${APPLICATION_IDENTITY}" == "Developer ID Application: "* ]] || \
  fail "DEVELOPER_ID_APPLICATION must be a Developer ID Application certificate common name."
[[ "${INSTALLER_IDENTITY}" == "Developer ID Installer: "* ]] || \
  fail "DEVELOPER_ID_INSTALLER must be a Developer ID Installer certificate common name."

ASC_KEY_PATH="${APP_STORE_CONNECT_API_KEY_PATH:-${ASC_API_KEY_PATH:-}}"
ASC_KEY_ID="${APP_STORE_CONNECT_API_KEY_ID:-${ASC_API_KEY_ID:-}}"
ASC_ISSUER_ID="${APP_STORE_CONNECT_API_ISSUER_ID:-${ASC_API_ISSUER_ID:-}}"
[[ -n "${ASC_KEY_PATH}" ]] || fail "APP_STORE_CONNECT_API_KEY_PATH (or ASC_API_KEY_PATH) is required."
[[ -n "${ASC_KEY_ID}" ]] || fail "APP_STORE_CONNECT_API_KEY_ID (or ASC_API_KEY_ID) is required."
[[ -n "${ASC_ISSUER_ID}" ]] || fail "APP_STORE_CONNECT_API_ISSUER_ID (or ASC_API_ISSUER_ID) is required."

CODE_SIGNING_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
[[ "${CODE_SIGNING_IDENTITIES}" == *\"${APPLICATION_IDENTITY}\"* ]] || \
  fail "Developer ID Application identity not found in accessible keychains: ${APPLICATION_IDENTITY}"
INSTALLER_IDENTITIES="$(security find-identity -v -p basic 2>/dev/null || true)"
[[ "${INSTALLER_IDENTITIES}" == *\"${INSTALLER_IDENTITY}\"* ]] || \
  fail "Developer ID Installer identity not found in accessible keychains: ${INSTALLER_IDENTITY}"

if [[ "${ASC_KEY_PATH}" != /* ]]; then
  ASC_KEY_PATH="${ROOT_DIR}/${ASC_KEY_PATH}"
fi
[[ -f "${ASC_KEY_PATH}" ]] || fail "App Store Connect API key file not found: ${ASC_KEY_PATH}"

if [[ -n "${DART_BIN:-}" ]]; then
  command -v "${DART_BIN}" >/dev/null 2>&1 || fail "DART_BIN is not executable: ${DART_BIN}"
elif [[ -x "${ROOT_DIR}/.fvm/flutter_sdk/bin/dart" ]]; then
  DART_BIN="${ROOT_DIR}/.fvm/flutter_sdk/bin/dart"
else
  DART_BIN="$(command -v dart 2>/dev/null || true)"
  [[ -n "${DART_BIN}" ]] || fail "dart not found; install Dart/Flutter or set DART_BIN."
fi

if [[ "${OUTPUT_PATH}" != /* ]]; then
  OUTPUT_PATH="${ROOT_DIR}/${OUTPUT_PATH}"
fi
mkdir -p "$(dirname -- "${OUTPUT_PATH}")"
OUTPUT_PATH="$(cd -- "$(dirname -- "${OUTPUT_PATH}")" && pwd -P)/$(basename -- "${OUTPUT_PATH}")"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/keyvault-native-host.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT
ARM64_HOST="${WORK_DIR}/keyvault_native_host-arm64"
X64_HOST="${WORK_DIR}/keyvault_native_host-x64"
X64_SDK_ARCHIVE="${WORK_DIR}/dartsdk-macos-x64-release.zip"
X64_SDK_CHECKSUM="${X64_SDK_ARCHIVE}.sha256sum"
X64_SDK_DIR="${WORK_DIR}/x64-sdk"
PAYLOAD_ROOT="${WORK_DIR}/payload"
HOST_DIR="${PAYLOAD_ROOT}/Library/Application Support/KeyVault/NativeMessagingHosts"
# One manifest per Chromium-family browser: each reads its OWN system-level
# NativeMessagingHosts directory (Arc reads Chrome's, so it needs no entry
# of its own). Same content everywhere — only the directory differs.
MANIFEST_DIRS=(
  "${PAYLOAD_ROOT}/Library/Google/Chrome/NativeMessagingHosts"
  "${PAYLOAD_ROOT}/Library/Microsoft/Edge/NativeMessagingHosts"
  "${PAYLOAD_ROOT}/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"
  "${PAYLOAD_ROOT}/Library/Application Support/Vivaldi/NativeMessagingHosts"
  "${PAYLOAD_ROOT}/Library/Application Support/Chromium/NativeMessagingHosts"
  "${PAYLOAD_ROOT}/Library/Application Support/com.operasoftware.Opera/NativeMessagingHosts"
)
HOST_PATH="${HOST_DIR}/keyvault_native_host"
UNSIGNED_PACKAGE="${WORK_DIR}/keyvault-native-host-unsigned.pkg"

[[ "$(uname -m)" == "arm64" ]] || fail "Universal package build requires an Apple Silicon runner."
arch -x86_64 /usr/bin/true || fail "Rosetta 2 is required to build the x64 native host."

printf 'Compiling arm64 native host...\n'
(cd "${ROOT_DIR}" && "${DART_BIN}" compile exe tool/native_host.dart -o "${ARM64_HOST}")

DART_VERSION="$("${DART_BIN}" --version 2>&1 | sed -E 's/^Dart SDK version: ([^ ]+).*/\1/')"
[[ "${DART_VERSION}" =~ ^[0-9]+([.][0-9]+){2}$ ]] || fail "Unable to determine Dart SDK version."
DART_ARCHIVE_BASE="https://storage.googleapis.com/dart-archive/channels/stable/release/${DART_VERSION}/sdk"

printf 'Downloading verified Dart %s x64 SDK...\n' "${DART_VERSION}"
curl --fail --location --silent --show-error \
  "${DART_ARCHIVE_BASE}/dartsdk-macos-x64-release.zip" \
  --output "${X64_SDK_ARCHIVE}"
curl --fail --location --silent --show-error \
  "${DART_ARCHIVE_BASE}/dartsdk-macos-x64-release.zip.sha256sum" \
  --output "${X64_SDK_CHECKSUM}"
(cd "${WORK_DIR}" && shasum -a 256 -c "$(basename -- "${X64_SDK_CHECKSUM}")")

mkdir -p "${X64_SDK_DIR}"
ditto -x -k "${X64_SDK_ARCHIVE}" "${X64_SDK_DIR}"
X64_DART="${X64_SDK_DIR}/dart-sdk/bin/dart"
[[ -x "${X64_DART}" ]] || fail "Downloaded x64 Dart SDK is incomplete."

printf 'Compiling x64 native host under Rosetta...\n'
(cd "${ROOT_DIR}" && arch -x86_64 "${X64_DART}" compile exe tool/native_host.dart -o "${X64_HOST}")

install -d -m 0755 "${HOST_DIR}" "${MANIFEST_DIRS[@]}"
lipo -create "${ARM64_HOST}" "${X64_HOST}" -output "${HOST_PATH}"
# One architecture per call: newer lipo reads a second -verify_arch argument
# as another input file ("-verify_arch requires exactly one input file").
for host_arch in arm64 x86_64; do
  lipo "${HOST_PATH}" -verify_arch "${host_arch}"
done
chmod 0755 "${HOST_PATH}"
# Hardened runtime is required for notarization, but it kills Dart AOT
# binaries at launch (the runtime maps the embedded snapshot as executable
# memory) unless allow-unsigned-executable-memory is granted. See
# tool/native_host_macos.entitlements for the rationale.
#
# The entitlements also declare com.apple.security.application-groups
# (Team-ID-prefixed browser-store group only) so the signed host is a group
# *member* and Sequoia's App Data protection never prompts when it reads the
# store — Sequoia honors membership only for Team-ID-prefixed groups, which
# is why the store has its own group instead of the legacy shared one.
# Notarization accepts application-groups on Developer ID binaries (signed
# metadata, not a restricted entitlement — no provisioning profile involved).
# See tool/native_host_macos.entitlements for the full rationale.
HOST_ENTITLEMENTS="${SCRIPT_DIR}/native_host_macos.entitlements"
[[ -f "${HOST_ENTITLEMENTS}" ]] || fail "Host entitlements file not found: ${HOST_ENTITLEMENTS}"
plutil -lint "${HOST_ENTITLEMENTS}" || fail "Host entitlements file is invalid: ${HOST_ENTITLEMENTS}"
codesign --force --options runtime --timestamp \
  --entitlements "${HOST_ENTITLEMENTS}" \
  --sign "${APPLICATION_IDENTITY}" "${HOST_PATH}"
codesign --verify --strict --verbose=2 "${HOST_PATH}"
for manifest_dir in "${MANIFEST_DIRS[@]}"; do
  install -m 0644 "${MANIFEST}" "${manifest_dir}/$(basename -- "${MANIFEST}")"
done
# AGPL-3.0: ship the license alongside the separately distributed binary.
install -m 0644 "${ROOT_DIR}/LICENSE" "${HOST_DIR}/LICENSE"
install -m 0644 "${ROOT_DIR}/LICENSE-EXCEPTIONS.txt" "${HOST_DIR}/LICENSE-EXCEPTIONS.txt"
xattr -cr "${PAYLOAD_ROOT}"

COPYFILE_DISABLE=1 pkgbuild \
  --root "${PAYLOAD_ROOT}" \
  --identifier "${PACKAGE_ID}" \
  --version "${PACKAGE_VERSION}" \
  --install-location / \
  --ownership recommended \
  "${UNSIGNED_PACKAGE}"

rm -f "${OUTPUT_PATH}"
productsign --sign "${INSTALLER_IDENTITY}" --timestamp "${UNSIGNED_PACKAGE}" "${OUTPUT_PATH}"
pkgutil --check-signature "${OUTPUT_PATH}"

printf 'Submitting package for notarization...\n'
xcrun notarytool submit "${OUTPUT_PATH}" \
  --key "${ASC_KEY_PATH}" \
  --key-id "${ASC_KEY_ID}" \
  --issuer "${ASC_ISSUER_ID}" \
  --wait
retry xcrun stapler staple "${OUTPUT_PATH}" || fail "stapler staple failed after retries."
retry xcrun stapler validate "${OUTPUT_PATH}" || fail "stapler validate failed after retries."

printf 'Package ready: %s\n' "${OUTPUT_PATH}"
