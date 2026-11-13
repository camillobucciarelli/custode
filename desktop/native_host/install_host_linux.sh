#!/usr/bin/env bash
set -euo pipefail
umask 077

HOST_NAME="dev.camillobucciarelli.keyvault_native_host"
PUBLISHED_EXTENSION_ID="ogjmlkogmogijgpflnjifiobdmnmommh"

usage() {
  cat <<'USAGE'
Usage: install_host_linux.sh [--browser chrome|chromium|edge] [extension-id]

Installs the Custode native messaging host manifest for the current Linux user.
No sudo is required. Defaults: Google Chrome and the published extension ID.

Examples:
  ./desktop/native_host/install_host_linux.sh
  ./desktop/native_host/install_host_linux.sh abcdefghijklmnopabcdefghijklmnop
  ./desktop/native_host/install_host_linux.sh --browser chromium abcdefghijklmnopabcdefghijklmnop
  ./desktop/native_host/install_host_linux.sh --browser edge abcdefghijklmnopabcdefghijklmnop

Pass an extension ID from chrome://extensions or edge://extensions to override
the published ID when loading desktop/browser_extension in Developer mode.
USAGE
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

BROWSER="chrome"
EXTENSION_ID=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --browser)
      [[ "$#" -ge 2 ]] || die "--browser requires chrome, chromium or edge"
      BROWSER="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      die "Unknown option: $1"
      ;;
    *)
      [[ -z "${EXTENSION_ID}" ]] || die "Only one extension ID can be provided"
      EXTENSION_ID="$1"
      shift
      ;;
  esac
done

EXTENSION_ID="${EXTENSION_ID:-${PUBLISHED_EXTENSION_ID}}"

if [[ ! "${EXTENSION_ID}" =~ ^[a-p]{32}$ ]]; then
  die "Invalid extension ID '${EXTENSION_ID}'. Expected 32 lowercase characters from a to p."
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMPILED_HOST="${SCRIPT_DIR}/keyvault_native_host"
LAUNCHER="${SCRIPT_DIR}/keyvault_native_host.sh"
SOURCE_ENTRYPOINT="${SCRIPT_DIR}/../../tool/native_host.dart"

[[ -n "${HOME:-}" ]] || die "HOME is required to install the browser manifest"

case "${BROWSER}" in
  chrome)
    DEST_DIR="${HOME}/.config/google-chrome/NativeMessagingHosts"
    ;;
  chromium)
    DEST_DIR="${HOME}/.config/chromium/NativeMessagingHosts"
    ;;
  edge)
    DEST_DIR="${HOME}/.config/microsoft-edge/NativeMessagingHosts"
    ;;
  *)
    die "Unsupported browser '${BROWSER}'. Use chrome, chromium or edge."
    ;;
esac

TEMP_PATH=""
cleanup() {
  if [[ -n "${TEMP_PATH}" ]]; then
    rm -f -- "${TEMP_PATH}"
  fi
}
trap cleanup EXIT

if [[ -e "${COMPILED_HOST}" || -L "${COMPILED_HOST}" ]]; then
  [[ -f "${COMPILED_HOST}" ]] || die "Compiled native host is not a regular file: ${COMPILED_HOST}"

  DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
  [[ "${DATA_HOME}" = /* ]] || die "XDG_DATA_HOME must be an absolute path"

  HOST_INSTALL_DIR="${DATA_HOME}/keyvault/native-host"
  HOST_PATH="${HOST_INSTALL_DIR}/keyvault_native_host"
  mkdir -p -- "${HOST_INSTALL_DIR}"
  chmod 0700 "${HOST_INSTALL_DIR}"

  TEMP_PATH="$(mktemp "${HOST_INSTALL_DIR}/.keyvault_native_host.XXXXXX")"
  cp -- "${COMPILED_HOST}" "${TEMP_PATH}"
  chmod 0700 "${TEMP_PATH}"
  mv -f -- "${TEMP_PATH}" "${HOST_PATH}"
  TEMP_PATH=""
else
  [[ -f "${LAUNCHER}" && -f "${SOURCE_ENTRYPOINT}" ]] || \
    die "Compiled native host not found: ${COMPILED_HOST}. Build it with tool/build_native_host.sh."
  HOST_PATH="${LAUNCHER}"
  chmod u+x "${HOST_PATH}"
fi

mkdir -p "${DEST_DIR}"
DEST_PATH="${DEST_DIR}/${HOST_NAME}.json"

if [[ "${HOST_PATH}" =~ [[:cntrl:]] ]]; then
  die "Native host path contains characters unsupported by JSON"
fi
JSON_HOST_PATH="${HOST_PATH//\\/\\\\}"
JSON_HOST_PATH="${JSON_HOST_PATH//\"/\\\"}"

TEMP_PATH="$(mktemp "${DEST_DIR}/.${HOST_NAME}.json.XXXXXX")"
printf '{\n  "name": "%s",\n  "description": "%s",\n  "path": "%s",\n  "type": "stdio",\n  "allowed_origins": [\n    "chrome-extension://%s/"\n  ]\n}\n' \
  "${HOST_NAME}" \
  "Custode Native Messaging v2 host (metadata search and explicit fill)" \
  "${JSON_HOST_PATH}" \
  "${EXTENSION_ID}" >"${TEMP_PATH}"
chmod 0600 "${TEMP_PATH}"
mv -f -- "${TEMP_PATH}" "${DEST_PATH}"
TEMP_PATH=""

printf 'Installed Custode native messaging host for %s.\n' "${BROWSER}"
printf 'Manifest: %s\n' "${DEST_PATH}"
printf 'Host: %s\n' "${HOST_PATH}"
printf 'Allowed origin: chrome-extension://%s/\n' "${EXTENSION_ID}"
printf 'Restart the browser before testing the extension.\n'
