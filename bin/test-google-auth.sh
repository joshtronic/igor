#!/usr/bin/env bash
# test-google-auth.sh -- unit tests for lib/google-auth.sh (service-account
# token minting). Generates a throwaway RSA keypair, builds a fake SA key, and
# checks google_sa_json (base64 / file / inline) plus that google_sa_access_token
# assembles a correct, correctly-SIGNED JWT. The token exchange (curl) is
# stubbed -- no network. Skip-safe: needs jq + openssl + base64.
set -uo pipefail

for t in jq openssl base64; do
  command -v "$t" >/dev/null 2>&1 || { echo "test-google-auth: $t unavailable -- skipping"; exit 0; }
done

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/google-auth.sh
. "$HERE/../lib/google-auth.sh"

FAIL=0
eq() { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }
no() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  x %s (rc!=0 expected)\n' "$d"; FAIL=$((FAIL + 1)); else printf '  + %s\n' "$d"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/key.pem" 2>/dev/null
openssl rsa -in "$TMP/key.pem" -pubout -out "$TMP/pub.pem" 2>/dev/null
PK=$(cat "$TMP/key.pem")
SA=$(jq -n --arg ce "svc@proj.iam.gserviceaccount.com" --arg pk "$PK" \
  '{type:"service_account", client_email:$ce, private_key:$pk, token_uri:"https://oauth2.googleapis.com/token"}')

# base64url -> raw bytes (restore padding + url-safe -> standard alphabet)
b64urld() { local s="$1"; s="${s//-/+}"; s="${s//_//}"; case $((${#s} % 4)) in 2) s="$s==";; 3) s="$s=";; esac; printf '%s' "$s" | base64 -d 2>/dev/null; }

echo "== google_sa_json: inline / base64 / file / unset / garbage =="
GOOGLE_SERVICE_ACCOUNT="$SA"
eq "inline JSON" "svc@proj.iam.gserviceaccount.com" "$(google_sa_json | jq -r .client_email)"
GOOGLE_SERVICE_ACCOUNT=$(printf '%s' "$SA" | base64 -w0)
eq "base64"      "svc@proj.iam.gserviceaccount.com" "$(google_sa_json | jq -r .client_email)"
printf '%s' "$SA" > "$TMP/sa.json"; GOOGLE_SERVICE_ACCOUNT="$TMP/sa.json"
eq "file path"   "svc@proj.iam.gserviceaccount.com" "$(google_sa_json | jq -r .client_email)"
GOOGLE_SERVICE_ACCOUNT="";        no "unset -> rc1"   google_sa_json
GOOGLE_SERVICE_ACCOUNT="notjson"; no "garbage -> rc1" google_sa_json

echo "== google_sa_access_token: assembles + signs a valid JWT, returns the token =="
# shellcheck disable=SC2034  # read by google_sa_json, called from
# google_sa_access_token below (lib/google-auth.sh).
GOOGLE_SERVICE_ACCOUNT="$SA"
# stub curl: capture the assertion (the JWT), return a fake token response
curl() { local i; for ((i=1; i<=$#; i++)); do case "${!i}" in assertion=*) printf '%s' "${!i#assertion=}" > "$TMP/jwt";; esac; done; printf '{"access_token":"fake-tok-abc"}'; }
tok=$(google_sa_access_token "https://www.googleapis.com/auth/webmasters.readonly")
eq "returns the access token" "fake-tok-abc" "$tok"
JWT=$(cat "$TMP/jwt" 2>/dev/null)
eq "jwt has 3 parts"     "3"     "$(awk -F. '{print NF}' <<<"$JWT")"
hdr=$(b64urld "$(cut -d. -f1 <<<"$JWT")"); cl=$(b64urld "$(cut -d. -f2 <<<"$JWT")")
eq "header alg RS256"    "RS256" "$(jq -r .alg <<<"$hdr")"
eq "claim iss = email"   "svc@proj.iam.gserviceaccount.com" "$(jq -r .iss <<<"$cl")"
eq "claim scope"         "https://www.googleapis.com/auth/webmasters.readonly" "$(jq -r .scope <<<"$cl")"
eq "claim aud=token_uri" "https://oauth2.googleapis.com/token" "$(jq -r .aud <<<"$cl")"
eq "exp > iat"           "true"  "$(jq -r '(.exp > .iat)' <<<"$cl")"
# the signature must verify against the SA public key (proves real RS256 signing)
b64urld "$(cut -d. -f3 <<<"$JWT")" > "$TMP/sig.bin"
if printf '%s' "$(cut -d. -f1,2 <<<"$JWT")" | openssl dgst -sha256 -verify "$TMP/pub.pem" -signature "$TMP/sig.bin" >/dev/null 2>&1; then
  printf '  + signature verifies against the SA public key\n'
else
  printf '  x signature does NOT verify\n'; FAIL=$((FAIL + 1))
fi
unset -f curl

if [ "$FAIL" -eq 0 ]; then echo "test-google-auth: all passed"; else echo "test-google-auth: $FAIL FAILED"; exit 1; fi
