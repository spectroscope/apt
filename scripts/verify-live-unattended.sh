#!/bin/sh
# verify-live-unattended.sh — drive the card-153 live leg from the host.
#
# The leg itself lives in verify-client.sh under LIVE_LEG=1. It needs three
# things this script provides and the container cannot give itself:
#
#   -t                    a tty on stdin. Without one the documented line
#                         ABORTS in seconds with exit 1 instead of hanging, so
#                         a no-tty run would measure the wrong failure.
#   --platform amd64      the repository is x86_64 only; on an arm64 host apt
#                         would add the source and then find nothing.
#   the live URL          the local http.server path in verify-client.sh cannot
#                         see a problem with the real repository.
#
#   sh apt-repo/scripts/verify-live-unattended.sh
#   IMAGE=ubuntu:24.04 BASE_URL=https://apt.spectroscope.dev sh ...
#
# It downloads ~320 MB of packages from the live repository and its mirrors, so
# it is a deliberate, occasional run, not something a pre-commit hook does.
#
# PROVENANCE, so nobody mistakes this for a measured result: as of 2026-08-11
# this leg has NEVER BEEN EXECUTED, and the reason was measured that day rather
# than assumed. `docker` is on PATH at /usr/local/bin/docker (client 29.4.0,
# darwin/arm64), and Docker Desktop 4.69.0 is installed, but the daemon socket
# at ~/.docker/run/docker.sock does not exist and `docker info` exits 1. The
# backend dies before it opens one:
#
#   backend crashed: initializing cli binaries configuration: repairing vmnetd
#   configuration: configuring privileged port mapping: applescript error:
#
# and a live osascript process sits there holding the wall:
#
#   with prompt "Docker Desktop requires privileged access to configure
#   privileged port mapping" with administrator privileges
#
# That is a macOS admin-password dialog. It needs the owner at the keyboard;
# no agent may type into it. A hard restart of Docker Desktop on 2026-08-11
# reproduced the same crash and the same dialog, so it is the standing state of
# this machine and not a one-off. podman, nerdctl, colima, lima, limactl,
# multipass, vagrant, qemu and orb are all absent, so there is no second route
# to a Linux userspace here.
#
# What HAS been checked: `sh -n` on this file and on verify-client.sh, and the
# two guards below firing (exit 2, "daemon is not reachable"). The numbers the
# leg asserts come from the card-153 measurement of 2026-08-03, not from a run
# of this script. Delete this paragraph the first time it goes green on a host
# with a working daemon and put the date and the numbers here instead.
set -eu

IMAGE="${IMAGE:-ubuntu:24.04}"
PLATFORM="${PLATFORM:-linux/amd64}"
BASE_URL="${BASE_URL:-https://apt.spectroscope.dev}"
repo="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found — this leg needs a container; there is no host-side substitute"
  exit 2
fi
if ! docker info >/dev/null 2>&1; then
  echo "docker is installed but the daemon is not reachable — start it and re-run"
  exit 2
fi

echo "image=$IMAGE platform=$PLATFORM base=$BASE_URL"
echo "repo=$repo"

# -t alone, not -it: stdin stays attached to whatever this script has, and the
# pseudo-tty is what makes apt block on its question rather than abort.
exec docker run --rm -t \
  --platform "$PLATFORM" \
  -e LIVE_LEG=1 \
  -e BASE_URL="$BASE_URL" \
  -v "$repo:/srv/apt:ro" \
  "$IMAGE" \
  sh /srv/apt/scripts/verify-client.sh
