#!/usr/bin/env bash
# gsc-auth.sh -- one-time OAuth helper to mint a Google Search Console
# refresh token for Igor's SEO analysis pass.
#
# Runs the OAuth "Desktop app" loopback flow LOCALLY (it needs a
# browser), so run it on your Mac/laptop -- NOT the headless server:
#   1. opens Google's consent screen for the webmasters.readonly scope
#   2. catches the loopback redirect and grabs the authorization code
#   3. exchanges it for a refresh token and prints it
#
# Then paste the three printed values into the agent's .env on the
# server: GSC_OAUTH_CLIENT_ID, GSC_OAUTH_CLIENT_SECRET,
# GSC_OAUTH_REFRESH_TOKEN. The refresh token is durable; access tokens
# are derived from it at runtime and never stored.
#
# This is a dev/onboarding utility -- it is NOT part of the tick.
#
# Client id/secret are read from the environment if set, otherwise
# prompted for. Override the loopback port with GSC_OAUTH_PORT.

set -euo pipefail

SCOPE="https://www.googleapis.com/auth/webmasters.readonly"
PORT="${GSC_OAUTH_PORT:-8765}"
REDIRECT="http://127.0.0.1:${PORT}"
AUTH_EP="https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_EP="https://oauth2.googleapis.com/token"

err() { printf 'gsc-auth: %s\n' "$*" >&2; }

command -v curl >/dev/null 2>&1 || { err "curl is required"; exit 1; }
command -v jq   >/dev/null 2>&1 || { err "jq is required"; exit 1; }

# url-encode via jq's @uri -- jq is a hard dep anyway.
urlencode() { jq -rn --arg x "$1" '$x|@uri'; }

# --- client credentials: env or interactive prompt ---
CLIENT_ID="${GSC_OAUTH_CLIENT_ID:-}"
CLIENT_SECRET="${GSC_OAUTH_CLIENT_SECRET:-}"
[ -n "$CLIENT_ID" ]     || { printf 'OAuth client ID: ';     read -r CLIENT_ID; }
[ -n "$CLIENT_SECRET" ] || { printf 'OAuth client secret: '; read -r CLIENT_SECRET; }
[ -n "$CLIENT_ID" ] && [ -n "$CLIENT_SECRET" ] \
  || { err "client id and secret are both required"; exit 1; }

AUTH_URL="${AUTH_EP}?client_id=$(urlencode "$CLIENT_ID")"
AUTH_URL+="&redirect_uri=$(urlencode "$REDIRECT")"
AUTH_URL+="&response_type=code&scope=$(urlencode "$SCOPE")"
AUTH_URL+="&access_type=offline&prompt=consent"

echo
echo "Open this URL in your browser and approve access:"
echo
echo "  $AUTH_URL"
echo

# best-effort auto-open
if   command -v open     >/dev/null 2>&1; then open     "$AUTH_URL" >/dev/null 2>&1 || true
elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$AUTH_URL" >/dev/null 2>&1 || true
fi

# --- capture the authorization code from the loopback redirect ---
CODE=""
if command -v python3 >/dev/null 2>&1; then
  echo "Waiting for the redirect on ${REDIRECT} ... (Ctrl-C to fall back to paste)"
  CODE=$(python3 - "$PORT" <<'PY' || true
import sys, http.server, urllib.parse
port = int(sys.argv[1])
result = {"code": None, "error": None}

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        if "code" in params:
            result["code"] = params["code"][0]
        if "error" in params:
            result["error"] = params["error"][0]
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(b"<h2>Authorized. You can close this tab and "
                         b"return to the terminal.</h2>")

    def log_message(self, *a):  # silence access logging
        pass

try:
    srv = http.server.HTTPServer(("127.0.0.1", port), H)
except OSError:
    sys.exit(1)  # port busy -> caller falls back to manual paste

while result["code"] is None and result["error"] is None:
    srv.handle_request()  # ignores favicon/other requests until code|error

print(result["code"] or "")
PY
)
fi

if [ -z "$CODE" ]; then
  echo
  echo "No code captured automatically. After approving, your browser lands"
  echo "on a ${REDIRECT}/?code=... page (it may say 'unable to connect' --"
  echo "that's expected). Copy the value of the 'code' query parameter from"
  echo "the address bar."
  echo
  printf 'Paste the code here: '; read -r CODE
fi
[ -n "$CODE" ] || { err "no authorization code captured"; exit 1; }

# --- exchange the code for a refresh token ---
# --data-urlencode so '/', '=', etc. in the code/secret are safe.
RESP=$(curl -fsS -X POST "$TOKEN_EP" \
  --data-urlencode "code=${CODE}" \
  --data-urlencode "client_id=${CLIENT_ID}" \
  --data-urlencode "client_secret=${CLIENT_SECRET}" \
  --data-urlencode "redirect_uri=${REDIRECT}" \
  --data-urlencode "grant_type=authorization_code") \
  || { err "token exchange request failed"; exit 1; }

REFRESH=$(jq -r '.refresh_token // empty' <<<"$RESP")
if [ -z "$REFRESH" ]; then
  err "no refresh_token in Google's response:"
  jq . <<<"$RESP" >&2 2>/dev/null || printf '%s\n' "$RESP" >&2
  err "if you've authorized this client before, Google may omit the refresh"
  err "token -- revoke prior access at myaccount.google.com/permissions and"
  err "retry (this script already sends prompt=consent)."
  exit 1
fi

echo
echo "Success. Add these to the agent's .env on the server:"
echo
echo "  GSC_OAUTH_CLIENT_ID=${CLIENT_ID}"
echo "  GSC_OAUTH_CLIENT_SECRET=${CLIENT_SECRET}"
echo "  GSC_OAUTH_REFRESH_TOKEN=${REFRESH}"
echo
