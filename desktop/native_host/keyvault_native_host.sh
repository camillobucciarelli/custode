#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
HOST_BIN="${SCRIPT_DIR}/keyvault_native_host"
HOST_DART="${REPO_ROOT}/tool/native_host.dart"

log_error() {
  printf '[Custode native host] %s\n' "$*" >&2
}

run_dart_host() {
  local dart_bin="$1"
  if [[ -x "${dart_bin}" ]]; then
    exec "${dart_bin}" "${HOST_DART}"
  fi
  return 0
}

if [[ -x "${HOST_BIN}" ]]; then
  exec "${HOST_BIN}"
fi

if [[ -e "${HOST_BIN}" ]]; then
  log_error "compiled host is present but not executable: ${HOST_BIN}"
fi

if [[ ! -f "${HOST_DART}" ]]; then
  log_error "Dart native host entry point not found: ${HOST_DART}"
  exit 127
fi

# Development fallback. Keep stdout pristine for Native Messaging frames.
run_dart_host "${REPO_ROOT}/.fvm/flutter_sdk/bin/dart"

if FVM_FROM_PATH="$(command -v fvm 2>/dev/null || true)"; then
  if [[ -n "${FVM_FROM_PATH}" ]] && "${FVM_FROM_PATH}" dart --version >/dev/null 2>&1; then
    exec "${FVM_FROM_PATH}" dart "${HOST_DART}"
  fi
fi

if DART_FROM_PATH="$(command -v dart 2>/dev/null || true)"; then
  if [[ -n "${DART_FROM_PATH}" ]]; then
    run_dart_host "${DART_FROM_PATH}"
  fi
fi

if [[ -n "${HOME:-}" ]]; then
  # Last-resort user-local FVM installs. Avoid hardcoding a username.
  run_dart_host "${HOME}/fvm/versions/stable/bin/dart"
  run_dart_host "${HOME}/.fvm/versions/stable/bin/dart"
fi

log_error "Dart runtime not found. Build the native host with tool/build_native_host.sh or install Dart/Flutter/FVM."
exit 127
