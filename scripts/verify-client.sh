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
#
# LIVE_LEG=1 switches this script into a SECOND, separate mode (card 153):
#
#   docker run --rm -t --platform linux/amd64 -e LIVE_LEG=1 \
#     -v /path/to/apt-repo:/srv/apt:ro ubuntu:24.04 \
#     sh /srv/apt/scripts/verify-client.sh
#
# The two modes cannot share a process, and that is the whole point. The mock
# mode above hides the card-153 tzdata question four times over: it exports
# DEBIAN_FRONTEND, it installs python3 (which configures tzdata) before our
# repository is added, it supplies -y, and it points apt at a local http.server
# instead of the live host. The live leg drops the first two and the last: it
# bootstraps without python3, leaves DEBIAN_FRONTEND unset for itself, and talks
# to the real repository, so the container it runs in has genuinely never seen
# tzdata when our source is added.
#
# What the live leg does NOT do is reproduce the hang. It measures one thing:
# that the unattended variant the documentation hands a reader lands cleanly on
# a machine in that state. The leg that claimed to reproduce the hang was
# removed on 2026-08-11 — see the note further down and card 153.
# Drive it with scripts/verify-live-unattended.sh, which allocates the tty.
set -eu
PKG="${PKG:-spectroscope}"

# --------------------------------------------------------------------------
# LIVE LEG (card 153): the documented lines, under a tty, against the live
# repository, in a container that has never seen python3 or tzdata.
# --------------------------------------------------------------------------
if [ "${LIVE_LEG:-0}" = "1" ]; then
  BASE="${BASE_URL:-https://apt.spectroscope.dev}"
  # Bounded, because the thing this leg walks past is an unbounded wait. A leg
  # that can hang cannot report on hanging.
  CURE_BUDGET="${CURE_BUDGET:-900}"

  echo "=== live leg: $(head -1 /etc/os-release) arch=$(dpkg --print-architecture) ==="
  echo "base=$BASE  cure_budget=${CURE_BUDGET}s"

  # A tty keeps this run in the same shape the card measured on 2026-08-03:
  # debconf tries its Dialog frontend first and falls back to Readline, which is
  # the path the timezone question travels. Without one the run is a different
  # experiment, so the leg refuses rather than quietly measuring something else.
  if [ ! -t 0 ]; then
    echo "NO TTY ON STDIN — run docker with -t; this leg proves nothing without one"
    exit 1
  fi
  echo "tty on stdin: yes ($(tty 2>/dev/null || echo unknown))"

  # DEBIAN_FRONTEND must not be set for us: the documented line has to meet the
  # question the way a reader would.
  if [ -n "${DEBIAN_FRONTEND:-}" ]; then
    echo "DEBIAN_FRONTEND IS SET ($DEBIAN_FRONTEND) — that is one of the masks; unset it"
    exit 1
  fi

  # The honest bootstrap. curl, gpg and sudo are all absent from ubuntu:24.04,
  # so a reader has to install something before line 1 can run. These three pull
  # neither tzdata nor python3 (measured 2026-08-03), so they do not hide the
  # defect the way installing python3 would.
  apt-get update -qq >/dev/null
  apt-get install -y -qq curl gnupg ca-certificates >/dev/null 2>&1
  for forbidden in python3 tzdata; do
    if dpkg -s "$forbidden" >/dev/null 2>&1; then
      echo "BOOTSTRAP PULLED $forbidden — that mask is back, the leg is worthless"
      exit 1
    fi
  done
  echo "bootstrap clean: no python3, no tzdata"

  echo "=== the documented lines, verbatim except for sudo (we are root) ==="
  curl -fsSL "$BASE/spectroscope.asc" | gpg --dearmor -o /usr/share/keyrings/spectroscope.gpg
  echo "deb [signed-by=/usr/share/keyrings/spectroscope.gpg] $BASE stable main" \
    > /etc/apt/sources.list.d/spectroscope.list
  apt-get update 2>&1 | grep -Ei 'InRelease' || true

  # There used to be a first leg here that claimed to reproduce the hang: it ran
  # the bare `apt install spectroscope` under `timeout` and passed when the log
  # did not reach "Setting up". It was removed on 2026-08-11, unrun, because it
  # could not fail. Its apt call took stdin from /dev/null, so apt read EOF and
  # aborted with exit 1 in seconds instead of waiting — and "did not reach
  # Setting up" is true of an abort too, so the leg reported success no matter
  # which of the two outcomes happened. Both the guard it needed and the hang
  # itself are unmeasured; see the 2026-08-11 note on card 153 for what is
  # missing and where it can be gathered. Do not restore it without a container
  # that actually starts.

  # The documented cure. This is the line the docs hand a reader who has nobody
  # at the keyboard, and it has to land.
  echo "=== the unattended variant must reach 'Setting up $PKG' ==="
  set +e
  timeout "$CURE_BUDGET" env DEBIAN_FRONTEND=noninteractive apt install -y "$PKG" \
    >/tmp/cure.log 2>&1
  cure_rc=$?
  set -e
  echo "exit=$cure_rc"
  grep -E "Setting up (tzdata|$PKG)" /tmp/cure.log || true
  if [ "$cure_rc" -eq 124 ]; then
    echo "TIMED OUT AFTER ${CURE_BUDGET}s — the unattended variant hangs (BAD)"
    exit 1
  fi
  [ "$cure_rc" -eq 0 ] || { echo "UNATTENDED INSTALL FAILED exit=$cure_rc (BAD)"; exit 1; }
  grep -q "Setting up $PKG" /tmp/cure.log \
    || { echo "NEVER REACHED 'Setting up $PKG' (BAD)"; exit 1; }

  # The three states the card measured on the stuck machine, asserted the right
  # way round: nothing half-configured, and the binary actually there.
  dpkg -s "$PKG" | grep -E '^(Status|Version):'
  dpkg -s tzdata | grep -E '^Status:'
  ls -l /usr/bin/"$PKG"
  echo "timezone chosen for you: $(cat /etc/timezone 2>/dev/null || echo none)"
  nonii="$(dpkg -l | grep -c '^[^i]' || true)"
  echo "non-ii package lines: $nonii"
  if grep -qi 'geographic area' /tmp/cure.log; then
    echo "A DEBCONF QUESTION STILL APPEARED (BAD)"; exit 1
  fi
  echo "LIVE LEG OK"
  exit 0
fi

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
