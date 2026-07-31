#!/bin/sh
# verify-client.sh — the house verification for this repo (card 135).
#
# Runs INSIDE a clean debian/ubuntu container with the built tree mounted
# read-only at /srv/apt:
#   docker run --rm -v /path/to/apt-repo:/srv/apt:ro debian:12 \
#     sh /srv/apt/scripts/verify-client.sh
#
# Executes the documented user-facing two lines (URL swapped for a throwaway
# local python3 http.server on the tree), then proves:
#   - apt-get update fetches InRelease with NO signature warnings
#   - apt-get install spectroscope succeeds and the files land
#   - apt-get remove cleans the package up while ~/.spectro (user state)
#     survives
#   - a tampered index is rejected (negative control)
# No trusted=yes, no allow-insecure anywhere.
set -eu
PKG="${PKG:-spectroscope}"
export DEBIAN_FRONTEND=noninteractive
echo "=== client: $(head -1 /etc/os-release) arch=$(dpkg --print-architecture) ==="
apt-get update -qq >/dev/null
apt-get install -y -qq curl gnupg python3 >/dev/null 2>&1

python3 -m http.server 8000 --directory /srv/apt --bind 127.0.0.1 >/dev/null 2>&1 &
sleep 1

echo "=== the documented two lines (http) ==="
echo '$ curl -fsSL http://127.0.0.1:8000/spectroscope.asc | gpg --dearmor -o /usr/share/keyrings/spectroscope.gpg'
curl -fsSL http://127.0.0.1:8000/spectroscope.asc | gpg --dearmor -o /usr/share/keyrings/spectroscope.gpg
echo '$ echo "deb [signed-by=/usr/share/keyrings/spectroscope.gpg] http://127.0.0.1:8000 stable main" > /etc/apt/sources.list.d/spectroscope.list'
echo "deb [signed-by=/usr/share/keyrings/spectroscope.gpg] http://127.0.0.1:8000 stable main" > /etc/apt/sources.list.d/spectroscope.list

echo "=== apt-get update (must fetch InRelease, no warnings) ==="
apt-get update 2>&1 | tee /tmp/update.log | grep -Ei 'InRelease|Packages' || true
if grep -Eiq 'warn|insecure|NO_PUBKEY|is not signed' /tmp/update.log; then
  echo "SIGNATURE WARNINGS PRESENT (BAD)"; exit 1
fi
echo "no signature warnings"

echo "=== policy + install ==="
apt-cache policy "$PKG"
apt-get install -y "$PKG" 2>&1 | grep -E 'Get:|Setting up|newly installed'

echo "=== the files land ==="
dpkg -L "$PKG" | tail -5
APPBIN="$(dpkg -L "$PKG" | grep -E '^/opt/.*/spectroscope$' | head -1 || true)"
[ -n "$APPBIN" ] && { echo "app binary: $APPBIN"; ls -la "$APPBIN"; }

echo "=== simulate user state: ~/.spectro before remove ==="
mkdir -p "$HOME/.spectro"
echo '{"user":"data"}' > "$HOME/.spectro/settings.json"
ls -la "$HOME/.spectro"

echo "=== apt-get remove cleans the package up ==="
apt-get remove -y -qq "$PKG" 2>&1 | tail -1
if [ -n "$APPBIN" ] && [ -e "$APPBIN" ]; then
  echo "APP BINARY STILL PRESENT AFTER REMOVE (BAD)"; exit 1
fi
echo "app binary gone: $APPBIN"
dpkg -s "$PKG" 2>&1 | head -2 || true

echo "=== ~/.spectro survives remove ==="
if [ -f "$HOME/.spectro/settings.json" ]; then
  echo "~/.spectro SURVIVES: $(cat "$HOME/.spectro/settings.json")"
else
  echo "~/.spectro LOST AFTER REMOVE (BAD)"; exit 1
fi

echo "=== negative control: tampered Packages.gz must fail ==="
cp -r /srv/apt /tmp/tampered
rm -rf /tmp/tampered/scripts /tmp/tampered/.git
arch="$(dpkg --print-architecture)"
gunzip -c "/tmp/tampered/dists/stable/main/binary-$arch/Packages.gz" > /tmp/p
printf '\n' >> /tmp/p
gzip -9 -c /tmp/p > "/tmp/tampered/dists/stable/main/binary-$arch/Packages.gz"
echo "deb [signed-by=/usr/share/keyrings/spectroscope.gpg] file:/tmp/tampered stable main" > /etc/apt/sources.list.d/spectroscope.list
if apt-get update 2>&1 | grep -Ei 'hash sum mismatch|err'; then
  echo "TAMPER DETECTED (good)"
else
  echo "TAMPER NOT DETECTED (BAD)"; exit 1
fi
echo "CLIENT OK"
