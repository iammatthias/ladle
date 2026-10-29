#!/bin/zsh
# sync-fixtures.sh [--check]
# Copies the protocol's replay fixtures, at the commit scripts/SPEC pins, into the test bundle, or
# with --check verifies the copy still matches them (exit 1 on drift, 0 with a note when the
# clone or the pinned commit is absent).
set -e
setopt NULL_GLOB
cd "$(dirname "$0")/.."
SPEC=${APRON_SPEC:-$HOME/Developer/forks/apron-server-go/testdata/apron}
PIN=$(awk '$1 == "apron" { print $2 }' scripts/SPEC)
FIXTURES=tests/fixtures/wire/replay
DST=Packages/ApronKit/Tests/ApronKitTests/Fixtures/wire/replay

if ! git -C "$SPEC" cat-file -e "$PIN^{commit}" 2>/dev/null; then
  echo "sync-fixtures: spec commit $PIN not found in $SPEC; skipping (fetch the clone)" >&2
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
git -C "$SPEC" archive "$PIN" "$FIXTURES" | tar -x -C "$TMP"
SRC=$TMP/$FIXTURES

if [[ $1 == --check ]]; then
  if diff -rq "$SRC" "$DST" >/dev/null; then
    echo "sync-fixtures: $(ls "$DST"/*.json | wc -l | tr -d ' ') replay fixtures match the spec at ${PIN:0:7}"
  else
    echo "sync-fixtures: fixtures drifted from the spec at ${PIN:0:7}; run scripts/sync-fixtures.sh" >&2
    diff -rq "$SRC" "$DST" >&2
    exit 1
  fi
else
  mkdir -p "$DST"
  rm -f "$DST"/*.json
  cp "$SRC"/*.json "$DST"/
  echo "sync-fixtures: copied $(ls "$DST"/*.json | wc -l | tr -d ' ') replay fixtures from the spec at ${PIN:0:7}"
fi
