(lang dune 3.0)
(name fetcher)
(generate_opam_files true)

(source (github mtelvers/fetcher))
(license ISC)
(authors "Mark Elvers <mark.elvers@tunbury.org>")
(maintainers "Mark Elvers <mark.elvers@tunbury.org>")

(package
 (name fetcher)
 (synopsis "Caching HTTP fetcher: a frozen, coalescing, URL-tree download cache")
 (description
  "fetcher is a small HTTP service that stores every file it downloads in a
plain directory tree named after the file's URL, fetches each URL from
upstream at most once however many clients ask for it at the same time, and
never refreshes or expires a file unless an operator deletes it. Clients are
pointed at it by rewriting URLs to http://cache/<scheme>/<host>/<path>, so
https upstreams are served without any proxy or certificate configuration.")
 (depends
  (ocaml (>= 5.1))
  (eio (>= 1.0))
  (eio_main (>= 1.0))
  (cohttp-eio (>= 6.0.0))
  (http (>= 6.0.0))
  uri
  (cmdliner (>= 1.3.0))
  (logs (>= 0.7.0))
  (fmt (>= 0.9.0))
  cstruct
  optint
  (alcotest (and (>= 1.7.0) :with-test))))
