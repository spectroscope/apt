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
this tree through the assets binding and answers `pool/` with a redirect.
**It is not deployed yet.** The worker, its config and the pool map are
committed here, but connecting this repository to a Worker and attaching the
custom domain are dashboard steps, so the address does not resolve today. The
same indexes are already live over GitHub Pages at
`https://spectroscope.github.io/apt`, which serves everything except the pool.

## Der Stand, gemessen am 31.07.2026

Die Indexe sind **live**: `https://spectroscope.github.io/apt` liefert
`dists/stable/InRelease`, `Packages` und `spectroscope.asc`, und ein frischer
debian-12-Container akzeptiert sie mit den zwei dokumentierten Zeilen -
`apt update` endet mit Exit 0, ohne eine einzige Signatur-Warnung, und
`apt-cache policy spectroscope` nennt `Candidate: 0.4.2~dev.4d46480`.

**Der Pool liegt nicht in diesem Repo, und er kann es auch nicht.** GitHub
weist jede Datei über 100 MB ab (gemessen beim ersten Push: `GH001 ... is
178.63 MB; this exceeds GitHub's file size limit of 100.00 MB`), und Git LFS
hilft nicht, weil Pages den Zeiger ausliefert statt des Objekts. Dass die
Kette sonst trägt, ist getrennt bewiesen: gegen denselben Baum lokal
ausgeliefert installieren debian 12 und ubuntu 24.04 das Paket sauber, und drei
Manipulationsversuche (gekipptes Byte, entfernte Signatur, fremder Schlüssel)
werden von apt abgewiesen.

## Der gewählte Aufbau: Indexe hier, Pakete am Release

Gebaut ist Weg 1 der beiden, die hier vorher zur Wahl standen:
**Release-Assets plus Umleitung**, kein Objektspeicher.

`apt.spectroscope.dev` ist ein Cloudflare Worker nach demselben Muster wie
spectroscope.ai und spectroscope.dev — Assets first, kein Build-Schritt. Alles
außer `pool/` geht unverändert aus der Assets-Bindung raus; das sind elf
Dateien, die größte rund 17 KB (gemessen 31.07.2026). Ein Paket paßt da nicht
hinein: der deb ist 187306536 Bytes, also 178,6 MiB, und ein statisches Asset
darf bei Cloudflare **25 MiB** groß sein. Also beantwortet der Worker `pool/`
selbst, mit einem **302 auf die URL, die die Bytes wirklich hält**.

Welche URL das ist, wird **nie geraten**. `pool-map.json` nennt jeden Dateinamen
und sein Ziel; ein Name, der dort fehlt, bekommt vom Worker einen `404` mit
genau dieser Auskunft, statt einer Umleitung in ein fremdes Nichts.
`scripts/update-repo.sh` schreibt den Eintrag beim Poolen und verweigert den
Dienst ohne `--url` — ein signierter Index, der eine Datei verspricht, die
niemand ausliefert, ist der Fehler, gegen den diese ganze Schicht gebaut ist.

**Die Umleitung schwächt nichts ab.** apt vertraut einem Paket nicht wegen
seiner Herkunft: es hasht die empfangenen Bytes gegen den SHA256 aus dem Index,
und dieser Index hängt an der Signatur von `InRelease`, die apt gegen den einen
per `signed-by` gepinnten Schlüssel prüft. Gemessen an debian 12 mit apt 2.6.1,
sieben Läufe: über ein 302 hinweg installiert das Paket sauber (`apt-get install
exit 0`), und ein Ziel, das denselben Dateinamen mit **einem gekippten Byte bei
gleicher Länge** ausliefert, wird abgewiesen:

```
E: Failed to fetch ...  Hash Sum mismatch
 - SHA256:2fb23c69...  (erwartet, aus dem signierten Index)
 - SHA256:d9d83680...  (empfangen)
--- apt-get install exit=100 ---
```

Nichts wurde ausgepackt, die Bytes landeten als `*.deb.FAILED` in Quarantäne.
Eine falsche Größe fliegt noch früher auf (`File has unexpected size (38 !=
187306536)`). Der Pool-Host ist damit von Bauart her unvertrauenswürdig: er
kann eine Installation scheitern lassen, niemals eine stillschweigend
verändern.

Zwei Dinge, die dabei gemessen wurden und den Betrieb betreffen: apt zeigt in
seinen `Get:`-Zeilen die Adresse des Worker an, nicht die des Ziels — die
Marken-URL ist die, die Anwender sehen. Nach einem Abbruch nimmt apt den
Download aber **direkt beim Ziel** wieder auf (`Range: bytes=40000000-`), nicht
noch einmal über den Worker; der Pool-Host muß also direkt erreichbar sein und
sollte ein stabiles `Last-Modified` liefern.

**Der Entwicklungs-Build im Index hat noch kein öffentliches Asset.** Für
`spectroscope_0.4.2-dev.4d46480_amd64.deb` steht deshalb kein Eintrag in
`pool-map.json`, und der Worker antwortet ehrlich:

```
404  no pool entry for spectroscope_0.4.2-dev.4d46480_amd64.deb — see pool-map.json at the root of this repository
```

Das bleibt so, bis der Owner die Datei an ein Release oder ein Prerelease
hängt und ihre URL mit `scripts/update-repo.sh --url` einträgt. Ein geratener
Link wäre kein Fortschritt, sondern derselbe 404 eine Ebene später.

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

It sits in the local `pool/` (gitignored) and in the signed index, but it has
no entry in `pool-map.json`, because no public URL serves it yet. See the
section above for what the worker answers in the meantime.

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

One command per new deb, and it needs the URL that will serve the file:

```sh
scripts/update-repo.sh \
  --url https://github.com/spectroscope/spectroscope/releases/download/v0.4.2/spectroscope_0.4.2_amd64.deb \
  /path/to/spectroscope_0.4.2_amd64.deb
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

Then review the diff, commit, and push. The push is what publishes: Pages
serves the indexes straight from the repository, and once the worker is
connected, Workers Builds redeploys it on the same push. The deb itself never
travels with that push — `pool/` is gitignored, because GitHub refuses a
178.6 MiB file (`GH001`, measured). Uploading the package to its release is a
separate, manual step, and until it is done the entry `update-repo.sh` just
wrote points at a URL that answers 404.

## Was noch offen ist

Drei Schritte, alle beim Owner, alle nach außen gerichtet:

1. **Das Repository mit einem Worker verbinden** (Workers & Pages → Settings →
   Builds → Connect, Deploy-Kommando `npx wrangler deploy`, wie bei
   spectroscope-dev). Der OAuth-Zugriff auf GitHub läßt sich in keiner
   Konfigurationsdatei ausdrücken.
2. **`apt.spectroscope.dev` als Custom Domain anhängen.** Cloudflare legt den
   DNS-Eintrag an und stellt das Zertifikat selbst aus; Voraussetzung ist, daß
   für den Namen noch kein CNAME in der Zone steht. Alternativ die
   `routes`-Zeile aus `wrangler.jsonc` einkommentieren, dann erledigt das der
   erste Deploy.
3. **Den deb an ein Release oder Prerelease hängen** und die URL mit
   `scripts/update-repo.sh --url` eintragen. Vorher gibt es nichts, worauf der
   Worker umleiten könnte.

Ungemessen bleibt bis zum ersten Deploy zweierlei: ob `.assetsignore` die
Maschinerie (`src/`, `scripts/`, `pool/`, `.git`) wirklich aus dem Upload
hält — die Datei ist dokumentiert und hat `.gitignore`-Format, aber geprüft ist
sie hier nicht —, und ob GitHubs Release-CDN die `Range`-Anfragen beantwortet,
mit denen apt einen abgebrochenen Download fortsetzt. Beides fällt beim ersten
echten Lauf auf. Schlimmstenfalls landen ein paar Dateien mehr im
ausgelieferten Baum; Schlüsselmaterial ist keines darunter, dafür sorgt die
`.gitignore`.
