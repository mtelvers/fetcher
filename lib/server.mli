(** The HTTP front end: request parsing, hit serving with [Range] and [HEAD],
    error mapping and the per-request log line. *)

val src : Logs.Src.t
(** The log source of the per-request lines. *)

type config = {
  store : Store.t;
  max_connections : int;
}

val handler : config -> Cohttp_eio.Server.t
(** A cohttp-eio server that serves the cache. [GET /] answers [200] with a
    one-line banner for health checks; every other path must be
    [/<scheme>/<host>/<path>]. *)

val serve : config -> _ Eio.Net.listening_socket -> unit
(** [serve config socket] accepts connections on [socket] forever. *)

val run :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  config ->
  Eio.Net.Sockaddr.stream ->
  unit
(** [run ~sw ~net config addr] listens on [addr] and calls {!serve}. *)

val http_date : float -> string
(** A time in seconds since the epoch, as an RFC 7231 IMF-fixdate. *)
