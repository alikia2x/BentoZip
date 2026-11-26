#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PBXPROJ="${ROOT_DIR}/BentoZip.xcodeproj/project.pbxproj"
CHANGELOG_PATH="${ROOT_DIR}/CHANGELOG.md"

usage() {
  local msg="${1:-}"
  if [ -n "${msg}" ]; then
    echo "release: ${msg}" >&2
    echo "" >&2
  fi
  cat >&2 <<'EOF'
Usage: ./scripts/release.sh <major|minor|patch|x.y.z> [--dry-run] [--skip-changelog]

Bumps MARKETING_VERSION and increments CURRENT_PROJECT_VERSION in
BentoZip.xcodeproj/project.pbxproj, folds CHANGELOG.md [Unreleased] into
the new version, and prints commit/tag commands without touching git.
EOF
  exit 1
}

DRY_RUN=0
SKIP_CHANGELOG=0
TARGET=""

for arg in "$@"; do
  case "${arg}" in
    --dry-run)
      DRY_RUN=1
      ;;
    --skip-changelog)
      SKIP_CHANGELOG=1
      ;;
    -h|--help)
      usage
      ;;
    -*)
      usage "unknown option '${arg}'"
      ;;
    *)
      if [ -z "${TARGET}" ]; then
        TARGET="${arg}"
      else
        usage "unexpected argument '${arg}'"
      fi
      ;;
  esac
done

[ -n "${TARGET}" ] || usage "missing version argument"
[ -f "${PBXPROJ}" ] || usage "missing ${PBXPROJ}"

CURRENT_VERSION="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' "${PBXPROJ}" | head -n1 | tr -d '[:space:]')"
CURRENT_BUILD="$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([^;]*\);.*/\1/p' "${PBXPROJ}" | head -n1 | tr -d '[:space:]')"

[ -n "${CURRENT_VERSION}" ] || usage "could not read MARKETING_VERSION"
if ! [[ "${CURRENT_BUILD}" =~ ^[0-9]+$ ]]; then
  usage "invalid CURRENT_PROJECT_VERSION '${CURRENT_BUILD}'"
fi

CORE_VERSION="${CURRENT_VERSION%%-*}"
IFS='.' read -r CUR_MAJOR CUR_MINOR CUR_PATCH <<< "${CORE_VERSION}"
CUR_MAJOR="${CUR_MAJOR:-0}"
CUR_MINOR="${CUR_MINOR:-0}"
CUR_PATCH="${CUR_PATCH:-0}"

for part in "${CUR_MAJOR}" "${CUR_MINOR}" "${CUR_PATCH}"; do
  if ! [[ "${part}" =~ ^[0-9]+$ ]]; then
    usage "invalid current MARKETING_VERSION '${CURRENT_VERSION}'"
  fi
done

case "${TARGET}" in
  major)
    NEXT_VERSION="$((CUR_MAJOR + 1)).0.0"
    ;;
  minor)
    NEXT_VERSION="${CUR_MAJOR}.$((CUR_MINOR + 1)).0"
    ;;
  patch)
    NEXT_VERSION="${CUR_MAJOR}.${CUR_MINOR}.$((CUR_PATCH + 1))"
    ;;
  *)
    if ! [[ "${TARGET}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
      usage "'${TARGET}' is not a valid semver version"
    fi
    NEXT_VERSION="${TARGET}"
    ;;
esac

if [ "${NEXT_VERSION}" = "${CURRENT_VERSION}" ]; then
  usage "version is already ${CURRENT_VERSION}"
fi

NEXT_BUILD="$((CURRENT_BUILD + 1))"
RELEASE_DATE="$(date -u +%Y-%m-%d)"

if [ "${SKIP_CHANGELOG}" = "0" ]; then
  [ -f "${CHANGELOG_PATH}" ] || usage "missing ${CHANGELOG_PATH}"
  if ! grep -q '^## \[Unreleased\]$' "${CHANGELOG_PATH}"; then
    usage "CHANGELOG.md is missing '## [Unreleased]'"
  fi
fi

echo "BentoZip ${CURRENT_VERSION} (${CURRENT_BUILD}) -> ${NEXT_VERSION} (${NEXT_BUILD})"

if [ "${DRY_RUN}" = "1" ]; then
  echo "would update MARKETING_VERSION = ${NEXT_VERSION} and CURRENT_PROJECT_VERSION = ${NEXT_BUILD} in BentoZip.xcodeproj/project.pbxproj"
  if [ "${SKIP_CHANGELOG}" = "0" ]; then
    echo "would add \"## [${NEXT_VERSION}] - ${RELEASE_DATE}\" to CHANGELOG.md"
  fi
  echo "dry run: no files written"
  exit 0
fi

python3 - "${PBXPROJ}" "${CURRENT_VERSION}" "${NEXT_VERSION}" "${CURRENT_BUILD}" "${NEXT_BUILD}" <<'PYEOF'
import pathlib, re, sys

pbx_path = pathlib.Path(sys.argv[1])
cur_ver, next_ver, cur_build, next_build = sys.argv[2:6]
text = pbx_path.read_text(encoding="utf-8")

updated = re.sub(
    r"(MARKETING_VERSION\s*=\s*)[^;]+(;)",
    rf"\g<1>{next_ver}\g<2>",
    text,
)
updated = re.sub(
    r"(CURRENT_PROJECT_VERSION\s*=\s*)[0-9]+(;)",
    rf"\g<1>{next_build}\g<2>",
    updated,
)
if updated == text:
    raise SystemExit("No version fields updated in project.pbxproj")
pbx_path.write_text(updated, encoding="utf-8")
PYEOF

if [ "${SKIP_CHANGELOG}" = "0" ]; then
  python3 - "${CHANGELOG_PATH}" "${NEXT_VERSION}" "${RELEASE_DATE}" <<'PYEOF'
import pathlib, sys

changelog_path = pathlib.Path(sys.argv[1])
version = sys.argv[2]
date = sys.argv[3]
source = changelog_path.read_text(encoding="utf-8")

header = "## [Unreleased]"
start = source.find(header)
if start == -1:
    raise SystemExit('CHANGELOG.md is missing "## [Unreleased]"')

body_start = start + len(header)
next_heading = source.find("\n## [", body_start)
if next_heading == -1:
    body = source[body_start:].strip()
    rest = ""
else:
    body = source[body_start:next_heading].strip()
    rest = source[next_heading + 1:]

if not body:
    body = "- No user-facing changes recorded."

entry = f"## [{version}] - {date}\n\n{body}\n\n"
updated = f"{source[:start]}{header}\n\n{entry}{rest}"
changelog_path.write_text(updated, encoding="utf-8")
PYEOF
fi

echo ""
echo "Next steps:"
echo "  1. Review the changelog entry and commit the bump"
echo "  2. git tag -a v${NEXT_VERSION} -m \"v${NEXT_VERSION}\""
echo "  3. git push origin main v${NEXT_VERSION}"
echo ""
echo "Pushing the tag runs the release workflow: verify, build universal, sign, notarize, publish."
