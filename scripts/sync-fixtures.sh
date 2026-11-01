#!/bin/zsh
# sync-fixtures.sh [--check]
# Copies the protocol's replay fixtures and its terminal screens (tests/fixtures/terminal.json), at
# the commit scripts/SPEC pins, into the test bundle, or with --check verifies the copies still
# match them (exit 1 on drift, 0 with a note when the clone or the pinned commit is absent).
set -e
setopt NULL_GLOB
cd "$(dirname "$0")/.."
PIN=$(awk '$1 == "apron" { print $2 }' scripts/SPEC)
# The first clone that has the pin: APRON_SPEC, the server's spec checkout, then the bare reference clone.
for SPEC in ${APRON_SPEC:-} $HOME/Developer/forks/apron-server-go/testdata/apron $HOME/.cache/apron-reference/shazow_apron.git; do
  git -C "$SPEC" cat-file -e "$PIN^{commit}" 2>/dev/null && break
done
FIXTURES=tests/fixtures/wire/replay
TERMINAL=tests/fixtures/terminal.json
BUNDLE=Packages/ApronKit/Tests/ApronKitTests/Fixtures
DST=$BUNDLE/wire/replay

if ! git -C "$SPEC" cat-file -e "$PIN^{commit}" 2>/dev/null; then
  echo "sync-fixtures: spec commit $PIN not found in $SPEC; skipping (fetch the clone)" >&2
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
git -C "$SPEC" archive "$PIN" "$FIXTURES" "$TERMINAL" | tar -x -C "$TMP"
SRC=$TMP/$FIXTURES

if [[ $1 == --check ]]; then
  if diff -rq "$SRC" "$DST" >/dev/null && cmp -s "$TMP/$TERMINAL" "$BUNDLE/terminal.json"; then
    echo "sync-fixtures: $(ls "$DST"/*.json | wc -l | tr -d ' ') replay fixtures and terminal.json match the spec at ${PIN:0:7}"
  else
    echo "sync-fixtures: fixtures drifted from the spec at ${PIN:0:7}; run scripts/sync-fixtures.sh" >&2
    diff -rq "$SRC" "$DST" >&2 || true
    cmp "$TMP/$TERMINAL" "$BUNDLE/terminal.json" >&2 || true
    exit 1
  fi
else
  mkdir -p "$DST"
  rm -f "$DST"/*.json
  cp "$SRC"/*.json "$DST"/
  cp "$TMP/$TERMINAL" "$BUNDLE/terminal.json"
  echo "sync-fixtures: copied $(ls "$DST"/*.json | wc -l | tr -d ' ') replay fixtures and terminal.json from the spec at ${PIN:0:7}"
fi
