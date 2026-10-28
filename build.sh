#!/bin/zsh
# build.sh [build|test]
# Builds or tests the Ladle scheme with DerivedData in ./build. Tests need a simulator: the
# "Ladle iPhone" device if it exists, else set DEST. A build with no simulator runtime falls
# back to the generic iOS Simulator destination.
set -o pipefail
cd "$(dirname "$0")"
ACTION=${1:-build}
SCHEME=${SCHEME:-Ladle}

if [[ $ACTION == test && -z $NO_FIXTURE_CHECK ]]; then
  scripts/sync-fixtures.sh --check || exit 1
fi

[[ -f Config/Domains.xcconfig ]] || cp Config/Domains.example.xcconfig Config/Domains.xcconfig
xcodegen generate -q

if [[ -z $DEST ]]; then
  if timeout 30 xcrun simctl list devices available 2>/dev/null | grep -q 'Ladle iPhone'; then
    DEST='platform=iOS Simulator,name=Ladle iPhone'
  elif [[ $ACTION == test ]]; then
    echo "no 'Ladle iPhone' simulator; create one or set DEST" >&2
    exit 1
  else
    DEST='generic/platform=iOS Simulator'
  fi
fi

xcodebuild -project Ladle.xcodeproj -scheme "$SCHEME" -destination "$DEST" \
  -derivedDataPath "${DERIVED_DATA:-build}" "$ACTION" 2>&1 \
  | grep -E "error:|warning: [^C]|BUILD|Test Case.*(passed|failed)|Test Suite.*(passed|failed)|Executed|TEST" \
  | grep -v "Could not read serialized" | head -"${LINES_MAX:-200}"
