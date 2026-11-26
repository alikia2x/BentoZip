#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE_SRC="${ROOT_DIR}/engine/bento7z"
ENGINE_BUILD="${ENGINE_BUILD_DIR:-${ENGINE_SRC}/build}"
BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}"
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

if [ ! -f "${ENGINE_SRC}/CMakeLists.txt" ]; then
  echo "error: Missing engine source at ${ENGINE_SRC}" >&2
  exit 1
fi

JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

if [ "${UNIVERSAL}" = "1" ]; then
  if ! command -v lipo >/dev/null 2>&1; then
    echo "error: 'lipo' is required for --universal builds" >&2
    exit 1
  fi

  DEPS_DIR="${ENGINE_BUILD}/_deps"
  ARM64_BUILD="${ENGINE_BUILD}/universal/arm64"
  X64_BUILD="${ENGINE_BUILD}/universal/x86_64"
  mkdir -p "${ENGINE_BUILD}" "${DEPS_DIR}"

  echo "Building bento7z (${BUILD_TYPE}, arch=arm64+x86_64 universal)..."
  cmake -S "${ENGINE_SRC}" -B "${ARM64_BUILD}" \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DCMAKE_OSX_ARCHITECTURES="arm64" \
    -DFETCHCONTENT_BASE_DIR="${DEPS_DIR}"
  cmake --build "${ARM64_BUILD}" --parallel "${JOBS}"

  cmake -S "${ENGINE_SRC}" -B "${X64_BUILD}" \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DCMAKE_OSX_ARCHITECTURES="x86_64" \
    -DFETCHCONTENT_BASE_DIR="${DEPS_DIR}"
  cmake --build "${X64_BUILD}" --parallel "${JOBS}"

  lipo -create "${ARM64_BUILD}/bento7z" "${X64_BUILD}/bento7z" -output "${ENGINE_BUILD}/bento7z"
  lipo -create "${ARM64_BUILD}/7z.so" "${X64_BUILD}/7z.so" -output "${ENGINE_BUILD}/7z.so"
  chmod +x "${ENGINE_BUILD}/bento7z"

  lipo -info "${ENGINE_BUILD}/bento7z"
  lipo -info "${ENGINE_BUILD}/7z.so"
else
  echo "Building bento7z (${BUILD_TYPE}, arch=${ARCH_MODE})..."
  cmake -S "${ENGINE_SRC}" -B "${ENGINE_BUILD}" \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DCMAKE_OSX_ARCHITECTURES="${ARCH_MODE}"
  cmake --build "${ENGINE_BUILD}" --parallel "${JOBS}"
fi

if [ ! -x "${ENGINE_BUILD}/bento7z" ] || [ ! -f "${ENGINE_BUILD}/7z.so" ]; then
  echo "error: Expected engine binaries missing in ${ENGINE_BUILD}" >&2
  exit 1
fi

echo "Engine ready: ${ENGINE_BUILD}/bento7z and ${ENGINE_BUILD}/7z.so"
