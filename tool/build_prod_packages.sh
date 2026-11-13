#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${ROOT_DIR}/.env.dart.define.json"
OUTPUT_ROOT="${ROOT_DIR}/dist/prod_packages"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_DIR="${OUTPUT_ROOT}/${TIMESTAMP}"
PLATFORMS="android,ios,macos,windows,linux"
RUN_CLEAN=true
APPSTORE_ARCHIVE=""

print_help() {
  cat <<'EOF'
Usage: tool/build_prod_packages.sh [options]

Build production Flutter packages and copy them to a timestamped folder.

Options:
  --env-file <path>      Path to dart define json file
                          (default: .env.dart.define.json)
  --platforms <list>     Comma-separated list: android,android-playstore,ios,ios-appstore,macos,macos-appstore,windows,linux
                           (default: all)
  --archive-path <path>  Archive used by ios-appstore-upload or macos-appstore-upload
  --no-clean             Skip flutter clean + flutter pub get
  --output-dir <path>    Output base directory (default: dist/prod_packages)
  -h, --help             Show this help

Environment for App Store Connect signing:
  APP_STORE_CONNECT_API_KEY_PATH       Optional path to App Store Connect .p8 key
  APP_STORE_CONNECT_API_KEY_ID         Key ID for the .p8 key
  APP_STORE_CONNECT_API_ISSUER_ID      Issuer ID for the .p8 key

  Aliases are also accepted: ASC_API_KEY_PATH, ASC_API_KEY_ID, ASC_API_ISSUER_ID.

Examples:
  tool/build_prod_packages.sh
  tool/build_prod_packages.sh --platforms android,macos
  tool/build_prod_packages.sh --env-file .env.prod.json --output-dir dist/releases
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    --platforms)
      PLATFORMS="$2"
      shift 2
      ;;
    --no-clean)
      RUN_CLEAN=false
      shift
      ;;
    --archive-path)
      APPSTORE_ARCHIVE="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_ROOT="$2"
      OUTPUT_DIR="${OUTPUT_ROOT}/${TIMESTAMP}"
      shift 2
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      print_help
      exit 1
      ;;
  esac
done

if [[ "${ENV_FILE}" != /* ]]; then
  ENV_FILE="${ROOT_DIR}/${ENV_FILE}"
fi

if [[ "${OUTPUT_ROOT}" != /* ]]; then
  OUTPUT_ROOT="${ROOT_DIR}/${OUTPUT_ROOT}"
  OUTPUT_DIR="${OUTPUT_ROOT}/${TIMESTAMP}"
fi

if [[ -n "${APPSTORE_ARCHIVE}" && "${APPSTORE_ARCHIVE}" != /* ]]; then
  APPSTORE_ARCHIVE="${ROOT_DIR}/${APPSTORE_ARCHIVE}"
fi

# Every release job builds through this script, including the self-hosted
# iOS/macOS ones that have no `flutter-action` step and would otherwise use
# whatever Flutter the machine happens to have. The version that ships must be
# the one the repo declares, so resolve the pinned SDK if it is available and
# then verify the version regardless of how `flutter` was found.
PINNED_FLUTTER="$(sed -n 's/.*"flutter"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${ROOT_DIR}/.fvmrc" 2>/dev/null | head -1)"
if [[ -z "${PINNED_FLUTTER}" ]]; then
  echo "Could not read the pinned Flutter version from ${ROOT_DIR}/.fvmrc"
  exit 1
fi

# Prefer an fvm-provided SDK matching the pin. Prepending to PATH keeps every
# bare `flutter` call below unchanged.
for candidate in \
  "${ROOT_DIR}/.fvm/flutter_sdk/bin" \
  "${HOME:-}/fvm/versions/${PINNED_FLUTTER}/bin" \
  "${HOME:-}/.fvm/versions/${PINNED_FLUTTER}/bin"; do
  if [[ -x "${candidate}/flutter" ]]; then
    PATH="${candidate}:${PATH}"
    break
  fi
done

if ! command -v flutter >/dev/null 2>&1; then
  echo "flutter command not found in PATH"
  echo "Install Flutter ${PINNED_FLUTTER} (see AGENTS.md), or run via fvm."
  exit 1
fi

ACTUAL_FLUTTER="$(flutter --version 2>/dev/null | sed -n 's/^Flutter \([^ ]*\).*/\1/p' | head -1)"
if [[ "${ACTUAL_FLUTTER}" != "${PINNED_FLUTTER}" ]]; then
  echo "Flutter version mismatch: this repository pins ${PINNED_FLUTTER} (.fvmrc),"
  echo "but the resolved toolchain is ${ACTUAL_FLUTTER:-unknown} ($(command -v flutter))."
  echo
  echo "Release artifacts must be built with the pinned toolchain. Either:"
  echo "  - install it and retry:  fvm install ${PINNED_FLUTTER} && fvm use ${PINNED_FLUTTER}"
  echo "  - or, to move the pin deliberately, follow the upgrade procedure in AGENTS.md."
  exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Env file not found: ${ENV_FILE}"
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"

build_args=(--release --dart-define-from-file="${ENV_FILE}")

copy_if_exists() {
  local src="$1"
  local dest="$2"
  if [[ -e "${src}" ]]; then
    cp -R "${src}" "${dest}"
    echo "Saved: ${dest}"
  else
    echo "Artifact not found: ${src}"
    return 1
  fi
}

zip_dir() {
  local src_dir="$1"
  local zip_target="$2"
  if command -v zip >/dev/null 2>&1; then
    (
      cd "$(dirname -- "${src_dir}")"
      zip -r "${zip_target}" "$(basename -- "${src_dir}")" >/dev/null
    )
    echo "Saved: ${zip_target}"
  else
    echo "zip command not found; cannot package: ${src_dir}"
    return 1
  fi
}

local_export_options() {
  local source="$1"
  local destination="$2"
  cp "${source}" "${destination}"
  /usr/libexec/PlistBuddy -c "Set :destination export" "${destination}"
}

run_xcodebuild_filtered() {
  local filter_regex="$1"
  shift

  local xcodebuild_status=0
  local full_log
  full_log="$(mktemp -t xcodebuild.XXXXXX)"
  set +e
  "$@" 2>&1 | tee "${full_log}" | grep -E "${filter_regex}"
  xcodebuild_status=${PIPESTATUS[0]}
  set -e

  if [[ "${xcodebuild_status}" -ne 0 ]]; then
    # The filter can drop the line that explains the failure (a failed script
    # phase, a signing problem), so show the unfiltered tail as well.
    echo "xcodebuild failed with exit code ${xcodebuild_status}; last 80 lines of its output:"
    tail -n 80 "${full_log}"
  fi
  rm -f "${full_log}"

  return "${xcodebuild_status}"
}

app_store_connect_api_args=()

configure_app_store_connect_api_args() {
  app_store_connect_api_args=()

  local key_path="${APP_STORE_CONNECT_API_KEY_PATH:-${ASC_API_KEY_PATH:-}}"
  local key_id="${APP_STORE_CONNECT_API_KEY_ID:-${ASC_API_KEY_ID:-}}"
  local issuer_id="${APP_STORE_CONNECT_API_ISSUER_ID:-${ASC_API_ISSUER_ID:-}}"
  local configured_count=0

  [[ -n "${key_path}" ]] && configured_count=$((configured_count + 1))
  [[ -n "${key_id}" ]] && configured_count=$((configured_count + 1))
  [[ -n "${issuer_id}" ]] && configured_count=$((configured_count + 1))

  if [[ "${configured_count}" -eq 0 ]]; then
    return 0
  fi

  if [[ "${configured_count}" -ne 3 ]]; then
    cat <<'EOF'
Incomplete App Store Connect API auth.
Set all of:
  APP_STORE_CONNECT_API_KEY_PATH
  APP_STORE_CONNECT_API_KEY_ID
  APP_STORE_CONNECT_API_ISSUER_ID
or aliases:
  ASC_API_KEY_PATH
  ASC_API_KEY_ID
  ASC_API_ISSUER_ID
EOF
    exit 1
  fi

  if [[ "${key_path}" != /* ]]; then
    key_path="${ROOT_DIR}/${key_path}"
  fi

  if [[ ! -f "${key_path}" ]]; then
    echo "App Store Connect API key file not found: ${key_path}"
    exit 1
  fi

  app_store_connect_api_args=(
    -authenticationKeyPath "${key_path}"
    -authenticationKeyID "${key_id}"
    -authenticationKeyIssuerID "${issuer_id}"
  )
}

preflight_macos_appstore_signing() {
  local team_id="$1"

  if ! command -v security >/dev/null 2>&1; then
    echo "security command not found; macOS App Store signing requires macOS keychain access."
    exit 1
  fi

  local identities
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"

  if ! grep -E "(Mac App Distribution|Apple Distribution|3rd Party Mac Developer Application)" <<<"${identities}" | grep -F "(${team_id})" >/dev/null; then
    cat <<EOF
Missing Mac App Store distribution signing identity for team ${team_id}.

Import a .p12 containing the distribution certificate and private key into an unlocked keychain accessible to this runner.
Accepted identities include:
  - Apple Distribution: ... (${team_id})
  - Mac App Distribution: ... (${team_id})
  - 3rd Party Mac Developer Application: ... (${team_id})

Verify on the runner with:
  security find-identity -v -p codesigning

Automatic signing also needs Developer Portal/App Store Connect auth to create/download Mac App Store provisioning profiles.
Use Xcode account auth on the runner, or set APP_STORE_CONNECT_API_KEY_PATH, APP_STORE_CONNECT_API_KEY_ID, and APP_STORE_CONNECT_API_ISSUER_ID.
EOF
    exit 1
  fi

  if [[ "${#app_store_connect_api_args[@]}" -gt 0 ]]; then
    echo "Using App Store Connect API key auth for xcodebuild."
  else
    echo "No App Store Connect API key env configured; xcodebuild will use the Xcode account on this runner."
  fi
}

IFS=',' read -r -a selected_platforms <<<"${PLATFORMS}"

echo "Output folder: ${OUTPUT_DIR}"
echo "Using env file: ${ENV_FILE}"
echo "Platforms: ${PLATFORMS}"

if [[ "${RUN_CLEAN}" == true ]]; then
  echo "Running flutter clean and flutter pub get..."
  (cd "${ROOT_DIR}" && flutter clean && flutter pub get)
fi

for raw_platform in "${selected_platforms[@]}"; do
  platform="$(echo "${raw_platform}" | tr '[:upper:]' '[:lower:]' | xargs)"

  case "${platform}" in
    android)
      echo "Building Android app bundle..."
      (cd "${ROOT_DIR}" && flutter build appbundle "${build_args[@]}")
      copy_if_exists \
        "${ROOT_DIR}/build/app/outputs/bundle/release/app-release.aab" \
        "${OUTPUT_DIR}/password_manager-android-release.aab"

      echo "Building Android apk..."
      (cd "${ROOT_DIR}" && flutter build apk "${build_args[@]}")
      copy_if_exists \
        "${ROOT_DIR}/build/app/outputs/flutter-apk/app-release.apk" \
        "${OUTPUT_DIR}/password_manager-android-release.apk"
      ;;

    android-playstore)
      echo "Building Android app bundle for Play Store..."
      (cd "${ROOT_DIR}" && flutter build appbundle "${build_args[@]}")
      copy_if_exists \
        "${ROOT_DIR}/build/app/outputs/bundle/release/app-release.aab" \
        "${OUTPUT_DIR}/password_manager-android-release.aab"

      echo "Uploading to Google Play Store..."
      (cd "${ROOT_DIR}/android" && ./gradlew publishReleaseBundle)

      echo "Android Play Store upload complete."
      ;;

    ios)
      echo "Building iOS ipa..."
      (cd "${ROOT_DIR}" && flutter build ipa "${build_args[@]}")

      ipa_file="$(ls "${ROOT_DIR}"/build/ios/ipa/*.ipa 2>/dev/null | head -n 1 || true)"
      if [[ -n "${ipa_file}" ]]; then
        copy_if_exists "${ipa_file}" "${OUTPUT_DIR}/password_manager-ios-release.ipa"
      else
        echo "No .ipa found in build/ios/ipa"
      fi
      ;;

    ios-appstore)
      echo "Building iOS app for App Store..."
      ARCHIVE_PATH="${OUTPUT_DIR}/Runner-ios.xcarchive"
      EXPORT_PATH="${OUTPUT_DIR}/ios-appstore-export"
      EXPORT_OPTIONS="${ROOT_DIR}/ios/ExportOptions.plist"
      LOCAL_EXPORT_OPTIONS="${OUTPUT_DIR}/ios-export-options.plist"

      configure_app_store_connect_api_args
      ios_appstore_auth_args=(
        -allowProvisioningUpdates
        "${app_store_connect_api_args[@]}"
      )

      (cd "${ROOT_DIR}" && flutter build ios "${build_args[@]}" --no-codesign)

      echo "Archiving with xcodebuild..."
      run_xcodebuild_filtered "(error:|warning:|\*\* ARCHIVE (SUCCEEDED|FAILED) \*\*)" \
        xcodebuild archive \
        -workspace "${ROOT_DIR}/ios/Runner.xcworkspace" \
        -scheme Runner \
        -configuration Release \
        -destination "generic/platform=iOS" \
        -archivePath "${ARCHIVE_PATH}" \
        "${ios_appstore_auth_args[@]}" \
        CODE_SIGN_STYLE=Automatic \
        DEVELOPMENT_TEAM=A8QUU5F9G3

      local_export_options "${EXPORT_OPTIONS}" "${LOCAL_EXPORT_OPTIONS}"
      echo "Exporting iOS App Store artifact..."
      run_xcodebuild_filtered "(error:|warning:|\*\* EXPORT (SUCCEEDED|FAILED) \*\*|Uploaded)" \
        xcodebuild -exportArchive \
        -archivePath "${ARCHIVE_PATH}" \
        -exportOptionsPlist "${LOCAL_EXPORT_OPTIONS}" \
        -exportPath "${EXPORT_PATH}" \
        "${ios_appstore_auth_args[@]}"

      ipa_file="$(ls "${EXPORT_PATH}"/*.ipa 2>/dev/null | head -n 1 || true)"
      if [[ -n "${ipa_file}" ]]; then
        copy_if_exists "${ipa_file}" "${OUTPUT_DIR}/password_manager-ios-appstore.ipa"
      else
        echo "No .ipa found in ${EXPORT_PATH}"
        exit 1
      fi
      ;;

    ios-appstore-upload)
      if [[ ! -d "${APPSTORE_ARCHIVE}" ]]; then
        echo "iOS App Store archive not found: ${APPSTORE_ARCHIVE}"
        exit 1
      fi

      configure_app_store_connect_api_args
      (( ${#app_store_connect_api_args[@]} )) || {
        echo "App Store Connect API auth required for upload (set APP_STORE_CONNECT_API_KEY_PATH, APP_STORE_CONNECT_API_KEY_ID, APP_STORE_CONNECT_API_ISSUER_ID)"
        exit 1
      }
      echo "Uploading iOS archive to App Store Connect..."
      run_xcodebuild_filtered "(error:|warning:|\*\* EXPORT (SUCCEEDED|FAILED) \*\*|Uploaded)" \
        xcodebuild -exportArchive \
        -archivePath "${APPSTORE_ARCHIVE}" \
        -exportOptionsPlist "${ROOT_DIR}/ios/ExportOptions.plist" \
        -exportPath "${OUTPUT_DIR}/ios-appstore-upload" \
        -allowProvisioningUpdates \
        "${app_store_connect_api_args[@]}"
      ;;

    macos)
      echo "Building macOS app..."
      (cd "${ROOT_DIR}" && flutter build macos "${build_args[@]}")

      macos_app="${ROOT_DIR}/build/macos/Build/Products/Release/Custode.app"
      copy_if_exists "${macos_app}" "${OUTPUT_DIR}/password_manager-macos-release.app"
      zip_dir "${OUTPUT_DIR}/password_manager-macos-release.app" "${OUTPUT_DIR}/password_manager-macos-release.zip"
      ;;

    macos-appstore)
      echo "Building macOS app for App Store..."
      ARCHIVE_PATH="${OUTPUT_DIR}/Runner.xcarchive"
      EXPORT_PATH="${OUTPUT_DIR}/macos-appstore-export"
      EXPORT_OPTIONS="${ROOT_DIR}/macos/ExportOptions.plist"
      LOCAL_EXPORT_OPTIONS="${OUTPUT_DIR}/macos-export-options.plist"

      # Generate Flutter/Xcode config without signing. The archive step below
      # owns App Store signing with provisioning updates enabled.
      configure_app_store_connect_api_args
      preflight_macos_appstore_signing "A8QUU5F9G3"

      (cd "${ROOT_DIR}" && flutter build macos "${build_args[@]}" --config-only)

      macos_appstore_signing_args=(
        -allowProvisioningUpdates
        "${app_store_connect_api_args[@]}"
        CODE_SIGN_STYLE=Automatic
        DEVELOPMENT_TEAM=A8QUU5F9G3
      )

      echo "Archiving with xcodebuild..."
      run_xcodebuild_filtered "(error:|warning:|\*\* ARCHIVE (SUCCEEDED|FAILED) \*\*)" \
        xcodebuild archive \
        -workspace "${ROOT_DIR}/macos/Runner.xcworkspace" \
        -scheme Runner \
        -configuration Release \
        -destination "generic/platform=macOS" \
        -archivePath "${ARCHIVE_PATH}" \
        "${macos_appstore_signing_args[@]}"

      local_export_options "${EXPORT_OPTIONS}" "${LOCAL_EXPORT_OPTIONS}"
      echo "Exporting macOS App Store artifact..."
      run_xcodebuild_filtered "(error:|warning:|\*\* EXPORT (SUCCEEDED|FAILED) \*\*|Uploaded)" \
        xcodebuild -exportArchive \
        -archivePath "${ARCHIVE_PATH}" \
        -exportOptionsPlist "${LOCAL_EXPORT_OPTIONS}" \
        -exportPath "${EXPORT_PATH}" \
        "${macos_appstore_signing_args[@]}"

      pkg_file="$(ls "${EXPORT_PATH}"/*.pkg 2>/dev/null | head -n 1 || true)"
      if [[ -n "${pkg_file}" ]]; then
        copy_if_exists "${pkg_file}" "${OUTPUT_DIR}/password_manager-macos-appstore.pkg"
      else
        echo "No .pkg found in ${EXPORT_PATH}"
        exit 1
      fi
      ;;

    macos-appstore-upload)
      if [[ ! -d "${APPSTORE_ARCHIVE}" ]]; then
        echo "macOS App Store archive not found: ${APPSTORE_ARCHIVE}"
        exit 1
      fi

      configure_app_store_connect_api_args
      (( ${#app_store_connect_api_args[@]} )) || {
        echo "App Store Connect API auth required for upload (set APP_STORE_CONNECT_API_KEY_PATH, APP_STORE_CONNECT_API_KEY_ID, APP_STORE_CONNECT_API_ISSUER_ID)"
        exit 1
      }
      preflight_macos_appstore_signing "A8QUU5F9G3"
      echo "Uploading macOS archive to App Store Connect..."
      run_xcodebuild_filtered "(error:|warning:|\*\* EXPORT (SUCCEEDED|FAILED) \*\*|Uploaded)" \
        xcodebuild -exportArchive \
        -archivePath "${APPSTORE_ARCHIVE}" \
        -exportOptionsPlist "${ROOT_DIR}/macos/ExportOptions.plist" \
        -exportPath "${OUTPUT_DIR}/macos-appstore-upload" \
        -allowProvisioningUpdates \
        "${app_store_connect_api_args[@]}" \
        CODE_SIGN_STYLE=Automatic \
        DEVELOPMENT_TEAM=A8QUU5F9G3
      ;;

    windows)
      echo "Building Windows app..."
      native_host_out="${ROOT_DIR}/build/native_host/windows/keyvault_native_host.exe"
      (cd "${ROOT_DIR}" && NATIVE_HOST_OUT_PATH="${native_host_out}" ./tool/build_native_host.sh)
      (cd "${ROOT_DIR}" && flutter build windows "${build_args[@]}")

      windows_dir="${ROOT_DIR}/build/windows/x64/runner/Release"
      windows_bundle="${OUTPUT_DIR}/password_manager-windows-release"
      copy_if_exists "${windows_dir}" "${windows_bundle}"
      native_host_bundle="${windows_bundle}/desktop/native_host"
      mkdir -p "${native_host_bundle}/manifests/chrome"
      copy_if_exists "${native_host_out}" "${native_host_bundle}/keyvault_native_host.exe"
      copy_if_exists "${ROOT_DIR}/desktop/native_host/install_host_windows.ps1" "${native_host_bundle}/install_host_windows.ps1"
      copy_if_exists "${ROOT_DIR}/desktop/native_host/manifests/chrome/dev.camillobucciarelli.keyvault_native_host.json" "${native_host_bundle}/manifests/chrome/dev.camillobucciarelli.keyvault_native_host.json"
      ;;

    linux)
      echo "Building Linux app..."
      native_host_out="${ROOT_DIR}/build/native_host/linux/keyvault_native_host"
      (cd "${ROOT_DIR}" && NATIVE_HOST_OUT_PATH="${native_host_out}" ./tool/build_native_host.sh)
      (cd "${ROOT_DIR}" && flutter build linux "${build_args[@]}")

      linux_dir="${ROOT_DIR}/build/linux/x64/release/bundle"
      linux_bundle="${OUTPUT_DIR}/password_manager-linux-release"
      copy_if_exists "${linux_dir}" "${linux_bundle}"
      icon_bundle="${linux_bundle}/share/icons/hicolor/512x512/apps"
      mkdir -p "${icon_bundle}"
      copy_if_exists \
        "${ROOT_DIR}/linux/packaging/dev.camillobucciarelli.kdbxKeyVault.png" \
        "${icon_bundle}/dev.camillobucciarelli.kdbxKeyVault.png"
      native_host_bundle="${linux_bundle}/desktop/native_host"
      mkdir -p "${native_host_bundle}/manifests/chrome"
      copy_if_exists "${native_host_out}" "${native_host_bundle}/keyvault_native_host"
      copy_if_exists "${ROOT_DIR}/desktop/native_host/install_host_linux.sh" "${native_host_bundle}/install_host_linux.sh"
      copy_if_exists "${ROOT_DIR}/desktop/native_host/keyvault_native_host.sh" "${native_host_bundle}/keyvault_native_host.sh"
      copy_if_exists "${ROOT_DIR}/desktop/native_host/manifests/chrome/dev.camillobucciarelli.keyvault_native_host.json" "${native_host_bundle}/manifests/chrome/dev.camillobucciarelli.keyvault_native_host.json"
      zip_dir "${linux_bundle}" "${OUTPUT_DIR}/password_manager-linux-release.zip"
      ;;

    "")
      ;;

    *)
      echo "Unsupported platform: ${platform}"
      echo "Supported: android, android-playstore, ios, ios-appstore, ios-appstore-upload, macos, macos-appstore, macos-appstore-upload, windows, linux"
      exit 1
      ;;
  esac
done

echo "Done. Production packages are in: ${OUTPUT_DIR}"
