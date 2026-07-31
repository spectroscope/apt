#!/bin/sh
# update-repo.sh — release playbook step 8c: publish a new deb into the apt tree.
#
#   scripts/update-repo.sh /path/to/spectroscope_<version>_<arch>.deb
#
# Runs on the host (macOS or Linux; needs docker). Inside a debian:12
# container it first checks the signing key, THEN copies the deb into pool/,
# regenerates Packages/Packages.gz/Release and re-signs InRelease +
# Release.gpg with the dedicated apt key.
#
# It REFUSES to leave an unsigned or badly signed tree behind:
#   - aborts when the key home is missing or holds no secret key for $KEYID;
#     the key check runs BEFORE the deb touches pool/, so a refused run
#     leaves the tree exactly as it was
#   - after signing, verifies InRelease AND Release.gpg with gpgv against the
#     exported public key (spectroscope.asc); any failure aborts non-zero.
#
# The key home is a LOCAL credential (default ~/.spectroscope-apt-key,
# override with SPECTRO_APT_KEYHOME). It is never part of this git repo.
# Recipe to mint it: scripts/apt-signing-key.batch.
#
# After a successful run: git add -A && git commit && git push (push = publish
# once GitHub Pages serves this repo).
set -eu

DEB="${1:?usage: update-repo.sh /path/to/spectroscope_<version>_<arch>.deb}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYHOME="${SPECTRO_APT_KEYHOME:-$HOME/.spectroscope-apt-key}"
KEYID="${KEYID:-chris@spectroscope.ai}"
IMAGE="${IMAGE:-debian:12}"

case "$DEB" in
  *.deb) ;;
  *) echo "refusing: not a .deb: $DEB" >&2; exit 1 ;;
esac
[ -f "$DEB" ] || { echo "refusing: no such file: $DEB" >&2; exit 1; }
[ -d "$KEYHOME" ] && [ -d "$KEYHOME/private-keys-v1.d" ] || {
  echo "refusing: apt signing key home missing at $KEYHOME" >&2
  echo "mint it with scripts/apt-signing-key.batch (see the file header)" >&2
  exit 1
}
command -v docker >/dev/null || { echo "refusing: docker not available" >&2; exit 1; }

DEBNAME="$(basename "$DEB")"

docker run --rm \
  -v "$ROOT":/repo \
  -v "$DEB":"/incoming/$DEBNAME":ro \
  -v "$KEYHOME":/gnupg \
  -e GNUPGHOME=/gnupg \
  -e KEYID="$KEYID" \
  -e DEBNAME="$DEBNAME" \
  "$IMAGE" sh -ec '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null
    apt-get install -y -qq dpkg-dev apt-utils gnupg >/dev/null 2>&1
    chmod 700 /gnupg
    gpg --batch --list-secret-keys "$KEYID" >/dev/null 2>&1 \
      || { echo "refusing: no secret key for $KEYID in the key home" >&2; exit 1; }
    # key check passed — only now may the deb enter the pool
    mkdir -p /repo/pool/main/s/spectroscope
    cp "/incoming/$DEBNAME" /repo/pool/main/s/spectroscope/
    echo "pooled: pool/main/s/spectroscope/$DEBNAME"
    sh /repo/scripts/make-apt-repo.sh /repo
    echo "=== signature self-check (gpgv against the served public key) ==="
    gpg --batch --dearmor < /repo/spectroscope.asc > /tmp/pub.gpg
    gpgv --keyring /tmp/pub.gpg /repo/dists/stable/InRelease
    gpgv --keyring /tmp/pub.gpg /repo/dists/stable/Release.gpg /repo/dists/stable/Release
  '

echo "apt tree updated and signature-verified. Review, commit, push to publish."
