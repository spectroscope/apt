#!/bin/sh
# make-apt-repo.sh — regenerate the static apt tree from the debs in pool/.
#
# Runs INSIDE a debian container (the host is macOS and has no dpkg).
# Normally invoked via scripts/update-repo.sh, which mounts this repo at
# /repo and the dedicated key home at /gnupg:
#   docker run --rm \
#     -v /path/to/apt-repo:/repo \
#     -v ~/.spectroscope-apt-key:/gnupg \
#     -e GNUPGHOME=/gnupg \
#     debian:12 sh -c 'apt-get update -qq && \
#       apt-get install -y -qq dpkg-dev apt-utils gnupg && \
#       sh /repo/scripts/make-apt-repo.sh /repo'
#
# Preconditions:
#   - the .deb files already sit in $REPO/pool/main/s/spectroscope/
#   - $GNUPGHOME holds the dedicated apt signing key
#     (uid "spectroscope apt <chris@spectroscope.ai>",
#      recipe: apt-signing-key.batch — NOT the Maven key)
# Mechanics verified in debian:12 + ubuntu:24.04 containers on 2026-07-31
# (dpkg-scanpackages 1.21.23, apt-ftparchive/apt 2.6.1, gpg 2.2.40).
set -eu
REPO="${1:?usage: make-apt-repo.sh /path/to/repo-root}"
KEYID="${KEYID:-chris@spectroscope.ai}"
SUITE="${SUITE:-stable}"
ARCHES="${ARCHES:-amd64 arm64}"

cd "$REPO"
ls pool/main/s/spectroscope/*.deb >/dev/null  # refuse to build an empty repo

for arch in $ARCHES; do
  mkdir -p "dists/$SUITE/main/binary-$arch"
  # --arch includes Architecture: <arch> AND Architecture: all debs (verified:
  # an arch-all deb appeared under both --arch amd64 and --arch arm64).
  dpkg-scanpackages --multiversion --arch "$arch" pool \
    > "dists/$SUITE/main/binary-$arch/Packages"
  gzip -9 -f -k "dists/$SUITE/main/binary-$arch/Packages"
done

apt-ftparchive \
  -o APT::FTPArchive::Release::Origin=spectroscope \
  -o APT::FTPArchive::Release::Label=spectroscope \
  -o "APT::FTPArchive::Release::Suite=$SUITE" \
  -o "APT::FTPArchive::Release::Codename=$SUITE" \
  -o "APT::FTPArchive::Release::Architectures=$ARCHES" \
  -o APT::FTPArchive::Release::Components=main \
  release "dists/$SUITE" > "dists/$SUITE/Release.new"
mv "dists/$SUITE/Release.new" "dists/$SUITE/Release"

# InRelease (clearsigned, what modern apt fetches) + Release.gpg (detached,
# kept for old clients that fetch Release + Release.gpg separately).
gpg --batch --yes -u "$KEYID" --clearsign --digest-algo SHA256 \
  -o "dists/$SUITE/InRelease" "dists/$SUITE/Release"
gpg --batch --yes -u "$KEYID" -abs --digest-algo SHA256 \
  -o "dists/$SUITE/Release.gpg" "dists/$SUITE/Release"

# The armored public key served at the repo root (target of the curl line).
gpg --armor --export "$KEYID" > spectroscope.asc

# GitHub Pages: keep Jekyll away from the tree.
touch .nojekyll

echo "repo regenerated:"
find dists pool -type f | sort
