(** Mapping between client request paths, upstream URLs and on-disk files.

    A client asks the cache for [/<scheme>/<host>/<path>?<query>]. The cache
    fetches [<scheme>://<host>/<path>?<query>] from upstream and stores the
    bytes at [<root>/<host>/<path>] (with [?<query>] appended to the file
    name, and [index.html] standing in for a trailing slash). *)

type t = {
  scheme : string;  (** ["http"] or ["https"]. *)
  host : string;  (** Host, optionally with a [:port] suffix. *)
  segments : string list;
      (** Path segments as the client sent them, with empty segments
          dropped. *)
  trailing_slash : bool;  (** The upstream path ended in a slash. *)
  query : string option;  (** The raw query string, without the [?]. *)
}

val of_request_path : string -> (t, string) result
(** [of_request_path target] parses the request target of an HTTP request made
    to the cache, for example ["/https/deb.debian.org/debian/dists/trixie/InRelease"].
    It rejects schemes other than [http] and [https], an empty host, any
    segment equal to [.] or [..], and control characters. *)

val of_url : string -> (t, string) result
(** [of_url url] parses an upstream URL such as
    ["https://deb.debian.org/debian/dists/trixie/InRelease"]. Any fragment is
    dropped. The same validation as {!of_request_path} applies. *)

val upstream_url : t -> string
(** The URL to fetch from upstream. *)

val request_path : t -> string
(** The request target a client should send to the cache for this file. *)

val relative_file : t -> string
(** The file's path relative to the cache root, using [/] as the separator:
    [<host>/<segments...>], with [index.html] appended when the upstream path
    ends in a slash or is empty, and [?<query>] appended to the file name when
    a query is present ([/] inside the query is stored as [%2F]). *)
