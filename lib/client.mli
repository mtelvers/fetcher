(** Downloading through a running cache: the client side of [fetcher]. *)

type error =
  | Bad_url of string  (** Not an absolute http(s) URL. *)
  | Cannot_connect of string  (** The cache did not answer. *)
  | Status of int * string  (** The cache answered with this status and body. *)
  | Write_failed of string  (** The destination could not be written. *)

val pp_error : error Fmt.t

val cache_base : string -> string
(** [cache_base s] normalises a [--cache] argument: ["localhost:8080"],
    ["10.0.0.1"] or ["http://10.0.0.1:8080/"] all become a base URL without a
    trailing slash. A bare host gets port 8080. *)

val cache_url : cache:string -> Cache_path.t -> string
(** The URL to request from the cache for an upstream file. *)

val download :
  net:_ Eio.Net.t ->
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  cache:string ->
  url:string ->
  dest:[ `File of string | `Sink of Eio.Flow.sink_ty Eio.Resource.t ] ->
  (unit, error) result
(** [download ~net ~fs ~cache ~url ~dest] fetches [url] through the cache at
    [cache] (see {!cache_base}). A file destination is written beside its
    final name and renamed into place on success, so a failed download leaves
    nothing behind. *)
