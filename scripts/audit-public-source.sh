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
check_pattern "hard-coded OAuth application IDs" 'app_[A-Za-z0-9]{20,}'
check_pattern "real account-linked UUIDs" '(01[0-9a-f]{6}|a1363e6c)-[0-9a-f-]{27,}'
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
  if git log --format='%an <%ae>' \
    | rg -v '^NightBlood Remote contributors <noreply@users.noreply.github.com>$' \
    | rg -i '/(Users|home)/|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}'; then
    printf '%s\n' "FAIL: Git author metadata contains non-generic identity data"
    failed=1
  else
    printf '%s\n' "PASS: Git author metadata"
  fi
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi

printf '%s\n' "Public-source audit passed. Independent review is still required."
