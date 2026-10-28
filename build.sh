#!/bin/zsh
# build.sh [build|test|shots <dir>]
# Builds or tests the Ladle scheme with DerivedData in ./build. Tests need a simulator: the
# "Ladle iPhone" device if it exists, else set DEST. A build with no simulator runtime falls
# back to the generic iOS Simulator destination.
# `shots <dir>` builds the LadleShots Mac Catalyst renderer and writes the design-review PNGs
# and contrast.json to <dir>; it needs no simulator.
set -o pipefail
cd "$(dirname "$0")"
ACTION=${1:-build}
SCHEME=${SCHEME:-Ladle}

if [[ $ACTION == shots ]]; then
  OUT=${2:?usage: build.sh shots <dir>}
  [[ -f Config/Domains.xcconfig ]] || cp Config/Domains.example.xcconfig Config/Domains.xcconfig
  xcodegen generate -q
  xcodebuild -project Ladle.xcodeproj -scheme LadleShots \
    -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
    -derivedDataPath "${DERIVED_DATA:-build}" build 2>&1 | grep -E "error:|BUILD" || exit 1
  OUT=${OUT:A}
  TZ=UTC LADLE_SHOTS_DIR=$OUT timeout 300 \
    "${DERIVED_DATA:-build}/Build/Products/Debug-maccatalyst/LadleShots.app/Contents/MacOS/LadleShots" 2>/dev/null
  ls "$OUT" | wc -l | xargs echo "files in $OUT:"
  exit
fi

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
