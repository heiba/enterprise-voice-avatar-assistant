"""First-run setup of n8n without a browser. Runs as a Job after n8n is healthy.

1. Creates the owner account (the call the setup page makes) when none exists.
2. Logs in and creates an API key, stored in a Kubernetes Secret for the scripts.
Every step is skipped when already done; nothing here fails the deployment for a
cluster where the owner was created by hand with another password.
"""

import base64
import http.cookiejar
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request

N8N = os.environ.get("N8N_URL", "http://n8n:5678").rstrip("/")
EMAIL = os.environ.get("N8N_OWNER_EMAIL", "")
PASSWORD = os.environ.get("N8N_OWNER_PASSWORD", "")
FIRST = os.environ.get("N8N_OWNER_FIRST_NAME", "Assistant")
LAST = os.environ.get("N8N_OWNER_LAST_NAME", "Admin")
NAMESPACE = os.environ["NAMESPACE"]
SECRET = os.environ.get("API_KEY_SECRET", "assistant-n8n-api")
SA = "/var/run/secrets/kubernetes.io/serviceaccount"

cookies = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cookies))


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def n8n(method, path, body=None, headers=None, timeout=30):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(N8N + path, data=data, method=method)
    request.add_header("Content-Type", "application/json")
    for k, v in (headers or {}).items():
        request.add_header(k, v)
    with opener.open(request, timeout=timeout) as response:
        raw = response.read()
        return json.loads(raw) if raw else {}


def wait_for_n8n():
    for _ in range(60):
        try:
            n8n("GET", "/healthz")
            return True
        except Exception as exc:  # noqa: BLE001
            log(f"waiting for n8n: {exc}")
            time.sleep(10)
    return False


def k8s(method, path, body=None, content_type="application/json"):
    with open(f"{SA}/token") as f:
        token = f.read().strip()
    ctx = ssl.create_default_context(cafile=f"{SA}/ca.crt")
    host = os.environ["KUBERNETES_SERVICE_HOST"]
    port = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(f"https://{host}:{port}{path}", data=data, method=method)
    request.add_header("Authorization", f"Bearer {token}")
    request.add_header("Content-Type", content_type)
    with urllib.request.urlopen(request, timeout=30, context=ctx) as response:
        raw = response.read()
        return json.loads(raw) if raw else {}


def stored_api_key():
    try:
        secret = k8s("GET", f"/api/v1/namespaces/{NAMESPACE}/secrets/{SECRET}")
        return base64.b64decode(secret.get("data", {}).get("N8N_API_KEY", "")).decode() or None
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise


def api_key_works(key):
    try:
        n8n("GET", "/api/v1/workflows?limit=1", headers={"X-N8N-API-KEY": key})
        return True
    except Exception:  # noqa: BLE001
        return False


def store_api_key(key):
    body = {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {"name": SECRET, "labels": {"app.kubernetes.io/part-of": "enterprise-voice-avatar-assistant"}},
        "type": "Opaque",
        "data": {"N8N_API_KEY": base64.b64encode(key.encode()).decode()},
    }
    try:
        k8s("POST", f"/api/v1/namespaces/{NAMESPACE}/secrets", body)
    except urllib.error.HTTPError as exc:
        if exc.code != 409:
            raise
        k8s("PATCH", f"/api/v1/namespaces/{NAMESPACE}/secrets/{SECRET}", {"data": body["data"]}, "application/merge-patch+json")


def login():
    for body in ({"emailOrLdapLoginId": EMAIL, "password": PASSWORD}, {"email": EMAIL, "password": PASSWORD}):
        try:
            n8n("POST", "/rest/login", body)
            return True
        except urllib.error.HTTPError as exc:
            if exc.code == 400:
                continue  # older or newer field name
            return False
    return False


def main():
    if not wait_for_n8n():
        log("n8n did not become healthy in 10 minutes")
        return 1
    settings = n8n("GET", "/rest/settings").get("data", {})
    needs_owner = settings.get("userManagement", {}).get("showSetupOnFirstLoad", False)
    if not EMAIL or not PASSWORD:
        log("no N8N_OWNER_EMAIL / N8N_OWNER_PASSWORD in the n8n secret; nothing to do (scripts/create-secrets.sh adds them)")
        return 0
    if needs_owner:
        n8n("POST", "/rest/owner/setup", {"email": EMAIL, "firstName": FIRST, "lastName": LAST, "password": PASSWORD})
        log(f"owner account created for {EMAIL}")
    else:
        log("owner account already exists")
        if not login():
            log("cannot log in with the credentials in the secret (owner created another way); leaving n8n as it is")
            return 0
    key = stored_api_key()
    if key and api_key_works(key):
        log(f"API key in secret {SECRET} works; nothing to do")
        return 0
    try:
        scopes = n8n("GET", "/rest/api-keys/scopes").get("data", [])
    except Exception:  # noqa: BLE001 - older n8n has no scoped keys
        scopes = []
    body = {"label": "assistant-setup", "expiresAt": None}
    if scopes:
        body["scopes"] = scopes
    created = n8n("POST", "/rest/api-keys", body).get("data", {})
    raw = created.get("rawApiKey") or created.get("apiKey")
    if not raw:
        log(f"API key creation returned no key: {json.dumps(created)[:200]}")
        return 1
    store_api_key(raw)
    log(f"API key created and stored in secret {SECRET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
