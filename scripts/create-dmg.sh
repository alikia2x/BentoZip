#!/bin/bash
set -euo pipefail

usage() {
  echo "Usage: $0 <app_path> <dmg_output_path> [volume_name]" >&2
  exit 1
}

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  usage
fi

APP_PATH="$1"
DMG_OUT="$2"
VOLUME_NAME="${3:-BentoZip}"

if [ ! -d "${APP_PATH}" ]; then
  echo "error: App bundle not found at ${APP_PATH}" >&2
  exit 1
fi

APP_NAME="$(basename "${APP_PATH}")"
OUT_DIR="$(dirname "${DMG_OUT}")"
mkdir -p "${OUT_DIR}"

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bentoZip-dmg.XXXXXX")"
cleanup() {
  rm -rf "${STAGE_DIR}"
}
trap cleanup EXIT

echo "Staging ${APP_NAME} into ${STAGE_DIR}..."
ditto "${APP_PATH}" "${STAGE_DIR}/${APP_NAME}"
ln -s /Applications "${STAGE_DIR}/Applications"

rm -f "${DMG_OUT}"
echo "Creating DMG at ${DMG_OUT} (volume: ${VOLUME_NAME})..."
hdiutil create \
  -volname "${VOLUME_NAME}" \
  -srcfolder "${STAGE_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_OUT}"

echo "DMG created: ${DMG_OUT}"
