#!/bin/sh

if command -v node >/dev/null 2>&1; then
  exec "$(command -v node)" "$@"
fi

for candidate in /opt/homebrew/bin/node /usr/local/bin/node; do
  if [ -x "$candidate" ]; then
    exec "$candidate" "$@"
  fi
done

echo "NightBlood iOS build requires Node.js, but Xcode could not find it." >&2
exit 127
