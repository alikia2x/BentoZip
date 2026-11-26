#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

PBXPROJ="${ROOT_DIR}/BentoZip.xcodeproj/project.pbxproj"

parse_marketing_version() {
  sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' "${PBXPROJ}" | head -n1 | tr -d '[:space:]'
}

RAW_VERSION="${VERSION:-$(parse_marketing_version)}"
VERSION="${RAW_VERSION#v}"
if [ -z "${VERSION}" ]; then
  echo "error: Could not determine VERSION from env or ${PBXPROJ}" >&2
  exit 1
fi

HOST_ARCH="$(uname -m)"
ARCH_MODE="${ARCH_MODE:-${HOST_ARCH}}"
UNIVERSAL=0

for arg in "$@"; do
  case "${arg}" in
    --universal)
      UNIVERSAL=1
      ;;
    *)
      echo "error: Unknown option '${arg}' (supported: --universal)" >&2
      exit 1
      ;;
  esac
done

case "${ARCH_MODE}" in
  universal|"arm64;x86_64"|"x86_64;arm64"|"arm64 x86_64"|"x86_64 arm64")
    UNIVERSAL=1
    ;;
esac

if [ "${UNIVERSAL}" = "1" ]; then
  ENGINE_BUILD_ARGS=("--universal")
  XCODE_ARCHS="arm64 x86_64"
  ARTIFACT_ARCH="universal"
else
  ENGINE_BUILD_ARGS=()
  XCODE_ARCHS="${ARCH_MODE}"
  ARTIFACT_ARCH="${ARCH_MODE}"
fi

DO_CODESIGN="${CODESIGN:-0}"
DO_NOTARIZE="${NOTARIZE:-0}"
# Unset CODESIGN so xcodebuild does not treat it as the path to the codesign binary.
unset CODESIGN NOTARIZE
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/dist}"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-${ROOT_DIR}/build/DerivedData}"
STAGE_DIR="${STAGE_DIR:-${ROOT_DIR}/build/stage}"

if [ "${DO_CODESIGN}" != "0" ] && [ "${DO_CODESIGN}" != "1" ]; then
  echo "error: CODESIGN must be 0 or 1 (got '${DO_CODESIGN}')" >&2
  exit 1
fi

if [ "${DO_NOTARIZE}" != "0" ] && [ "${DO_NOTARIZE}" != "1" ]; then
  echo "error: NOTARIZE must be 0 or 1 (got '${DO_NOTARIZE}')" >&2
  exit 1
fi

if [ "${DO_CODESIGN}" = "1" ]; then
  : "${MACOS_DEVELOPER_ID:?MACOS_DEVELOPER_ID must be set when CODESIGN=1}"
  : "${APPLE_TEAM_ID:?APPLE_TEAM_ID must be set when CODESIGN=1}"
fi

if [ "${DO_NOTARIZE}" = "1" ]; then
  if [ "${DO_CODESIGN}" != "1" ]; then
    echo "error: NOTARIZE=1 requires CODESIGN=1" >&2
    exit 1
  fi
  : "${APPLE_ID:?APPLE_ID must be set when NOTARIZE=1}"
  : "${APPLE_TEAM_ID:?APPLE_TEAM_ID must be set when NOTARIZE=1}"
  : "${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD must be set when NOTARIZE=1}"
fi

mkdir -p "${OUT_DIR}" "${STAGE_DIR}"

echo "==> Step 1: Building bento7z engine (arch=${ARTIFACT_ARCH})"
ARCH_MODE="${ARCH_MODE}" "${ROOT_DIR}/scripts/build-engine.sh" "${ENGINE_BUILD_ARGS[@]+"${ENGINE_BUILD_ARGS[@]}"}"

echo "==> Step 2: Building BentoZip.app (Release, arch=${XCODE_ARCHS}, CODESIGN=${DO_CODESIGN})"
XCODEBUILD_ARGS=(
  -project "${ROOT_DIR}/BentoZip.xcodeproj"
  -scheme BentoZip
  -configuration Release
  -derivedDataPath "${DERIVED_DATA_DIR}"
  "ARCHS=${XCODE_ARCHS}"
  ONLY_ACTIVE_ARCH=NO
  CODE_SIGN_STYLE=Manual
)

if [ "${DO_CODESIGN}" = "1" ]; then
  XCODEBUILD_ARGS+=(
    "CODE_SIGN_IDENTITY=${MACOS_DEVELOPER_ID}"
    "DEVELOPMENT_TEAM=${APPLE_TEAM_ID}"
    "OTHER_CODE_SIGN_FLAGS=--timestamp"
  )
else
  XCODEBUILD_ARGS+=(
    "CODE_SIGN_IDENTITY=-"
  )
fi

env -u CODESIGN xcodebuild "${XCODEBUILD_ARGS[@]}" build

BUILT_APP="${DERIVED_DATA_DIR}/Build/Products/Release/BentoZip.app"
if [ ! -d "${BUILT_APP}" ]; then
  echo "error: Built app bundle not found at ${BUILT_APP}" >&2
  exit 1
fi

APP_OUT="${STAGE_DIR}/BentoZip.app"
echo "==> Step 3: Staging app bundle to ${APP_OUT}"
rm -rf "${APP_OUT}"
ditto "${BUILT_APP}" "${APP_OUT}"

if [ "${DO_CODESIGN}" = "1" ]; then
  echo "==> Step 4: Hardening runtime & signing inside-out"
  codesign --force --options runtime --timestamp --sign "${MACOS_DEVELOPER_ID}" "${APP_OUT}/Contents/Helpers/7z.so"
  codesign --force --options runtime --timestamp --sign "${MACOS_DEVELOPER_ID}" "${APP_OUT}/Contents/Helpers/bento7z"
  codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "${MACOS_DEVELOPER_ID}" "${APP_OUT}"
  codesign --verify --deep --strict --verbose=2 "${APP_OUT}"
fi

if [ "${DO_NOTARIZE}" = "1" ]; then
  echo "==> Step 5: Notarizing and stapling ${APP_OUT}"
  NOTARY_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bentoZip-notary.XXXXXX")"
  APP_NOTARY_ZIP="${NOTARY_TMP_DIR}/BentoZip-notary.zip"
  ditto -c -k --keepParent "${APP_OUT}" "${APP_NOTARY_ZIP}"
  xcrun notarytool submit "${APP_NOTARY_ZIP}" \
    --apple-id "${APPLE_ID}" \
    --team-id "${APPLE_TEAM_ID}" \
    --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
    --wait
  rm -rf "${NOTARY_TMP_DIR}"
  xcrun stapler staple "${APP_OUT}"
  xcrun stapler validate "${APP_OUT}"
  spctl -a -vvv -t exec "${APP_OUT}"
fi

ZIP_NAME="BentoZip-${VERSION}-macos-${ARTIFACT_ARCH}.zip"
DMG_NAME="BentoZip-${VERSION}-macos-${ARTIFACT_ARCH}.dmg"
ZIP_PATH="${OUT_DIR}/${ZIP_NAME}"
DMG_PATH="${OUT_DIR}/${DMG_NAME}"

echo "==> Step 6: Packaging ${ZIP_NAME} and ${DMG_NAME}"
rm -f "${ZIP_PATH}" "${DMG_PATH}" "${OUT_DIR}/SHA256SUMS.txt"
ditto -c -k --keepParent "${APP_OUT}" "${ZIP_PATH}"
"${ROOT_DIR}/scripts/create-dmg.sh" "${APP_OUT}" "${DMG_PATH}" "BentoZip"

if [ "${DO_CODESIGN}" = "1" ]; then
  echo "==> Step 7: Signing ${DMG_NAME}"
  codesign --force --timestamp --sign "${MACOS_DEVELOPER_ID}" "${DMG_PATH}"
fi

if [ "${DO_NOTARIZE}" = "1" ]; then
  echo "==> Step 8: Notarizing and stapling ${DMG_NAME}"
  xcrun notarytool submit "${DMG_PATH}" \
    --apple-id "${APPLE_ID}" \
    --team-id "${APPLE_TEAM_ID}" \
    --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
    --wait
  xcrun stapler staple "${DMG_PATH}"
  xcrun stapler validate "${DMG_PATH}"
fi

echo "==> Step 9: Generating SHA256SUMS.txt"
(
  cd "${OUT_DIR}"
  shasum -a 256 "${DMG_NAME}" "${ZIP_NAME}" > SHA256SUMS.txt
)

echo "Release artifacts ready in ${OUT_DIR}:"
ls -lh "${OUT_DIR}"
cat "${OUT_DIR}/SHA256SUMS.txt"
