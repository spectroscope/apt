# spectroscope apt repository

A static apt repository for [spectroscope](https://spectroscope.ai), the agent
orchestrator you can watch. The signed indexes live under `dists/` and the
public signing key at the root; both are committed here and served as plain
files. The packages do not fit in either place they could be served from, so
they live at the release assets and the worker in `src/` points apt at them.

The base URL the install lines use is:

```
https://apt.spectroscope.dev
```

That name is a Cloudflare Worker (`wrangler.jsonc`, `src/worker.js`): it serves
this tree through the assets binding and answers `pool/` with a redirect, and it
is live. The same indexes are also served over GitHub Pages at
`https://spectroscope.github.io/apt`, which carries everything except the pool.

## Status, measured 2026-07-31

**The repository is live.** `https://apt.spectroscope.dev` serves the indexes,
the key and the pool redirect. The documented install lines bring
`spectroscope 0.5.0` into a clean container on Debian 12 (apt 2.6.1) and on
Ubuntu 24.04 (apt 2.8.3), both exit 0, neither with a signature warning.
`/usr/bin/spectroscope` is on PATH afterwards through update-alternatives,
`dpkg -V` stays silent, and `~/.spectro` survives an `apt remove` unchanged.

The pool holds exactly one package: `spectroscope_0.5.0_amd64.deb`, 187306672
bytes (178.63 MiB), sha256 `7f25fd52...df62f`, redirected to the asset of the
v0.5.0 release. `amd64` is the only architecture shipped; on arm64 apt takes
this source without error and then finds nothing to install.

**If apt is not your route.** The same v0.5.0 release carries
`spectroscope-0.5.0-x86_64.AppImage` for x86_64 distributions that do not use
apt, a signed and notarized `spectroscope-0.5.0-arm64.dmg` for macOS on Apple
silicon (also installable as `brew install --cask
spectroscope/tap/spectroscope`), and the CLI zip and the server jar, which need
a JDK 21 and run anywhere. There is no arm64 Linux package and no Windows
package: on arm64 Linux, run the CLI or the server jar.

**The pool is not in this repository, and it cannot be.** GitHub refuses any
file over 100 MB (measured on the first push: `GH001 ... is 178.63 MB; this
exceeds GitHub's file size limit of 100.00 MB`), and Git LFS does not help,
because Pages serves the pointer instead of the object. That the chain holds
otherwise is proven separately: served locally against this same tree, debian 12
and ubuntu 24.04 install the package cleanly, and three tampering attempts (a
flipped byte, a stripped signature, a foreign key) are refused by apt.

## The shape that was built: indexes here, packages at the release

Of the two routes that stood to choice, this is route 1: **release assets plus a
redirect**, no object store.

`apt.spectroscope.dev` is a Cloudflare Worker on the same pattern as
spectroscope.ai and spectroscope.dev, assets first, no build step. Everything
except `pool/` leaves the assets binding untouched, which is eleven files, the
largest around 17 KB (measured 2026-07-31). A package does not fit in there: the
deb is 187306672 bytes, so 178.63 MiB, and a static asset at Cloudflare may be
**25 MiB**. So the worker answers `pool/` itself, with a **302 to the URL that
really holds the bytes**.

Which URL that is, is **never guessed**. `pool-map.json` names every filename and
its target; a name missing from it gets a `404` from the worker saying exactly
that, instead of a redirect into somebody else's nothing.
`scripts/update-repo.sh` writes the entry while pooling and refuses to run
without `--url`. A signed index that promises a file nobody serves is the
failure this whole layer is built against.

**The redirect weakens nothing.** apt does not trust a package for where it came
from: it hashes the received bytes against the SHA256 from the index, and that
index hangs off the signature on `InRelease`, which apt checks against the one
key pinned by `signed-by`. Measured on debian 12 with apt 2.6.1, seven runs:
across a 302 the package installs cleanly (`apt-get install exit 0`), and a
target that serves the same filename with **one flipped byte at the same
length** is refused:

```
E: Failed to fetch ...  Hash Sum mismatch
 - SHA256:7f25fd52...  (expected, from the signed index)
 - SHA256:d9d83680...  (received)
--- apt-get install exit=100 ---
```

Nothing was unpacked; the bytes landed in quarantine as `*.deb.FAILED`. A wrong
size is caught even earlier (`File has unexpected size (38 != 187306672)`). By
construction the pool host is untrusted: it can make an installation fail, never
quietly change one.

Two things measured along the way that affect operation. apt prints the worker's
address in its `Get:` lines, not the target's, so the branded URL is the one
users see. After an abort, though, apt resumes the download **straight at the
target** (`Range: bytes=40000000-`), not through the worker again, so the pool
host has to be reachable directly and should serve a stable `Last-Modified`.

**What happens when a file has no entry.** The worker never guesses a URL. A
filename without an entry in `pool-map.json` gets a 404 that names it:

```
404  no pool entry for <file>.deb — see pool-map.json at the root of this repository
```

Until the 0.5.0 release that was the real state of this repository: the index
carried a development build that no release shipped. A guessed link would not
have been progress, only the same 404 one layer later and with the blame in the
wrong place. That is why `scripts/update-repo.sh` insists on `--url`.

## Install

```sh
curl -fsSL https://apt.spectroscope.dev/spectroscope.asc | sudo gpg --dearmor -o /usr/share/keyrings/spectroscope.gpg
echo "deb [signed-by=/usr/share/keyrings/spectroscope.gpg] https://apt.spectroscope.dev stable main" | sudo tee /etc/apt/sources.list.d/spectroscope.list
```

Those two lines are the whole client side, and they are the reason the worker
serves `dists/` and `pool/` under one hostname: a sources.list entry names one
base URL, and everything apt fetches hangs off it. The `Filename:` field in the
signed index stays relative, so moving a package between hosts never means
re-signing anything.

Then apt takes over:

```sh
sudo apt update
sudo apt install spectroscope
```

That last line waits for you twice, and in a container nobody answers either
time. apt asks you to confirm the download first, and on a machine where
`tzdata` has never been configured a package several levels down the chain then
asks which timezone you live in. Neither question times out. Stuck at the first
one, nothing has been downloaded; stuck at the second, spectroscope is unpacked
and never configured. Where nobody is at the keyboard, use this instead:

```sh
sudo DEBIAN_FRONTEND=noninteractive apt install -y spectroscope
```

`-y` answers apt's own confirmation and `DEBIAN_FRONTEND=noninteractive`
answers the timezone question, which then settles on `Etc/UTC` without telling
you. That is the right trade in a container and the wrong one on a machine you
are setting up by hand, which is why it stands next to the documented line
rather than replacing it.

Only the Ubuntu half of that pair is affected. Debian 12 ships `tzdata` already
configured, and its `systemd` does not recommend the Python network dispatcher
that drags `tzdata` in on Ubuntu. A full Ubuntu server or desktop install is
fine as well, because `tzdata` is priority-important and configured long before
this repository is added. Minimal container images and chroots are the ones
that strip it. Measured 2026-08-03 on `ubuntu:24.04` amd64 against this live
repository: the unattended line reaches `Setting up spectroscope` in 2m 01s with
zero prompts and zero half-configured packages.

`signed-by` binds that one keyring to this one source. There is no
`trusted=yes` and no allow-insecure switch in this repo or in the lines above:
apt checks the `InRelease` signature against the pinned key, and every package
hash against the signed index.

The package unpacks to `/opt/spectroscope` and registers
`/usr/bin/spectroscope` through `update-alternatives`. `sudo apt remove
spectroscope` takes those files back off. `~/.spectro` holds your sessions,
settings and downloaded models; install and remove both leave it alone.

## Signing key

```
spectroscope apt <chris@spectroscope.ai>
ed25519, [SC], no expiry, no subkeys
fingerprint  E603 2682 4E65 D5CB 3116  02D7 9DF6 0ECC 1605 83D8
```

This key signs the apt indexes and nothing else. It is deliberately not the
Maven signing key: revoking one surface must never break the other.

`spectroscope.asc` at the root is the armored public half and only that. It
carries zero `PRIVATE KEY BLOCK`s. The secret half lives in a local key home
outside this repo and is never committed.

If the key is ever rotated, running the first install line again replaces the
pinned keyring in place.

## What is in the pool right now

One package, amd64 only:

```
pool/main/s/spectroscope/spectroscope_0.5.0_amd64.deb
version  0.5.0
size     187306672 bytes
sha256   7f25fd52c5a29ab8cc6e955f5b165ce9b2fa513aa9b8e086c6a88ab8234df62f
```

**This is the release build.** It is the artifact CI produced against the tag
`v0.5.0`, and it went into the pool byte for byte: the sha256 above is the one
the run recorded, the one measured on the file here, the one in the signed
index, and the one apt checks after following the redirect. `pool-map.json`
points it at the release asset it is served from.

The pool held a development build before this one, `0.4.2~dev.4d46480`, and how
it was versioned is worth keeping as a note, because every future dev build
takes the same shape. A `~` segment sorts below the empty string in dpkg, so a
build made past one release and before the next sits exactly between them:

```
$ dpkg --compare-versions 0.4.1 lt 0.4.2~dev.4d46480     # true
$ dpkg --compare-versions 0.4.2~dev.4d46480 lt 0.4.2     # true
```

That is why a development build can never shadow a release: `apt upgrade`
replaces it the day the real version is pooled, and never the other way
around. The CI workflow stamps that form itself for any build that is not a
tag, and asserts the ordering before the artifact leaves the runner.

`dists/stable/main/binary-arm64/Packages` exists and is covered by the
signature, but it is empty. There is no arm64 package yet, and until there is,
arm64 Linux runs the CLI zip or the server jar from the same release on a
JDK 21.

## Verification

Measured 2026-07-31 against this tree, with the deb and indexes exactly as they
are committed here.

### debian 12 and ubuntu 24.04

Two clean containers, each running the documented install lines verbatim, with
only the URL pointed at a throwaway `python3 -m http.server` on this tree.
`Debian GNU/Linux 12 (bookworm)` and `Ubuntu 24.04.4 LTS`, both amd64, with the
same result. The transcript below is the local run from 2026-07-31, made
against the development build that was pooled at the time, served from a
throwaway http server: it is kept verbatim because it is what was actually
captured. The same two lines were run again the same evening against the live
`apt.spectroscope.dev` on Debian 12 (apt 2.6.1) and Ubuntu 24.04 (apt 2.8.3),
both ending at `Setting up spectroscope (0.5.0)`, exit 0, no signature
warning, `dpkg -V` silent over 553 files.

```
--- fingerprint apt is now pinned to ---
  E60326824E65D5CB311602D79DF60ECC160583D8
Get:1 http://...:8901 stable InRelease [2681 B]
Get:5 http://...:8901 stable/main amd64 Packages [545 B]
--- apt-get update exit=0 ---
  >>> ZERO matches: no signature warnings
Get:1 http://...:8901 stable/main amd64 spectroscope amd64 0.4.2~dev.4d46480 [187 MB]
Setting up spectroscope (0.4.2~dev.4d46480) ...
--- apt-get install exit=0 ---
$ which spectroscope -> /usr/bin/spectroscope
Status: install ok installed
Version: 0.4.2~dev.4d46480
files in package: 553
dpkg -V exit=0
```

The warning scan behind that "ZERO matches" line covers `NO_PUBKEY`,
`not signed`, `NODATA`, `EXPKEYSIG`, `BADSIG`, `REVKEYSIG`, `insecure`,
`untrusted`, `GPG error` and any `W:`, `E:` or `Err:` line. `dpkg -V` re-hashes
every installed file against the package's own manifest and reported nothing,
so what landed on disk is what the deb carries.

After `apt-get remove` (exit 0), `/usr/bin/spectroscope` and
`/opt/spectroscope` are gone, and a file written to `~/.spectro/sessions`
beforehand came through byte-identical (`93b1886a...` before and after) on both
distros.

### Signatures

From a container holding nothing but `spectroscope.asc`:

```
gpg: Good signature from "spectroscope apt <chris@spectroscope.ai>"    # InRelease
gpg: Good signature from "spectroscope apt <chris@spectroscope.ai>"    # Release.gpg + Release
Primary key fingerprint: E603 2682 4E65 D5CB 3116  02D7 9DF6 0ECC 1605 83D8
```

The clearsigned payload inside `InRelease` is byte-identical to `Release`
(`cmp` exit 0), and every hash in the `Release` SHA256 stanza matches the index
file it names.

### Tamper

Two attempts, both refused.

One flipped byte in the pooled deb, length preserved, indexes genuine. The
index is untouched, so `apt update` succeeds. apt then prints the hash it
expected from the signed index, the hash it actually received, and stops.
Verbatim from the run that produced it, on the build pooled at the time:

```
E: Failed to fetch .../spectroscope_0.4.2-dev.4d46480_amd64.deb  Hash Sum mismatch
    - SHA256:2fb23c69f06b950fb73b8740b874b87c4ef2d8bb886dae3a1be32e005c245a4f
    - SHA256:d9d836809e5ea08a281a1f79a29624a652ad840620fd25130c76442cbb97d5a5
--- apt-get install exit=100 ---
```

Nothing was installed afterwards: `dpkg-query: no packages found matching
spectroscope`, no `/opt/spectroscope`, nothing on PATH.

Both indexes re-signed by a freshly minted foreign key, with the genuine
`spectroscope.asc` still served, so the signature is well formed and merely
wrong:

```
Err:1 ... stable InRelease
  The following signatures couldn't be verified because the public key is not available: NO_PUBKEY A5A9E2D94091E6FC
E: The repository '... stable InRelease' is not signed.
--- apt-get update exit=100 ---
E: Unable to locate package spectroscope
```

That is what `signed-by` is there for. apt checks the signature against the one
key you pinned, so a signature from any other key fails even when it is
perfectly valid in itself.

### Running the check yourself

`scripts/verify-client.sh` does the whole client-side pass in one container:

```sh
docker run --rm -v "$PWD":/srv/apt:ro debian:12 sh /srv/apt/scripts/verify-client.sh
```

It serves the tree on a loopback `http.server`, runs the two documented lines,
installs, removes, confirms `~/.spectro` survived, and finishes with a negative
control that corrupts `Packages.gz` and requires apt to reject it. On
`debian:12` against this tree it ends:

```
=== negative control: tampered Packages.gz must fail ===
E: Failed to fetch file:/tmp/tampered/dists/stable/main/binary-amd64/Packages.gz  Hash Sum mismatch
TAMPER DETECTED (good)
CLIENT OK
```

The script exits non-zero at the first step that misbehaves, so `CLIENT OK` is
the only successful ending.

## Maintaining this repo (release playbook step 8c)

One command per new deb, and it needs the URL that will serve the file:

```sh
scripts/update-repo.sh \
  --url https://github.com/spectroscope/spectroscope/releases/download/v0.5.1/spectroscope_0.5.1_amd64.deb \
  /path/to/spectroscope_0.5.1_amd64.deb
```

It works inside a `debian:12` container, because the host is macOS and has no
dpkg, and it runs in this order: check the key home for a secret key, copy the
deb into `pool/`, write its entry into `pool-map.json`, regenerate `Packages`,
`Packages.gz` and `Release` with `dpkg-scanpackages` and `apt-ftparchive`,
clearsign `InRelease`, write the detached `Release.gpg`, re-export
`spectroscope.asc`, then verify both signatures with `gpgv` against that
exported public key. Any failing leg exits non-zero.

Pool and map move together, one after the other, so the tree never carries a
package the worker cannot point at. Re-running with the same filename and a
different `--url` replaces that one entry and leaves the rest of the map alone
(measured in `debian:12` with jq 1.6: two entries added, one refreshed in
place, key order and the `note` field intact).

The key check happens before the deb gets anywhere near `pool/`, so a refused
run leaves the tree exactly as it was. Every refusal below was measured on
2026-07-31, and the hash over the whole tree was identical before and after:

```
$ SPECTRO_APT_KEYHOME=/tmp/definitely-not-a-key-home scripts/update-repo.sh <deb>
refusing: apt signing key home missing at /tmp/definitely-not-a-key-home
$ scripts/update-repo.sh /etc/hosts
refusing: not a .deb: /etc/hosts
$ scripts/update-repo.sh /tmp/nope.deb
refusing: no such file: /tmp/nope.deb
$ scripts/update-repo.sh <deb>                       # no --url
refusing: no --url for spectroscope_0.4.2-dev.4d46480_amd64.deb
the pool map needs the URL that will actually serve this file, e.g.
  --url https://github.com/spectroscope/spectroscope/releases/download/v0.4.2/spectroscope_0.4.2-dev.4d46480_amd64.deb
without it the signed index would promise a package nobody serves
$ scripts/update-repo.sh --url http://example.com/x.deb <deb>
refusing: --url must be an https:// URL, got: http://example.com/x.deb
```

A `--url` whose last path segment differs from the deb's filename is allowed,
since the map is filename to URL, but it prints a note so a typo does not pass
unremarked.

The key home defaults to `~/.spectroscope-apt-key` and moves with
`SPECTRO_APT_KEYHOME`. It is a local credential, never part of this repo; the
recipe that mints it is `scripts/apt-signing-key.batch`. `.nojekyll` sits at
the root for Pages, and `make-apt-repo.sh` re-creates it on every run.

Then review the diff, commit, and push. The push is what publishes: Pages serves
the indexes straight from the repository, and Workers Builds redeploys the
worker on the same push. The deb itself never
travels with that push — `pool/` is gitignored, because GitHub refuses a
178.6 MiB file (`GH001`, measured). Uploading the package to its release is a
separate, manual step, and until it is done the entry `update-repo.sh` just
wrote points at a URL that answers 404.

## What is still open

The three setup steps this section used to list are done: the repository is
connected to a Worker, `apt.spectroscope.dev` is attached as a custom domain and
resolves, and the deb hangs off the v0.5.0 release with its URL recorded in
`pool-map.json`.

What remains:

1. **No arm64 package.** The signed arm64 index is there and empty. Pooling one
   needs an arm64 build first; there is none in the v0.5.0 release.
2. **Two things this repository has never measured.** Whether `.assetsignore`
   really keeps the machinery (`src/`, `scripts/`, `pool/`, `.git`) out of the
   deployed tree: the file is documented and has `.gitignore` format, but no
   check here confirms it. And whether GitHub's release CDN answers the `Range`
   requests apt uses to resume an aborted download; a full download is proven,
   a resumed one is not. Worst case for the first is a few extra files in the
   served tree. No key material is among them, and `.gitignore` is what keeps it
   that way.
