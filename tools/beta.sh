#!/bin/zsh
# tools/beta.sh
# Uploads HEAD with tools/testflight.sh, waits for App Store Connect to process it, adds it to the
# Public TestFlight group, sets its What to Test notes, and submits it for beta review. Needs
# ASC_KEY_ID and ASC_ISSUER_ID, and uv.
#
#   tools/beta.sh [notes.txt]
#
# Without a notes file, the notes are the subjects of the commits since the last uploaded build.
set -euo pipefail
cd "$(dirname "$0")/.."
app=6828032393
group=69dfbd85-333b-48df-b85c-cbbed71fc620
asc() { uv run -q tools/asc.py "$@"; }

v=$(git rev-list --count HEAD)
if [[ -n ${1:-} ]]; then
  notes=$(<$1)
else
  last=$(asc GET "/v1/builds?filter%5Bapp%5D=$app&sort=-version&limit=1&fields%5Bbuilds%5D=version" | sed 1d |
    python3 -c "import json,sys; d=json.load(sys.stdin)['data']; print(d[0]['attributes']['version'] if d else 0)")
  # The build number is the commit count, so the last build's commit is the one with that count.
  base=$(git rev-list HEAD | while read -r c; do [[ $(git rev-list --count $c) == $last ]] && { echo $c; break; }; done)
  notes=$(git log --no-merges --format='• %s' ${base:+$base..}HEAD | head -40)
fi
[[ -n $notes ]] || { echo "no notes for build $v" >&2; exit 1; }
echo "What to Test for build $v:\n$notes"

tools/testflight.sh
for i in {1..60}; do
  found=$(asc GET "/v1/builds?filter%5Bapp%5D=$app&filter%5Bversion%5D=$v&fields%5Bbuilds%5D=processingState" | sed 1d |
    python3 -c "import json,sys; d=json.load(sys.stdin)['data']; print(d[0]['id'] + ' ' + d[0]['attributes']['processingState'] if d else '')")
  [[ $found == *VALID ]] && break
  sleep 60
done
[[ $found == *VALID ]] || { echo "build $v did not finish processing" >&2; exit 1; }
id=${found% *}
echo "build $v processed: $id"

# A just-processed build can 404 here for a minute or two.
added=
for i in {1..10}; do
  [[ $(asc POST /v1/betaGroups/$group/relationships/builds "{\"data\":[{\"type\":\"builds\",\"id\":\"$id\"}]}" | head -1) == 204 ]] && { added=1; break; }
  sleep 60
done
[[ -n $added ]] || { echo "could not add build $v to the Public group" >&2; exit 1; }
echo "added to the Public group"

loc=$(asc GET "/v1/builds/$id/betaBuildLocalizations" | sed 1d |
  python3 -c "import json,sys; d=json.load(sys.stdin)['data']; print(next((l['id'] for l in d if l['attributes']['locale'] == 'en-US'), ''))")
body=$(NOTES=$notes BUILD=$id LOC=$loc python3 -c "
import json, os
attrs = {'whatsNew': os.environ['NOTES'][:4000]}
if os.environ['LOC']:
    data = {'type': 'betaBuildLocalizations', 'id': os.environ['LOC'], 'attributes': attrs}
else:
    data = {'type': 'betaBuildLocalizations', 'attributes': {**attrs, 'locale': 'en-US'},
            'relationships': {'build': {'data': {'type': 'builds', 'id': os.environ['BUILD']}}}}
print(json.dumps({'data': data}))")
if [[ -n $loc ]]; then asc PATCH /v1/betaBuildLocalizations/$loc "$body" | head -1
else asc POST /v1/betaBuildLocalizations "$body" | head -1; fi
echo "set What to Test"
asc POST /v1/betaAppReviewSubmissions "{\"data\":{\"type\":\"betaAppReviewSubmissions\",\"relationships\":{\"build\":{\"data\":{\"type\":\"builds\",\"id\":\"$id\"}}}}}" | head -1
