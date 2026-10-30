# fetcher

A caching HTTP fetcher with a frozen, browsable URL tree.

`fetcher` downloads files on behalf of HTTP clients and keeps them in a plain
directory tree named after their URLs. It does three things that no standard
proxy does together:

- **Files live at `<root>/<host>/<path>`, nothing hashed.** Any file can be
  found, inspected, deleted or replaced by hand with `ls` and `rm`.
- **One upstream fetch per URL, however many clients ask at once.** Twenty
  concurrent requests for an absent file become one upstream request; the
  other nineteen wait for it and are served from disk.
- **Nothing is refreshed or expired.** HTTP freshness headers are ignored. A
  file is served forever until an operator deletes it, at which point the next
  request fetches it again.

It was written for [day10](https://github.com/mtelvers/day10), where it stops
N containers under test from downloading the same source archive at the same
moment and keeps builds working through upstream outages, but it is a general
tool: any client that speaks HTTP `GET` works unchanged.

## How clients use it

Clients are not proxied. Almost every mirror and source URL is `https`, and an
`https_proxy` setting makes the client tunnel TLS straight through the proxy,
which then sees nothing it could cache. Instead, clients are pointed at the
cache by rewriting the URLs they already hold:

    https://deb.debian.org/debian/dists/trixie/InRelease
    becomes
    http://cache:8080/https/deb.debian.org/debian/dists/trixie/InRelease

The scheme is the first path segment, then the host (with an optional port),
then the upstream path. The cache terminates TLS to the origin itself, so no
client needs a proxy setting, a certificate or a new tool.

`fetcher url` prints the rewrite for you:

    $ fetcher url --cache http://10.0.0.1:8080 https://deb.debian.org/debian/dists/trixie/InRelease
    http://10.0.0.1:8080/https/deb.debian.org/debian/dists/trixie/InRelease

Typical rewrites for package managers:

| Client | Where the URL lives | Rewrite |
| --- | --- | --- |
| apt | `/etc/apt/sources.list.d/*.sources`, `URIs:` | `http://cache/https/deb.debian.org/debian` |
| dnf | `/etc/yum.repos.d/*.repo` | replace `metalink=`/`mirrorlist=` with one `baseurl=http://cache/https/dl.fedoraproject.org/...`; a mirror list hands the client a different host each time and defeats the tree |
| pacman | `/etc/pacman.d/mirrorlist` | `Server = http://cache/https/geo.mirror.pkgbuild.com/$repo/os/$arch` |
| apk | `/etc/apk/repositories` | `http://cache/https/dl-cdn.alpinelinux.org/alpine/v3.22/main` |
| zypper | `/etc/zypp/repos.d/*.repo`, `baseurl=` | `http://cache/https/download.opensuse.org/...` |
| opam | `download-command` in the switch config, or `OPAMFETCH` | `fetcher download`, below |

Where an app has a download hook rather than a base URL, `fetcher download`
is the client: it fetches a URL through the cache and writes the file.

    fetcher download --cache 10.0.0.1:8080 https://opam.ocaml.org/foo/bar/baz.tgz -o baz.tgz

For opam, set it as the download command, either persistently

    opam option download-command='["fetcher" "download" "--cache" "10.0.0.1:8080" "%{url}%" "-o" "%{out}%"]'

or for one session or CI job

    export OPAMFETCH="fetcher download --cache 10.0.0.1:8080 %{url}% -o %{out}%"

opam then fetches every source archive, including those it finds through
`archive-mirrors`, via the cache, and still verifies the checksum itself. The
`fetcher` binary is the only thing the image needs; it does not use curl on
the client side. `FETCHER_CACHE` in the environment replaces `--cache`.

Redirects from upstream are followed by the fetcher and the result is stored
under the URL the client asked for, so a mirror that redirects still produces
a tree keyed by what the clients know.

## Running it

    fetcher serve --root /var/cache/fetcher --listen 0.0.0.0:8080

One line is logged per request, with the outcome, method, path, status, bytes
sent and elapsed milliseconds:

    2026-10-30T08:42:47Z: miss GET /https/deb.debian.org/debian/dists/trixie/Release.gpg 200 1760 77ms
    2026-10-30T08:42:48Z: hit GET /https/deb.debian.org/debian/dists/trixie/Release.gpg 200 1760 0ms
    2026-10-30T08:42:48Z: wait GET /https/deb.debian.org/debian/dists/trixie/Release.gpg 200 1760 61ms
    2026-10-30T08:42:51Z: fail GET /https/no.such.host.invalid/x 502 0 3100ms

`hit` means the file was on disk, `miss` that this request fetched it, `wait`
that it waited for a fetch another request had started, and `fail` that no
file was served. The number of `wait` lines is the number of duplicate
downloads the cache removed.

Options (see `fetcher serve --help`):

| Option | Default | Meaning |
| --- | --- | --- |
| `--root DIR` | `/var/cache/fetcher` | The tree. Also `FETCHER_ROOT`. |
| `--listen HOST:PORT` | `127.0.0.1:8080` | Containers need an address routable from them, such as the docker bridge address. Also `FETCHER_LISTEN`. |
| `--retries N` | 3 | Attempts for 5xx, connection and transfer failures. 4xx answers are never retried. |
| `--connect-timeout S` | 30 | Passed to curl. |
| `--stall-timeout S` | 60 | A transfer with no progress for this long is abandoned and retried. |
| `--curl PATH` | `curl` | Upstream fetches run curl, so TLS, redirects and proxies come for free. |
| `--max-connections N` | 1024 | Simultaneous client connections. |
| `--log-level LEVEL` | `info` | `quiet`, `error`, `warning`, `info` or `debug`. |

A systemd unit is in `contrib/fetcher.service`. The process holds no state
beyond the tree, so a restart during a fetch costs one retry by the client.

## Behaviour in detail

**Hit.** The file exists at its final path, which by construction means it is
complete. It is served with `Content-Length`, `Accept-Ranges: bytes`,
`Last-Modified` and an `X-Cache: HIT` header. `HEAD` and a single `Range`
are honoured; `apk` and `pacman` issue `HEAD`, `dnf` resumes with `Range`.

**Miss.** The fetcher registers the path as in flight, confirms the file is
still absent, and runs curl to stream upstream into `<path>.part-<pid>` in
the same directory. On a clean end of body the part file is renamed into
place. Any other outcome deletes the part file. The client gets
`X-Cache: MISS`.

**Wait.** A request that finds the path in flight waits for that fetch, then
serves the file or returns the same failure. Waiters do not stream from the
part file: a corrupt upstream stream must not reach every waiter, and the tail
of a large archive arriving late costs nothing a build notices. The client
gets `X-Cache: WAIT`.

**Freshness.** None. `Cache-Control`, `Expires` and `Last-Modified` from
upstream are ignored and no conditional request is ever sent. Package files
and source archives are immutable by name on every mirror and forge, and
index files are frozen on purpose: a frozen index is what keeps a set of
packages consistent between builds. To advance, delete the index files under
the tree and let the next request fetch them.

**Checksums.** Not verified. Every client that matters (apt, dnf, pacman,
apk, zypper, opam) already checks what it downloads and names the URL in its
error, which is also the file's path in the tree. Delete the file to fix it.

**Failures.** The tree never holds a file the fetcher did not see arrive
whole, and a client always learns the truth about upstream.

| Event | Cache behaviour | Client sees |
| --- | --- | --- |
| Upstream 4xx | Nothing stored, not retried | The same status |
| Upstream 5xx, connection refused, DNS or TLS failure | Nothing stored, retried with backoff | 502 with the reason in the body |
| Body shorter than `Content-Length`, or stalled | Part file deleted, retried | 502 if all retries fail |
| Disk full | Part file deleted | 507 |
| The only requester disconnects mid-fetch | The fetch completes anyway; the next request will want the file | Nothing |
| Cache process down | | Connection refused; a build fails fast at its first download |
| Upstream unreachable but file cached | Served from disk | Normal, which is the point |

There is deliberately no fallback to direct fetching when the cache is down.
A silent fallback would hide an outage behind a slower, flakier build.

## Operations

- **Layout.** `<root>/<host>/<path>`. A URL ending in `/` is stored as
  `index.html` in that directory. A query string is kept as part of the file
  name after `?` (with `/` stored as `%2F`). `http` and `https` share the
  tree. There is no index and no database; `du` and `find` are the tools.
  `fetcher path URL` prints the file for a URL.
- **Pruning.** Never automatic. Delete by path or prefix with `rm`.
- **Part files.** `*.part-<pid>` files left by a crash are removed at start.
- **One cache per worker** is the intended deployment. The duplicate-download
  problem is a per-worker problem: one worker running N jobs hits a host N
  times. Workers that each fetch once are N workers' worth of load, which
  hosts have always carried.

## Building

    day10 build .                       # or: dune build
    day10 build --with-test . @runtest  # or: dune test

The end-to-end tests start a mock origin and a cache on loopback ports and
need `curl` on `PATH`.

## URL mapping rules

- The scheme must be `http` or `https`.
- The host may carry a port. Hosts are stored as given, not lowercased.
- Empty path segments are dropped (`//` collapses to `/`). Segments `.` and
  `..` are rejected with 400, as are control characters.
- Percent-encoding is preserved as given; what the client asked for is what
  is on disk.
