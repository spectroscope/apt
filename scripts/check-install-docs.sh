#!/bin/sh
# check-install-docs.sh — guard the documented apt lines (card 153).
#
# Card 153 measured two separate hangs behind one documented line:
#   1. `sudo apt install spectroscope` has no -y, so with a tty and nobody
#      answering it blocks forever on apt's own `Do you want to continue? [Y/n]`
#      before a single byte is downloaded, and with no tty it aborts with exit 1.
#   2. Supply -y and you reach a tzdata question a transitive dependency drags
#      in on Ubuntu, which leaves spectroscope `install ok unpacked` for good.
#
# The fix is documentation, not packaging: our own deb owns no debconf question
# (its control member holds only control/md5sums/postinst/postrm). So every
# surface that hands a reader the apt line must also hand them the unattended
# variant, must say what that variant decides for them, and must not advertise
# one command for two distributions when only Ubuntu is affected.
#
# This guard runs anywhere sh and grep exist — it needs no container, which is
# the point: the container leg in verify-client.sh cannot run on a developer
# machine without Docker, and a documentation defect should not need one.
#
#   sh apt-repo/scripts/check-install-docs.sh [extra-surface ...]
#
# Exit 0 = every surface carries the note. Exit 1 = at least one does not.
set -eu

here="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

# Default surfaces are the two this repository owns. Callers pass the others
# (the harness README, the website mirrors, the handbook) as arguments so this
# script never hard-codes a path outside its own repo.
if [ "$#" -gt 0 ]; then
  surfaces="$*"
else
  surfaces="$here/README.md $here/index.html"
fi

fail=0
note() { printf '%s\n' "$*"; }

for f in $surfaces; do
  if [ ! -f "$f" ]; then
    note "MISSING  $f"
    fail=1
    continue
  fi

  # Does this surface actually hand the reader an apt install line? If not, it
  # has nothing to answer for and we say so rather than passing it silently.
  if ! grep -Eq 'apt(-get)? install ([^|]*[[:space:]])?spectroscope' "$f"; then
    note "skip     $f (carries no apt install line)"
    continue
  fi

  bad=''

  grep -q 'DEBIAN_FRONTEND=noninteractive apt install -y spectroscope' "$f" \
    || bad="$bad
    no unattended variant (want: sudo DEBIAN_FRONTEND=noninteractive apt install -y spectroscope)"

  # The variant picks a timezone silently on a machine where tzdata has never
  # been configured. A reader who is not told that cannot consent to it.
  grep -q 'Etc/UTC' "$f" \
    || bad="$bad
    unattended variant does not say what it decides (want: Etc/UTC named)"

  # Only Ubuntu is affected: debian:12 ships tzdata configured and its systemd
  # does not recommend networkd-dispatcher. A surface naming both distributions
  # has to say which half the warning is about.
  if grep -q 'Debian 12' "$f" && grep -q 'Ubuntu 24.04' "$f"; then
    grep -Eq 'Ubuntu half|only the Ubuntu|Debian 12 ships' "$f" \
      || bad="$bad
    names both distributions but does not say only Ubuntu is affected"
  fi

  if [ -n "$bad" ]; then
    note "FAIL     $f$bad"
    fail=1
  else
    note "ok       $f"
  fi
done

# --------------------------------------------------------------------------
# The live leg must not close the stdin it just insisted on.
#
# verify-client.sh refuses to run its live leg without a tty on stdin, because
# the failure under test only happens when apt has a terminal it can ask. An
# `apt install` inside that block with its stdin redirected from /dev/null
# reads EOF and aborts in seconds with exit 1 — a DIFFERENT outcome from the
# indefinite wait the card describes. Such a leg passes whatever the truth is,
# so this guard exists to keep the premise and the measurement in one piece.
# --------------------------------------------------------------------------
leg="$here/scripts/verify-client.sh"
if [ -f "$leg" ]; then
  offenders="$(
    awk '/LIVE_LEG:-0/{inleg=1} /^fi$/{if(inleg) inleg=0} inleg' "$leg" \
      | grep -nE 'apt(-get)? +install' \
      | grep -E '0?< *\/dev\/null' || true
  )"
  if [ -n "$offenders" ]; then
    note "FAIL     $leg"
    note "    an apt install in the live leg reads stdin from /dev/null:"
    printf '    %s\n' "$offenders"
    note '    that measures apt aborting on EOF, not the hang the card describes'
    fail=1
  else
    note "ok       $leg (live leg keeps apt on the tty it demands)"
  fi
else
  note "MISSING  $leg"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  note ''
  note 'INSTALL DOCS NOT GUARDED (see card 153)'
  exit 1
fi
note ''
note 'INSTALL DOCS OK'
