// apt.spectroscope.dev — the signed apt repository.
//
// Almost everything here is a static asset, exactly like the two sibling
// workers (spectroscope-website, spectroscope-dev): dists/, spectroscope.asc
// and README.md go out through the ASSETS binding untouched. That upload is
// eleven files, the largest of them tens of kilobytes (InRelease is 2309
// bytes), so the asset size limit is nowhere near it.
//
// The packages do not. One deb is 187306536 bytes = 178.6 MiB, and a Workers
// static asset may be at most 25 MiB
// (https://developers.cloudflare.com/workers/platform/limits/, "Individual
// file size: 25 MiB", same on Free and Paid). So /pool/** is the one path
// this worker answers itself: a 302 at whatever URL actually holds the file.
//
// WHY THE REDIRECT CANNOT WEAKEN ANYTHING
//
// apt does not trust a package because of where it came from. It hashes the
// bytes it received against the SHA256 in the Packages index, and that index
// is covered by the signature on InRelease, which apt checks against the one
// key pinned by signed-by. The pool host is untrusted by construction: it can
// break an install, never quietly change one.
//
// Measured, not assumed (debian:12, apt 2.6.1 amd64, seven runs):
//
//   - full install across a 302 to a second host: "Setting up spectroscope
//     (0.4.2~dev.4d46480) ...", apt-get install exit 0. The redirecting host
//     never served a byte of the deb.
//   - same 302, but the target served a deb with one byte flipped at offset
//     100000000 and the length preserved, so only the hash could catch it:
//         E: Failed to fetch ...  Hash Sum mismatch
//          - SHA256:2fb23c69f06b950fb73b8740b874b87c4ef2d8bb886dae3a1be32e005c245a4f  (expected)
//          - SHA256:d9d836809e5ea08a281a1f79a29624a652ad840620fd25130c76442cbb97d5a5  (received)
//         apt-get install exit 100
//     The bytes were quarantined as *.deb.FAILED and never unpacked;
//     afterwards "dpkg-query: no packages found matching spectroscope".
//   - a wrong-sized body is refused earlier still, before the hash:
//         File has unexpected size (38 != 187306536). Mirror sync in progress?
//   - a dropped transfer resumes with "Range: bytes=40000000-" sent straight
//     to the redirect target, not back through here. The pool host must
//     therefore be directly reachable and should serve a stable
//     Last-Modified for If-Range. A target with no Range support still
//     installs, it just refetches from zero.
//
// THE MAPPING IS DATA, NEVER A GUESS
//
// pool-map.json names every deb we serve and the exact URL that holds it. A
// filename that is not in it gets a 404 from here, with a body that says so,
// rather than a redirect into somebody else's 404. An index that promises a
// file nobody serves is the failure this whole layer exists to prevent, and
// a guessed URL is that failure wearing a redirect.

const POOL_PREFIX = "/pool/";
const POOL_MAP_PATH = "/pool-map.json";

// Per-isolate memo. The map ships as an asset alongside this script, so a new
// map only ever arrives with a new deployment, which brings new isolates.
// Only successful reads are cached; a transient failure must not stick.
let poolMap = null;

async function loadPoolMap(env, request) {
  if (poolMap) return poolMap;
  const res = await env.ASSETS.fetch(new Request(new URL(POOL_MAP_PATH, request.url)));
  if (!res.ok) throw new Error(`pool-map.json unavailable (HTTP ${res.status})`);
  const parsed = await res.json();
  const packages = parsed && parsed.packages;
  if (!packages || typeof packages !== "object" || Array.isArray(packages)) {
    throw new Error("pool-map.json has no packages object");
  }
  poolMap = packages;
  return poolMap;
}

function line(status, text) {
  return new Response(`${text}\n`, {
    status,
    headers: { "content-type": "text/plain; charset=utf-8" },
  });
}

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (!pathname.startsWith(POOL_PREFIX)) {
      return env.ASSETS.fetch(request);
    }

    // Only the basename is looked up. Nothing in the rest of the path is
    // interpreted, so a crafted /pool/ path cannot reach anything.
    const raw = pathname.slice(pathname.lastIndexOf("/") + 1);
    let filename = raw;
    try {
      filename = decodeURIComponent(raw);
    } catch {
      // malformed percent-encoding: fall through with the raw name and let
      // the lookup miss, rather than throwing
    }

    if (filename === "") {
      return line(404, `no package named in ${pathname}`);
    }

    let packages;
    try {
      packages = await loadPoolMap(env, request);
    } catch (err) {
      return line(503, `pool map unreadable: ${err.message}`);
    }

    // hasOwnProperty, so that "constructor" or "__proto__" as a filename
    // resolves to a miss instead of an inherited property.
    const target = Object.prototype.hasOwnProperty.call(packages, filename)
      ? packages[filename]
      : null;
    if (typeof target !== "string" || target === "") {
      return line(404, `no pool entry for ${filename} — see pool-map.json at the root of this repository`);
    }
    try {
      new URL(target);
    } catch {
      return line(503, `pool entry for ${filename} is not an absolute URL`);
    }

    // 302, not 301: the pool location must stay movable. The Filename: field
    // in the signed index is relative, so moving a package between hosts
    // never requires re-signing anything.
    return Response.redirect(target, 302);
  },
};
