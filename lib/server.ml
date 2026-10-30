let src = Logs.Src.create "fetcher" ~doc:"fetcher request log"

module Log = (val Logs.src_log src : Logs.LOG)

type config = { store : Store.t; max_connections : int }

let days = [| "Sun"; "Mon"; "Tue"; "Wed"; "Thu"; "Fri"; "Sat" |]

let months =
  [| "Jan"; "Feb"; "Mar"; "Apr"; "May"; "Jun"; "Jul"; "Aug"; "Sep"; "Oct"; "Nov"; "Dec" |]

let http_date t =
  let tm = Unix.gmtime t in
  Printf.sprintf "%s, %02d %s %04d %02d:%02d:%02d GMT" days.(tm.tm_wday) tm.tm_mday
    months.(tm.tm_mon) (tm.tm_year + 1900) tm.tm_hour tm.tm_min tm.tm_sec

(* A flow that reads [length] bytes of a file starting at [offset]. *)
module File_slice = struct
  type t = { fd : Eio.File.ro_ty Eio.Resource.t; mutable offset : int; mutable remaining : int }

  let single_read t buf =
    if t.remaining = 0 then raise End_of_file;
    let buf = Cstruct.sub buf 0 (min (Cstruct.length buf) t.remaining) in
    let n = Eio.File.pread t.fd ~file_offset:(Optint.Int63.of_int t.offset) [ buf ] in
    t.offset <- t.offset + n;
    t.remaining <- t.remaining - n;
    n

  let read_methods = []
end

let file_slice =
  let ops = Eio.Flow.Pi.source (module File_slice) in
  fun fd ~offset ~length -> Eio.Resource.T ({ File_slice.fd; offset; remaining = length }, ops)

let outcome_name = function `Hit -> "hit" | `Miss -> "miss" | `Wait -> "wait" | `Fail -> "fail"

let status_code (s : Http.Status.t) = Http.Status.to_int s

let text_response ~status body =
  let headers = Http.Header.of_list [ ("content-type", "text/plain; charset=utf-8") ] in
  Cohttp_eio.Server.respond_string ~headers ~status ~body ()

let error_response (err : Store.error) =
  let body = Fmt.str "%a\n" Store.pp_error err in
  match err with
  | Upstream_status code when code < 500 -> (text_response ~status:(`Code code) body, code)
  | Upstream_status _ | Upstream_failed _ -> (text_response ~status:`Bad_gateway body, 502)
  | Disk_full _ -> (text_response ~status:`Insufficient_storage body, 507)
  | Internal _ -> (text_response ~status:`Internal_server_error body, 500)

(* Serve a complete file from the tree, honouring HEAD and a single Range. *)
let serve_file ~outcome ~meth ~range path writer =
  Eio.Switch.run @@ fun sw ->
  let fd = Eio.Path.open_in ~sw path in
  let stat = Eio.File.stat fd in
  let size = Optint.Int63.to_int stat.size in
  let base_headers =
    Http.Header.of_list
      [
        ("accept-ranges", "bytes");
        ("last-modified", http_date stat.mtime);
        ("content-type", "application/octet-stream");
        ("x-cache", String.uppercase_ascii (outcome_name outcome));
      ]
  in
  let respond ~status ~headers ~offset ~length =
    let headers = Http.Header.add headers "content-length" (string_of_int length) in
    let body =
      if meth = `HEAD then Cohttp_eio.Body.of_string "" else file_slice fd ~offset ~length
    in
    Cohttp_eio.Server.respond ~headers ~status ~body () writer;
    (status_code status, if meth = `HEAD then 0 else length)
  in
  match Option.map (Range.parse ~size) range with
  | Some (`Range r) ->
      let headers =
        Http.Header.add base_headers "content-range"
          (Printf.sprintf "bytes %d-%d/%d" r.first r.last size)
      in
      respond ~status:`Partial_content ~headers ~offset:r.first ~length:(Range.length r)
  | Some `Unsatisfiable ->
      let headers =
        Http.Header.add base_headers "content-range" (Printf.sprintf "bytes */%d" size)
      in
      Cohttp_eio.Server.respond_string ~headers ~status:`Requested_range_not_satisfiable
        ~body:"" () writer;
      (416, 0)
  | Some `Ignore | None -> respond ~status:`OK ~headers:base_headers ~offset:0 ~length:size

let handle config _conn (request : Http.Request.t) _body writer =
  let start = Unix.gettimeofday () in
  let meth = Http.Request.meth request in
  let target = Http.Request.resource request in
  let log ~outcome ~status ~bytes =
    let ms = int_of_float ((Unix.gettimeofday () -. start) *. 1000.) in
    Log.app (fun m ->
        m "%s %s %s %d %d %dms" (outcome_name outcome) (Http.Method.to_string meth) target status
          bytes ms)
  in
  match meth with
  | (`GET | `HEAD) when target = "/" ->
      text_response ~status:`OK "fetcher: caching HTTP fetcher. Request /<scheme>/<host>/<path>.\n"
        writer
  | `GET | `HEAD -> (
      match Cache_path.of_request_path target with
      | Error msg ->
          text_response ~status:`Bad_request (msg ^ "\n") writer;
          log ~outcome:`Fail ~status:400 ~bytes:0
      | Ok key -> (
          match Store.ensure config.store key with
          | outcome, Ok () ->
              let range = Http.Header.get (Http.Request.headers request) "range" in
              let status, bytes =
                serve_file ~outcome ~meth ~range (Store.file config.store key) writer
              in
              log ~outcome ~status ~bytes
          | _, Error err ->
              let respond, status = error_response err in
              Log.warn (fun m -> m "%s: %a" (Cache_path.upstream_url key) Store.pp_error err);
              respond writer;
              log ~outcome:`Fail ~status ~bytes:0))
  | _ ->
      let headers = Http.Header.of_list [ ("allow", "GET, HEAD") ] in
      Cohttp_eio.Server.respond_string ~headers ~status:`Method_not_allowed
        ~body:"only GET and HEAD are supported\n" () writer;
      log ~outcome:`Fail ~status:405 ~bytes:0

let handler config = Cohttp_eio.Server.make ~callback:(handle config) ()

let serve config socket =
  Cohttp_eio.Server.run ~max_connections:config.max_connections
    ~on_error:(fun exn -> Log.warn (fun m -> m "connection error: %a" Fmt.exn exn))
    socket (handler config)

let run ~sw ~net config addr =
  let socket = Eio.Net.listen ~sw ~backlog:128 ~reuse_addr:true net addr in
  Log.info (fun m -> m "listening on %a" Eio.Net.Sockaddr.pp addr);
  serve config socket
