#!/bin/zsh
# tools/beta.sh
# Uploads HEAD with tools/testflight.sh, waits for App Store Connect to process it, adds it to the
# Public TestFlight group, and submits it for beta review. Needs ASC_KEY_ID and ASC_ISSUER_ID, and uv.
set -euo pipefail
cd "$(dirname "$0")/.."
app=6828032393
group=69dfbd85-333b-48df-b85c-cbbed71fc620
asc() { uv run -q tools/asc.py "$@"; }

tools/testflight.sh
v=$(git rev-list --count HEAD)
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
asc POST /v1/betaAppReviewSubmissions "{\"data\":{\"type\":\"betaAppReviewSubmissions\",\"relationships\":{\"build\":{\"data\":{\"type\":\"builds\",\"id\":\"$id\"}}}}}" | head -1
