#!/bin/sh
# update-repo.sh — release playbook step 8c: publish a new deb into the apt tree.
#
#   scripts/update-repo.sh --url <public download URL> /path/to/spectroscope_<version>_<arch>.deb
#
# Runs on the host (macOS or Linux; needs docker). Inside a debian:12
# container it first checks the signing key, THEN copies the deb into pool/,
# records it in pool-map.json, regenerates Packages/Packages.gz/Release and
# re-signs InRelease + Release.gpg with the dedicated apt key.
#
# --url is MANDATORY. The pool is not served from this repository — GitHub
# refuses any file over 100 MB and a Cloudflare static asset may be 25 MiB, so
# the deb lives at a release asset and apt.spectroscope.dev redirects to it
# (src/worker.js). The worker redirects only to what pool-map.json names, and
# this script is what writes that entry. Pooling a deb without a URL would
# publish a signed index promising a file nobody serves, which is exactly the
# failure the whole redirect layer exists to prevent.
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
# After a successful run: git add -A && git commit && git push (push = publish;
# the indexes go out over GitHub Pages, the worker over Workers Builds).
set -eu

USAGE="usage: update-repo.sh --url <public download URL> /path/to/spectroscope_<version>_<arch>.deb"

DEB=""
POOL_URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --url)
      [ $# -ge 2 ] || { echo "refusing: --url needs a value" >&2; exit 1; }
      POOL_URL="$2"; shift 2 ;;
    --url=*) POOL_URL="${1#--url=}"; shift ;;
    -h|--help) echo "$USAGE"; exit 0 ;;
    -*) echo "refusing: unknown option: $1" >&2; echo "$USAGE" >&2; exit 1 ;;
    *)
      [ -z "$DEB" ] || { echo "refusing: more than one deb given: $DEB and $1" >&2; exit 1; }
      DEB="$1"; shift ;;
  esac
done
[ -n "$DEB" ] || { echo "$USAGE" >&2; exit 1; }

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

DEBNAME="$(basename "$DEB")"

# The pool map check sits after the key check so the refusals above keep their
# documented wording, and before docker so nothing is built for a run that
# cannot publish.
[ -n "$POOL_URL" ] || {
  echo "refusing: no --url for $DEBNAME" >&2
  echo "the pool map needs the URL that will actually serve this file, e.g." >&2
  echo "  --url https://github.com/spectroscope/spectroscope/releases/download/v0.4.2/$DEBNAME" >&2
  echo "without it the signed index would promise a package nobody serves" >&2
  exit 1
}
case "$POOL_URL" in
  https://*) ;;
  *) echo "refusing: --url must be an https:// URL, got: $POOL_URL" >&2; exit 1 ;;
esac
case "$POOL_URL" in
  *"/$DEBNAME") ;;
  *) echo "note: --url does not end in /$DEBNAME. The map is filename -> URL," >&2
     echo "      so a renamed asset is allowed; check that it is deliberate." >&2 ;;
esac

command -v docker >/dev/null || { echo "refusing: docker not available" >&2; exit 1; }

docker run --rm \
  -v "$ROOT":/repo \
  -v "$DEB":"/incoming/$DEBNAME":ro \
  -v "$KEYHOME":/gnupg \
  -e GNUPGHOME=/gnupg \
  -e KEYID="$KEYID" \
  -e DEBNAME="$DEBNAME" \
  -e POOL_URL="$POOL_URL" \
  "$IMAGE" sh -ec '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null
    apt-get install -y -qq dpkg-dev apt-utils gnupg jq >/dev/null 2>&1
    chmod 700 /gnupg
    gpg --batch --list-secret-keys "$KEYID" >/dev/null 2>&1 \
      || { echo "refusing: no secret key for $KEYID in the key home" >&2; exit 1; }
    # key check passed — only now may the deb enter the pool
    mkdir -p /repo/pool/main/s/spectroscope
    cp "/incoming/$DEBNAME" /repo/pool/main/s/spectroscope/
    echo "pooled: pool/main/s/spectroscope/$DEBNAME"
    # The map moves with the pool, in the same breath, so the tree never
    # carries a package the worker cannot point at. jq keeps the note and the
    # order of the existing entries; an entry for this filename is replaced.
    [ -f /repo/pool-map.json ] || echo "{\"packages\":{}}" > /repo/pool-map.json
    jq --arg f "$DEBNAME" --arg u "$POOL_URL" ".packages[\$f] = \$u" \
      /repo/pool-map.json > /tmp/pool-map.json
    mv /tmp/pool-map.json /repo/pool-map.json
    echo "mapped: $DEBNAME -> $POOL_URL"
    sh /repo/scripts/make-apt-repo.sh /repo
    echo "=== signature self-check (gpgv against the served public key) ==="
    gpg --batch --dearmor < /repo/spectroscope.asc > /tmp/pub.gpg
    gpgv --keyring /tmp/pub.gpg /repo/dists/stable/InRelease
    gpgv --keyring /tmp/pub.gpg /repo/dists/stable/Release.gpg /repo/dists/stable/Release
  '

echo "apt tree updated and signature-verified. Review, commit, push to publish."
