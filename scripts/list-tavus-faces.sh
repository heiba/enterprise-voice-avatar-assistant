#!/usr/bin/env bash
# Lists the Tavus faces you can offer in the UI (chart value voiceAgent.faces): the stock faces by
# default, or your own with FACE_TYPE=user. The API key comes from TAVUS_API_KEY or from the
# assistant-integrations secret in NS and is never printed.
#   NS=voice-avatar-assistant scripts/list-tavus-faces.sh
#   FACE_TYPE=user NS=voice-avatar-assistant scripts/list-tavus-faces.sh
set -euo pipefail
NS="${NS:-voice-avatar-assistant}"
FACE_TYPE="${FACE_TYPE:-system}"
if [ -z "${TAVUS_API_KEY:-}" ]; then
  TAVUS_API_KEY=$(oc get secret assistant-integrations -n "$NS" -o jsonpath='{.data.TAVUS_API_KEY}' | base64 -d)
fi
[ -n "$TAVUS_API_KEY" ] || { echo "TAVUS_API_KEY is empty: export it or add it to secret assistant-integrations in $NS" >&2; exit 1; }
export TAVUS_API_KEY FACE_TYPE
python3 - <<'PY'
import json
import os
import urllib.error
import urllib.request

key, face_type = os.environ["TAVUS_API_KEY"], os.environ["FACE_TYPE"]


def get(url):
    request = urllib.request.Request(url, headers={"x-api-key": key})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def fetch(resource, type_param, id_key, name_key):
    page, items = 1, []
    while True:
        body = get(f"https://tavusapi.com/v2/{resource}?{type_param}={face_type}&verbose=true&limit=100&page={page}")
        data = body.get("data") or []
        items.extend(data)
        if not data or len(items) >= int(body.get("total_count") or 0):
            break
        page += 1
    return [(i.get(id_key, ""), i.get(name_key, ""), i.get("status", "")) for i in items]


try:
    faces = fetch("faces", "face_type", "face_id", "face_name")
except urllib.error.HTTPError as exc:
    if exc.code != 404:
        raise
    # older Tavus API generation: faces were called replicas
    faces = fetch("replicas", "replica_type", "replica_id", "replica_name")

faces = [f for f in faces if f[2] in ("", "completed")]
print(f"{'face id':<16} name")
for face_id, name, _ in sorted(faces, key=lambda f: f[1].lower()):
    print(f"{face_id:<16} {name}")
print(f"\n{len(faces)} {face_type} faces ready to use.")
print("Add the ones you want to chart values as voiceAgent.faces entries: id, name, gender (female|male).")
PY
