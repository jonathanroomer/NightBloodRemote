#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

failed=0

check_pattern() {
  label=$1
  pattern=$2
  if rg -n -i --hidden \
    --glob '!.git/**' \
    --glob '!scripts/audit-public-source.sh' \
    --glob '!app/ui/package-lock.json' \
    "$pattern" .; then
    printf '%s\n' "FAIL: $label"
    failed=1
  else
    printf '%s\n' "PASS: $label"
  fi
}

check_pattern "absolute home-directory paths" '/(Users|home)/[^[:space:]]+'
check_pattern "email addresses" '[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}'
check_pattern "private keys" 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'
check_pattern "hard-coded Apple team IDs" 'DEVELOPMENT_TEAM[[:space:]]*[:=][[:space:]]*[A-Z0-9]{10}'
# Permit only the exact public upstream Codex client ID in its intended build
# setting. Other identifiers, locations and extra text still fail this check.
oauth_scan_status=0
oauth_id_matches=$(rg -n -i --no-heading --hidden \
  --glob '!.git/**' --glob '!scripts/audit-public-source.sh' \
  --glob '!app/ui/package-lock.json' 'app_[A-Za-z0-9]{20,}' .) || oauth_scan_status=$?
if [ "$oauth_scan_status" -gt 1 ]; then
  printf '%s\n' "FAIL: OAuth application ID scan could not complete"
  exit 1
fi
unexpected_oauth_ids=$(printf '%s\n' "$oauth_id_matches" \
  | rg -v '^\./ios/NightBloodRemote/project\.yml:[0-9]+:        CODEX_OAUTH_CLIENT_ID: "app_EMoamEEZ73f0CkXaXp7hrann"$' \
  | rg -v '^$' || true)
if [ -n "$unexpected_oauth_ids" ]; then
  printf '%s\n' "$unexpected_oauth_ids"
  printf '%s\n' "FAIL: unreviewed OAuth application IDs"
  failed=1
else
  printf '%s\n' "PASS: OAuth application IDs (one reviewed upstream build setting allowed)"
fi
check_pattern "real account-linked UUIDs" '01[0-9a-f]{6}-[0-9a-f-]{27,}'
check_pattern "common committed secrets" "(api[_-]?key|client[_-]?secret|access[_-]?token|refresh[_-]?token)[[:space:]]*[:=][[:space:]]*[\"'][A-Za-z0-9_./+=-]{20,}[\"']"
check_pattern "private IPv4 addresses" '(^|[^0-9])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})([^0-9]|$)'

if [ -d .git ] \
  && [ "$(git rev-parse --show-toplevel 2>/dev/null)" = "$ROOT" ]; then
  forbidden_files=$(git ls-files | rg '(\.p12|\.mobileprovision|\.xcarchive|\.ipa|\.blend|\.wav|\.mp3|\.mov|\.mp4)$|(^|/)xcuserdata/|(^|/)project\.pbxproj$' || true)
else
  forbidden_files=$(find . -type f \( \
    -name '*.p12' -o -name '*.mobileprovision' -o -name '*.xcarchive' -o \
    -name '*.ipa' -o -name '*.blend' -o -name '*.wav' -o -name '*.mp3' -o \
    -name '*.mov' -o -name '*.mp4' -o -path '*/xcuserdata/*' -o \
    -name 'project.pbxproj' \
  \) -print)
fi

if [ -n "$forbidden_files" ]; then
  printf '%s\n' "$forbidden_files"
  printf '%s\n' "FAIL: forbidden binary, signing or user-specific artefacts"
  failed=1
else
  printf '%s\n' "PASS: forbidden binary, signing and user-specific artefacts"
fi

if [ -d .git ] \
  && [ "$(git rev-parse --show-toplevel 2>/dev/null)" = "$ROOT" ] \
  && git rev-parse --verify HEAD >/dev/null 2>&1; then
  if git log --format='%an <%ae>%n%cn <%ce>' \
    | rg -v '^(NightBlood Remote contributors <noreply@users[.]noreply[.]github[.]com>|GitHub <noreply@github[.]com>)$' \
    | rg -v '^[^<>]+ <[0-9]+[+][^@<>]+@users[.]noreply[.]github[.]com>$' \
    | rg -i '/(Users|home)/|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}'; then
    printf '%s\n' "FAIL: Git author/committer metadata contains a non-public email identity"
    failed=1
  else
    printf '%s\n' "PASS: Git author/committer metadata (generic or existing public GitHub attribution)"
  fi
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi

printf '%s\n' "Public-source audit passed. Independent review is still required."
