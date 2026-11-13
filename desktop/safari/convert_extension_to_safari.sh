#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
EXTENSION_DIR="${REPO_ROOT}/desktop/browser_extension"

APP_NAME="${1:-CustodeSafariAutofill}"
BUNDLE_ID="${2:-dev.camillobucciarelli.kdbxKeyVault.safari}"
OUT_DIR="${REPO_ROOT}/desktop/safari/generated"

mkdir -p "${OUT_DIR}"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun not found. Install Xcode command line tools first."
  exit 1
fi

echo "Converting Web Extension for Safari..."
echo "- App name: ${APP_NAME}"
echo "- Bundle ID: ${BUNDLE_ID}"
echo "- Source: ${EXTENSION_DIR}"
echo "- Output: ${OUT_DIR}"

xcrun safari-web-extension-converter "${EXTENSION_DIR}" \
  --project-location "${OUT_DIR}" \
  --app-name "${APP_NAME}" \
  --bundle-identifier "${BUNDLE_ID}" \
  --force

echo
echo "Done. Open generated project in Xcode, sign it, and run the container app once."
