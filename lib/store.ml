let src = Logs.Src.create "fetcher.store" ~doc:"fetcher on-disk store"

module Log = (val Logs.src_log src : Logs.LOG)

type outcome = [ `Hit | `Miss | `Wait ]

type error =
  | Upstream_status of int
  | Upstream_failed of string
  | Disk_full of string
  | Internal of string

let pp_error ppf = function
  | Upstream_status n -> Fmt.pf ppf "upstream returned HTTP %d" n
  | Upstream_failed msg -> Fmt.pf ppf "upstream fetch failed: %s" msg
  | Disk_full msg -> Fmt.pf ppf "cannot write to cache: %s" msg
  | Internal msg -> Fmt.pf ppf "internal error: %s" msg

type t = {
  sw : Eio.Switch.t;
  root : Eio.Fs.dir_ty Eio.Path.t;
  spawn :
    stdout:Eio.Flow.sink_ty Eio.Resource.t ->
    stderr:Eio.Flow.sink_ty Eio.Resource.t ->
    string list ->
    Eio.Process.exit_status;
  sleep : float -> unit;
  curl : string;
  retries : int;
  connect_timeout : int;
  stall_timeout : int;
  user_agent : string;
  inflight : (string, (unit, error) result Eio.Promise.t) Hashtbl.t;
}

let create ~sw ~fs ~proc_mgr ~clock ~root ?(curl = "curl") ?(retries = 3)
    ?(connect_timeout = 30) ?(stall_timeout = 60) ?(user_agent = "fetcher") () =
  let root = Eio.Path.(fs / root) in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 root;
  let spawn ~stdout ~stderr args =
    Eio.Switch.run @@ fun sw ->
    Eio.Process.await (Eio.Process.spawn ~sw proc_mgr ~stdout ~stderr args)
  in
  {
    sw;
    root;
    spawn;
    sleep = Eio.Time.sleep clock;
    curl;
    retries;
    connect_timeout;
    stall_timeout;
    user_agent;
    inflight = Hashtbl.create 64;
  }

let root t = t.root
let file t key = Eio.Path.(t.root / Cache_path.relative_file key)

let is_part_file name =
  match String.rindex_opt name '.' with
  | Some i ->
      let suffix = String.sub name i (String.length name - i) in
      String.length suffix > 6
      && String.starts_with ~prefix:".part-" suffix
      && String.for_all
           (fun c -> c >= '0' && c <= '9')
           (String.sub suffix 6 (String.length suffix - 6))
  | None -> false

let clean_part_files t =
  let removed = ref 0 in
  let rec walk dir =
    List.iter
      (fun name ->
        let p = Eio.Path.(dir / name) in
        match Eio.Path.kind ~follow:false p with
        | `Directory -> walk p
        | `Regular_file when is_part_file name ->
            Log.info (fun m -> m "removing stale part file %a" Eio.Path.pp p);
            Eio.Path.unlink p;
            incr removed
        | _ -> ())
      (Eio.Path.read_dir dir)
  in
  walk t.root;
  !removed

let exists path =
  match Eio.Path.kind ~follow:true path with `Regular_file -> true | _ -> false

(* curl exit codes, from curl(1). *)
let curl_http_error = 22
let curl_write_error = 23

let describe_curl_exit code stderr =
  let stderr = String.trim stderr in
  if stderr <> "" then stderr else Printf.sprintf "curl exited with code %d" code

type attempt =
  | Done
  | Failed of error  (** Give up now. *)
  | Retry of error  (** May succeed on another attempt. *)

let run_curl t ~url ~part =
  let args =
    [
      t.curl;
      "--silent";
      "--show-error";
      "--fail";
      "--location";
      "--max-redirs";
      "10";
      "--proto";
      "=http,https";
      "--proto-redir";
      "=http,https";
      "--connect-timeout";
      string_of_int t.connect_timeout;
      "--speed-time";
      string_of_int t.stall_timeout;
      "--speed-limit";
      "1";
      "--user-agent";
      t.user_agent;
      "--output";
      part;
      "--write-out";
      "%{http_code}";
      "--";
      url;
    ]
  in
  let stdout = Buffer.create 8 and stderr = Buffer.create 256 in
  let status =
    t.spawn ~stdout:(Eio.Flow.buffer_sink stdout) ~stderr:(Eio.Flow.buffer_sink stderr) args
  in
  let http_code = Buffer.contents stdout |> String.trim |> int_of_string_opt in
  (status, http_code, Buffer.contents stderr)

let attempt t ~url ~part ~final =
  let part_path = Eio.Path.(t.root / part) in
  let remove_part () = try Eio.Path.unlink part_path with _ -> () in
  match run_curl t ~url ~part:(Eio.Path.native_exn part_path) with
  | `Exited 0, _, _ ->
      (* A response with an empty body may leave no file behind. *)
      if not (exists part_path) then Eio.Path.save ~create:(`Or_truncate 0o644) part_path "";
      Eio.Path.rename part_path final;
      Done
  | `Exited code, Some http, stderr when code = curl_http_error && http >= 400 ->
      remove_part ();
      if http < 500 then Failed (Upstream_status http)
      else (
        Log.debug (fun m -> m "%s: HTTP %d (%s)" url http (String.trim stderr));
        Retry (Upstream_status http))
  | `Exited code, _, stderr when code = curl_write_error ->
      remove_part ();
      Failed (Disk_full (describe_curl_exit code stderr))
  | `Exited code, _, stderr ->
      remove_part ();
      Retry (Upstream_failed (describe_curl_exit code stderr))
  | `Signaled n, _, _ ->
      remove_part ();
      Retry (Upstream_failed (Printf.sprintf "curl killed by signal %d" n))

let fetch t key =
  let url = Cache_path.upstream_url key in
  let rel = Cache_path.relative_file key in
  let final = Eio.Path.(t.root / rel) in
  let part = Printf.sprintf "%s.part-%d" rel (Unix.getpid ()) in
  let dir = Filename.dirname rel in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 Eio.Path.(t.root / dir);
  let rec go n =
    match attempt t ~url ~part ~final with
    | Done -> Ok ()
    | Failed e -> Error e
    | Retry e when n >= t.retries -> Error e
    | Retry e ->
        Log.info (fun m -> m "%s: attempt %d/%d failed (%a), retrying" url n t.retries pp_error e);
        t.sleep (float_of_int n);
        go (n + 1)
  in
  go 1

let ensure t key =
  let rel = Cache_path.relative_file key in
  match Hashtbl.find_opt t.inflight rel with
  | Some p -> (`Wait, Eio.Promise.await p)
  | None ->
      (* Register the in-flight fetch before the existence check, so that a
         second request arriving during the check waits instead of racing us
         to upstream. The fetch runs under the store's switch: a client that
         disconnects does not cancel work other clients may be waiting on. *)
      let promise, resolver = Eio.Promise.create () in
      Hashtbl.replace t.inflight rel promise;
      let outcome = ref `Miss in
      Eio.Fiber.fork ~sw:t.sw (fun () ->
          let result =
            Fun.protect
              ~finally:(fun () -> Hashtbl.remove t.inflight rel)
              (fun () ->
                try
                  if exists Eio.Path.(t.root / rel) then (
                    outcome := `Hit;
                    Ok ())
                  else fetch t key
                with
                | Eio.Io _ as exn -> Error (Internal (Printexc.to_string exn))
                | Unix.Unix_error (e, fn, arg) ->
                    Error (Internal (Printf.sprintf "%s %s: %s" fn arg (Unix.error_message e)))
                | exn -> Error (Internal (Printexc.to_string exn)))
          in
          Eio.Promise.resolve resolver result);
      let result = Eio.Promise.await promise in
      (!outcome, result)
