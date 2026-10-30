open Cmdliner

let version = "%%VERSION%%"

(* One line per event: ISO-8601 UTC timestamp, level, message. *)
let reporter () =
  let report src level ~over k msgf =
    let k _ =
      over ();
      k ()
    in
    let t = Unix.gettimeofday () in
    let tm = Unix.gmtime t in
    let stamp =
      Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (tm.tm_year + 1900) (tm.tm_mon + 1)
        tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec
    in
    let level_str =
      match level with
      | Logs.App -> ""
      | Error -> " error"
      | Warning -> " warning"
      | Info -> " info"
      | Debug -> " debug"
    in
    let src_str = if Logs.Src.equal src Fetcher.Server.src then "" else " " ^ Logs.Src.name src in
    msgf @@ fun ?header:_ ?tags:_ fmt ->
    Format.kfprintf k Format.std_formatter ("%s%s%s: " ^^ fmt ^^ "@.") stamp level_str src_str
  in
  { Logs.report }

let setup_logs level =
  Logs.set_reporter (reporter ());
  Logs.set_level ~all:true (Some Logs.Warning);
  List.iter
    (fun src ->
      if String.starts_with ~prefix:"fetcher" (Logs.Src.name src) then Logs.Src.set_level src level)
    (Logs.Src.list ())

let resolve_listen net listen =
  let host, service =
    match String.rindex_opt listen ':' with
    | Some i when not (String.ends_with ~suffix:"]" listen) ->
        (String.sub listen 0 i, String.sub listen (i + 1) (String.length listen - i - 1))
    | _ -> (listen, "8080")
  in
  let host =
    if String.length host >= 2 && host.[0] = '[' then String.sub host 1 (String.length host - 2)
    else host
  in
  match Eio.Net.getaddrinfo_stream ~service net host with
  | (`Tcp _ as addr) :: _ -> Ok addr
  | _ -> Error (Printf.sprintf "cannot resolve listen address %S" listen)

let serve root listen retries connect_timeout stall_timeout curl max_connections level =
  setup_logs level;
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let store =
    Fetcher.Store.create ~sw ~fs:(Eio.Stdenv.fs env) ~proc_mgr:(Eio.Stdenv.process_mgr env)
      ~clock:(Eio.Stdenv.clock env) ~root ~curl ~retries ~connect_timeout ~stall_timeout
      ~user_agent:("fetcher/" ^ version) ()
  in
  let removed = Fetcher.Store.clean_part_files store in
  if removed > 0 then Logs.info (fun m -> m "removed %d stale part file(s)" removed);
  match resolve_listen (Eio.Stdenv.net env) listen with
  | Error msg -> `Error (false, msg)
  | Ok addr ->
      Fetcher.Server.run ~sw ~net:(Eio.Stdenv.net env)
        { Fetcher.Server.store; max_connections }
        addr;
      `Ok ()

let print_url cache url =
  match Fetcher.Cache_path.of_url url with
  | Error msg -> `Error (false, msg)
  | Ok key ->
      print_endline (Fetcher.Client.cache_url ~cache key);
      `Ok ()

let print_path root url =
  match Fetcher.Cache_path.of_url url with
  | Error msg -> `Error (false, msg)
  | Ok key ->
      print_endline (Filename.concat root (Fetcher.Cache_path.relative_file key));
      `Ok ()

let download cache url out =
  Eio_main.run @@ fun env ->
  let dest =
    match out with
    | "-" -> `Sink (Eio.Stdenv.stdout env :> Eio.Flow.sink_ty Eio.Resource.t)
    | "" -> (
        match Fetcher.Cache_path.of_url url with
        | Ok key -> `File (Filename.basename (Fetcher.Cache_path.relative_file key))
        | Error _ -> `File "index.html")
    | path -> `File path
  in
  match
    Fetcher.Client.download ~net:(Eio.Stdenv.net env) ~fs:(Eio.Stdenv.fs env) ~cache ~url ~dest
  with
  | Ok () -> `Ok ()
  | Error err ->
      (* A download tool exits 1 on failure, not with cmdliner's usage code. *)
      Fmt.epr "fetcher: %a@." Fetcher.Client.pp_error err;
      exit 1

let root_arg =
  Arg.(
    value
    & opt string "/var/cache/fetcher"
    & info [ "r"; "root" ] ~docv:"DIR" ~env:(Cmd.Env.info "FETCHER_ROOT")
        ~doc:"Directory holding the cache tree, laid out as \\$(i,DIR)/<host>/<path>.")

let level_arg =
  let levels =
    [ ("error", Some Logs.Error); ("warning", Some Logs.Warning); ("info", Some Logs.Info);
      ("debug", Some Logs.Debug); ("quiet", None) ]
  in
  Arg.(
    value
    & opt (enum levels) (Some Logs.Info)
    & info [ "log-level" ] ~docv:"LEVEL"
        ~doc:"Verbosity of fetcher's own messages: quiet, error, warning, info or debug. The \
              per-request log line is always printed unless quiet.")

let serve_cmd =
  let listen =
    Arg.(
      value
      & opt string "127.0.0.1:8080"
      & info [ "l"; "listen" ] ~docv:"HOST:PORT" ~env:(Cmd.Env.info "FETCHER_LISTEN")
          ~doc:"Address to listen on. Containers that must reach the cache need an address \
                routable from them, such as the docker bridge address.")
  in
  let retries =
    Arg.(
      value & opt int 3
      & info [ "retries" ] ~docv:"N"
          ~doc:"Upstream attempts before a 5xx, connection or transfer failure is reported to \
                the client. 4xx answers are never retried.")
  in
  let connect_timeout =
    Arg.(
      value & opt int 30
      & info [ "connect-timeout" ] ~docv:"SECONDS" ~doc:"Time allowed to connect to upstream.")
  in
  let stall_timeout =
    Arg.(
      value & opt int 60
      & info [ "stall-timeout" ] ~docv:"SECONDS"
          ~doc:"A transfer that makes no progress for this long is abandoned and retried.")
  in
  let curl =
    Arg.(
      value & opt string "curl"
      & info [ "curl" ] ~docv:"PATH" ~doc:"The curl executable used for upstream fetches.")
  in
  let max_connections =
    Arg.(
      value & opt int 1024
      & info [ "max-connections" ] ~docv:"N" ~doc:"Maximum simultaneous client connections.")
  in
  let doc = "run the caching fetcher" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Serves $(b,GET) and $(b,HEAD) requests for $(i,/<scheme>/<host>/<path>) from \
         $(i,ROOT/<host>/<path>), fetching $(i,<scheme>://<host>/<path>) with curl when the \
         file is absent. Concurrent requests for an absent file share one upstream fetch. \
         Files are never refreshed or expired; delete a file from the tree to fetch it again.";
      `P
        "One line is logged per request: outcome (hit, miss, wait or fail), method, path, \
         status, bytes sent and elapsed milliseconds.";
    ]
  in
  Cmd.v
    (Cmd.info "serve" ~doc ~man)
    Term.(
      ret
        (const serve $ root_arg $ listen $ retries $ connect_timeout $ stall_timeout $ curl
       $ max_connections $ level_arg))

let url_arg = Arg.(required & pos 0 (some string) None & info [] ~docv:"URL")

let cache_arg =
  Arg.(
    value
    & opt string "127.0.0.1:8080"
    & info [ "c"; "cache" ] ~docv:"HOST[:PORT]" ~env:(Cmd.Env.info "FETCHER_CACHE")
        ~doc:"The running cache, as $(i,HOST), $(i,HOST:PORT) or a full $(i,http://) URL. \
              The port defaults to 8080.")

let download_cmd =
  let out =
    Arg.(
      value & opt string ""
      & info [ "o"; "output" ] ~docv:"FILE"
          ~doc:"Write to $(docv) instead of the URL's base name in the current directory. \
                $(b,-) writes to standard output.")
  in
  let doc = "download a URL through the cache" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Fetches $(i,URL) from the cache, which serves it from its tree or fetches it from \
         upstream once. The file is written beside its final name and renamed into place, so \
         a failed download leaves nothing behind. Exits with a non-zero status and the cache's \
         reason on standard error if the file could not be fetched.";
      `S Manpage.s_examples;
      `P "As opam's download command:";
      `Pre
        "  opam option download-command='[\"fetcher\" \"download\" \"--cache\" \
         \"10.0.0.1:8080\" \"%{url}%\" \"-o\" \"%{out}%\"]'";
    ]
  in
  Cmd.v (Cmd.info "download" ~doc ~man) Term.(ret (const download $ cache_arg $ url_arg $ out))

let url_cmd =
  let doc = "print the cache URL for an upstream URL" in
  Cmd.v (Cmd.info "url" ~doc) Term.(ret (const print_url $ cache_arg $ url_arg))

let path_cmd =
  let doc = "print the file in the cache tree that holds an upstream URL" in
  Cmd.v (Cmd.info "path" ~doc) Term.(ret (const print_path $ root_arg $ url_arg))

let () =
  let doc = "caching HTTP fetcher with a frozen, browsable URL tree" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "$(mname) downloads files on behalf of HTTP clients and keeps them in a directory \
         tree named after their URLs. Point a client at \
         $(i,http://cache/https/host/path) instead of $(i,https://host/path) and it will \
         be served from the tree, fetched once if absent, and never refreshed.";
      `S Manpage.s_examples;
      `P "Serve a cache from /srv/fetcher on every interface:";
      `Pre "  fetcher serve --root /srv/fetcher --listen 0.0.0.0:8080";
      `P "Download a file through it:";
      `Pre "  fetcher download --cache 10.0.0.1:8080 https://deb.debian.org/debian/dists/trixie/InRelease";
      `P "Find the URL a client that cannot run fetcher should use:";
      `Pre "  fetcher url --cache 10.0.0.1:8080 https://deb.debian.org/debian/dists/trixie/InRelease";
    ]
  in
  let info = Cmd.info "fetcher" ~version ~doc ~man in
  exit (Cmd.eval (Cmd.group info [ serve_cmd; download_cmd; url_cmd; path_cmd ]))
