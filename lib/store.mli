(** The on-disk tree and the single-fetch-per-URL protocol.

    A file at its final path is, by construction, complete: the fetcher writes
    upstream bytes to a [.part-<pid>] file beside the target and renames it
    into place only after curl reports a clean end of body. Concurrent requests
    for the same file share one fetch and all receive its result. *)

type t

type outcome = [ `Hit | `Miss | `Wait ]
(** How a request was satisfied: the file was already there, this request
    performed the upstream fetch, or it waited on a fetch another request had
    started. *)

type error =
  | Upstream_status of int
      (** Upstream answered with this HTTP status (4xx immediately, 5xx after
          the retries were exhausted). *)
  | Upstream_failed of string
      (** No usable upstream response after the retries: connection refused,
          DNS, TLS, timeout, truncated body. *)
  | Disk_full of string  (** The part file could not be written. *)
  | Internal of string  (** Anything else; the message is for the log. *)

val pp_error : error Fmt.t

val create :
  sw:Eio.Switch.t ->
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  proc_mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  root:string ->
  ?curl:string ->
  ?retries:int ->
  ?connect_timeout:int ->
  ?stall_timeout:int ->
  ?user_agent:string ->
  unit ->
  t
(** [create ~sw ~fs ~proc_mgr ~clock ~root ()] opens the tree at [root],
    creating it if needed. Fetches run in fibers attached to [sw], so a client
    going away never cancels a fetch other clients may be waiting on.

    @param curl The curl executable (default ["curl"]).
    @param retries Upstream attempts for retryable failures (default 3).
    @param connect_timeout Seconds curl waits for a connection (default 30).
    @param stall_timeout Seconds without progress before a transfer is
      abandoned (default 60). *)

val clean_part_files : t -> int
(** Remove leftover [.part-*] files from an earlier run and return how many
    were removed. Call once at start, before serving. *)

val ensure : t -> Cache_path.t -> outcome * (unit, error) result
(** [ensure t key] makes sure the file for [key] is in the tree, fetching it
    once if necessary, and reports how the request was satisfied. *)

val file : t -> Cache_path.t -> Eio.Fs.dir_ty Eio.Path.t
(** The file's location in the tree. *)

val root : t -> Eio.Fs.dir_ty Eio.Path.t
