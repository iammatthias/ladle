#!/bin/zsh
# sync-fixtures.sh [--check]
# Copies the protocol's replay fixtures into the test bundle, or with --check verifies the copy
# still matches the spec clone (exit 1 on drift, 0 with a note when the clone is absent).
set -e
setopt NULL_GLOB
cd "$(dirname "$0")/.."
SRC=${APRON_SPEC:-$HOME/Developer/forks/apron-server-go/testdata/apron}/tests/fixtures/wire/replay
DST=Packages/ApronKit/Tests/ApronKitTests/Fixtures/wire/replay

if [[ ! -d $SRC ]]; then
  echo "sync-fixtures: spec clone not found at $SRC; skipping drift check" >&2
  exit 0
fi

if [[ $1 == --check ]]; then
  if diff -rq "$SRC" "$DST" >/dev/null; then
    echo "sync-fixtures: $(ls "$DST"/*.json | wc -l | tr -d ' ') replay fixtures match the spec clone"
  else
    echo "sync-fixtures: fixtures drifted from $SRC; run scripts/sync-fixtures.sh" >&2
    diff -rq "$SRC" "$DST" >&2
    exit 1
  fi
else
  mkdir -p "$DST"
  rm -f "$DST"/*.json
  cp "$SRC"/*.json "$DST"/
  echo "sync-fixtures: copied $(ls "$DST"/*.json | wc -l | tr -d ' ') replay fixtures"
fi
