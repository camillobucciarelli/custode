#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 1 ]]; then
  echo "Usage: $0 <path-to-generated-safari-web-extension-folder>"
  echo "Example: $0 desktop/safari/generated/CustodeSafariAutofill/Shared (Extension)"
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
SRC_DIR="${REPO_ROOT}/desktop/browser_extension"
DEST_DIR_INPUT="$1"

if [[ "${DEST_DIR_INPUT}" = /* ]]; then
  DEST_DIR="${DEST_DIR_INPUT}"
else
  DEST_DIR="${REPO_ROOT}/${DEST_DIR_INPUT}"
fi

if [[ ! -d "${DEST_DIR}" ]]; then
  echo "Destination folder not found: ${DEST_DIR}"
  exit 1
fi

cp "${SRC_DIR}/manifest.json" "${DEST_DIR}/manifest.json"
cp "${SRC_DIR}/background.js" "${DEST_DIR}/background.js"
cp "${SRC_DIR}/content.js" "${DEST_DIR}/content.js"
cp "${SRC_DIR}/popup.html" "${DEST_DIR}/popup.html"
cp "${SRC_DIR}/popup.js" "${DEST_DIR}/popup.js"
cp "${SRC_DIR}/popup.css" "${DEST_DIR}/popup.css"

echo "Synced extension assets to: ${DEST_DIR}"
