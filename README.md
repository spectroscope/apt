# spectroscope apt repository

A static apt repository for [spectroscope](https://spectroscope.ai), the agent
orchestrator you can watch. Everything a client needs is in this tree: signed
indexes under `dists/`, packages under `pool/`, the public signing key at the
root. It is a directory of files. Nothing is generated at request time.

The tree is meant to be served as plain static files by GitHub Pages from this
repo. **Pages is not switched on yet.** Once it is, the base URL is:

```
https://spectroscope.github.io/apt
```

Every command below already uses that address, so they start working the moment
Pages serves this repo. Right now it answers `404` (checked 2026-07-31, for the
root, the key and `dists/stable/InRelease`).

## Der Stand, gemessen am 31.07.2026

Die Indexe sind **live**: `https://spectroscope.github.io/apt` liefert
`dists/stable/InRelease`, `Packages` und `spectroscope.asc`, und ein frischer
debian-12-Container akzeptiert sie mit den zwei dokumentierten Zeilen -
`apt update` endet mit Exit 0, ohne eine einzige Signatur-Warnung, und
`apt-cache policy spectroscope` nennt `Candidate: 0.4.2~dev.4d46480`.

**Der Pool wird noch nicht ausgeliefert, und das ist bekannt.** GitHub weist
jede Datei über 100 MB ab (gemessen beim ersten Push: `GH001 ... is 178.63 MB;
this exceeds GitHub's file size limit of 100.00 MB`), und Git LFS hilft nicht,
weil Pages den Zeiger ausliefert statt des Objekts. `apt install spectroscope`
gegen die Live-URL endet deshalb heute mit `404 Not Found` auf den Pfad unter
`pool/`. Dass die Kette sonst trägt, ist getrennt bewiesen: gegen denselben
Baum lokal ausgeliefert installieren debian 12 und ubuntu 24.04 das Paket
sauber, und drei Manipulationsversuche (gekipptes Byte, entfernte Signatur,
fremder Schlüssel) werden von apt abgewiesen.

**Offener Owner-Entscheid: wo der Pool liegt.** Zwei Wege, beide ohne neue
Kosten:

1. **GitHub-Release-Assets plus Umleitung.** Die Pakete hängen ohnehin am
   Release (Schritt 8c des Playbooks). Ein kleiner Worker unter einer eigenen
   Domain liefert `dists/` aus diesem Repo und leitet `pool/...` per 302 auf
   das Release-Asset um; apt folgt Umleitungen.
2. **Objektspeicher** (Cloudflare R2 oder vergleichbar) als Basis für den
   ganzen Baum, dieses Repo bleibt die Quelle.

Bis einer davon steht, ist dieses Repo der signierte Index samt Schlüssel und
Werkzeug, nicht die Bezugsquelle.

## Install

```sh
curl -fsSL https://spectroscope.github.io/apt/spectroscope.asc | sudo gpg --dearmor -o /usr/share/keyrings/spectroscope.gpg
echo "deb [signed-by=/usr/share/keyrings/spectroscope.gpg] https://spectroscope.github.io/apt stable main" | sudo tee /etc/apt/sources.list.d/spectroscope.list
```

Then apt takes over:

```sh
sudo apt update
sudo apt install spectroscope
```

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
pool/main/s/spectroscope/spectroscope_0.4.2-dev.4d46480_amd64.deb
version  0.4.2~dev.4d46480
size     187306536 bytes
sha256   2fb23c69f06b950fb73b8740b874b87c4ef2d8bb886dae3a1be32e005c245a4f
```

**This is a development build, not a release.** It is the artifact of CI run
30632819244, stamped with the commit it was built from (`4d46480`), and it went
into the pool byte for byte: the sha256 above is the one the run recorded in
its own `SHA256SUMS.linux`, the one measured on the file here, and the one in
the signed index. Releases arrive as ordinary versions with no `~dev` segment.

The `~` is what makes that version sort correctly. dpkg orders a `~` segment
below the empty string, so the build sits between the last release and the one
it is heading for:

```
$ dpkg --compare-versions 0.4.1 lt 0.4.2~dev.4d46480     # true
$ dpkg --compare-versions 0.4.2~dev.4d46480 lt 0.4.2     # true
```

So `apt upgrade` replaces it with 0.4.2 the day 0.4.2 is pooled, and never the
other way around.

`dists/stable/main/binary-arm64/Packages` exists and is covered by the
signature, but it is empty. There is no arm64 package yet.

## Verification

Measured 2026-07-31 against this tree, with the deb and indexes exactly as they
are committed here.

### debian 12 and ubuntu 24.04

Two clean containers, each running the documented install lines verbatim, with
only the URL pointed at a throwaway `python3 -m http.server` on this tree.
`Debian GNU/Linux 12 (bookworm)` and `Ubuntu 24.04.4 LTS`, both amd64, with the
same result:

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
expected from the signed index, the hash it actually received, and stops:

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

One command per new deb:

```sh
scripts/update-repo.sh /path/to/spectroscope_<version>_<arch>.deb
```

It works inside a `debian:12` container, because the host is macOS and has no
dpkg, and it runs in this order: check the key home for a secret key, copy the
deb into `pool/`, regenerate `Packages`, `Packages.gz` and `Release` with
`dpkg-scanpackages` and `apt-ftparchive`, clearsign `InRelease`, write the
detached `Release.gpg`, re-export `spectroscope.asc`, then verify both
signatures with `gpgv` against that exported public key. Any failing leg exits
non-zero.

The key check happens before the deb gets anywhere near `pool/`, so a refused
run leaves the tree exactly as it was. All three refusals below were measured,
and the hash over the whole tree was identical before and after:

```
$ SPECTRO_APT_KEYHOME=/tmp/definitely-not-a-key-home scripts/update-repo.sh <deb>
refusing: apt signing key home missing at /tmp/definitely-not-a-key-home
$ scripts/update-repo.sh /etc/hosts
refusing: not a .deb: /etc/hosts
$ scripts/update-repo.sh /tmp/nope.deb
refusing: no such file: /tmp/nope.deb
```

The key home defaults to `~/.spectroscope-apt-key` and moves with
`SPECTRO_APT_KEYHOME`. It is a local credential, never part of this repo; the
recipe that mints it is `scripts/apt-signing-key.batch`. `.nojekyll` sits at
the root for Pages, and `make-apt-repo.sh` re-creates it on every run.

Then review the diff, commit, and push to the repository Pages serves: with
Pages on, the push is what publishes.

One caution before that first push: the pooled deb is 187306536 bytes, 178.6
MiB, and GitHub documents a hard limit of 100 MiB for a single file arriving
over a push. Nothing has been pushed from here, so that limit has not been
exercised yet. The first push is the test.
