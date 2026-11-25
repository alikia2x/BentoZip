#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE_SRC="${ROOT_DIR}/engine/bento7z"
ENGINE_BUILD="${ENGINE_BUILD_DIR:-${ENGINE_SRC}/build}"
BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}"
ARCH_MODE="${ARCH_MODE:-arm64}"

if [ ! -f "${ENGINE_SRC}/CMakeLists.txt" ]; then
  echo "error: Missing engine source at ${ENGINE_SRC}" >&2
  exit 1
fi

JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

echo "Building bento7z (${BUILD_TYPE}, arch=${ARCH_MODE})..."
cmake -S "${ENGINE_SRC}" -B "${ENGINE_BUILD}" \
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
  -DCMAKE_OSX_ARCHITECTURES="${ARCH_MODE}"
cmake --build "${ENGINE_BUILD}" --parallel "${JOBS}"

if [ ! -x "${ENGINE_BUILD}/bento7z" ] || [ ! -f "${ENGINE_BUILD}/7z.so" ]; then
  echo "error: Expected engine binaries missing in ${ENGINE_BUILD}" >&2
  exit 1
fi

echo "Engine ready: ${ENGINE_BUILD}/bento7z and ${ENGINE_BUILD}/7z.so"
