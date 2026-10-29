# /// script
# dependencies = ["pyjwt[crypto]", "requests"]
# ///
"""Calls the App Store Connect API: asc.py METHOD PATH [JSON_BODY]. Prints the status, then the body.

Reads ASC_KEY_ID and ASC_ISSUER_ID; the key is ~/.appstoreconnect/private_keys/AuthKey_<id>.p8.
"""
import json, os, sys, time
import jwt, requests

key_id, issuer = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"]
key = open(os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8")).read()
now = int(time.time())
token = jwt.encode({"iss": issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                   key, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})

method, path = sys.argv[1], sys.argv[2]
body = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
r = requests.request(method, "https://api.appstoreconnect.apple.com" + path,
                     headers={"Authorization": f"Bearer {token}"}, json=body, timeout=60)
print(r.status_code)
print(json.dumps(r.json(), indent=1) if r.content else "")
