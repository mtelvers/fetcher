open Fetcher

(* ---- Cache_path ---------------------------------------------------------- *)

let key = Alcotest.testable (fun ppf k -> Fmt.string ppf (Cache_path.upstream_url k)) ( = )
let ok = function Ok v -> v | Error e -> Alcotest.failf "unexpected error: %s" e

let check_mapping ~target ~url ~file () =
  let k = ok (Cache_path.of_request_path target) in
  Alcotest.(check string) "upstream url" url (Cache_path.upstream_url k);
  Alcotest.(check string) "relative file" file (Cache_path.relative_file k);
  Alcotest.(check string) "request path round trip" target (Cache_path.request_path k);
  Alcotest.(check key) "of_url agrees" k (ok (Cache_path.of_url url))

let test_plain =
  check_mapping ~target:"/https/deb.debian.org/debian/dists/trixie/InRelease"
    ~url:"https://deb.debian.org/debian/dists/trixie/InRelease"
    ~file:"deb.debian.org/debian/dists/trixie/InRelease"

let test_http_with_port =
  check_mapping ~target:"/http/127.0.0.1:8000/a/b.tar.gz" ~url:"http://127.0.0.1:8000/a/b.tar.gz"
    ~file:"127.0.0.1:8000/a/b.tar.gz"

let test_trailing_slash =
  check_mapping ~target:"/https/example.com/dir/" ~url:"https://example.com/dir/"
    ~file:"example.com/dir/index.html"

let test_host_only =
  check_mapping ~target:"/https/example.com/" ~url:"https://example.com/"
    ~file:"example.com/index.html"

let test_query =
  check_mapping ~target:"/https/example.com/file?a=1&b=/x" ~url:"https://example.com/file?a=1&b=/x"
    ~file:"example.com/file?a=1&b=%2Fx"

let test_collapse_slashes () =
  let k = ok (Cache_path.of_request_path "/https//example.com//a///b") in
  Alcotest.(check string) "upstream" "https://example.com/a/b" (Cache_path.upstream_url k);
  Alcotest.(check string) "file" "example.com/a/b" (Cache_path.relative_file k)

let test_host_only_no_slash () =
  let k = ok (Cache_path.of_request_path "/https/example.com") in
  Alcotest.(check string) "upstream" "https://example.com/" (Cache_path.upstream_url k);
  Alcotest.(check string) "file" "example.com/index.html" (Cache_path.relative_file k)

let test_fragment_dropped () =
  let k = ok (Cache_path.of_url "https://example.com/a#frag") in
  Alcotest.(check string) "upstream" "https://example.com/a" (Cache_path.upstream_url k)

let rejects target () =
  match Cache_path.of_request_path target with
  | Ok k -> Alcotest.failf "accepted %S as %s" target (Cache_path.upstream_url k)
  | Error _ -> ()

let test_rejects_url () =
  List.iter
    (fun u ->
      match Cache_path.of_url u with
      | Ok _ -> Alcotest.failf "accepted URL %S" u
      | Error _ -> ())
    [ "ftp://example.com/x"; "example.com/x"; "https://user@example.com/x"; "https:///x" ]

let cache_path_tests =
  [
    Alcotest.test_case "plain https" `Quick test_plain;
    Alcotest.test_case "http with port" `Quick test_http_with_port;
    Alcotest.test_case "trailing slash" `Quick test_trailing_slash;
    Alcotest.test_case "host only" `Quick test_host_only;
    Alcotest.test_case "host only, no slash" `Quick test_host_only_no_slash;
    Alcotest.test_case "query string" `Quick test_query;
    Alcotest.test_case "collapse //" `Quick test_collapse_slashes;
    Alcotest.test_case "fragment dropped" `Quick test_fragment_dropped;
    Alcotest.test_case "reject .." `Quick (rejects "/https/example.com/a/../b");
    Alcotest.test_case "reject ." `Quick (rejects "/https/example.com/./b");
    Alcotest.test_case "reject .. host" `Quick (rejects "/https/../b");
    Alcotest.test_case "reject scheme" `Quick (rejects "/ftp/example.com/b");
    Alcotest.test_case "reject bad host" `Quick (rejects "/https/exa mple.com/b");
    Alcotest.test_case "reject short" `Quick (rejects "/https");
    Alcotest.test_case "reject control" `Quick (rejects "/https/example.com/a\nb");
    Alcotest.test_case "reject URLs" `Quick test_rejects_url;
  ]

(* ---- Range --------------------------------------------------------------- *)

let range =
  let pp ppf = function
    | `Range r -> Fmt.pf ppf "%d-%d" r.Range.first r.last
    | `Unsatisfiable -> Fmt.string ppf "unsatisfiable"
    | `Ignore -> Fmt.string ppf "ignore"
  in
  Alcotest.testable pp ( = )

let check_range header expected () =
  Alcotest.check range header expected (Range.parse ~size:100 header)

let range_tests =
  [
    Alcotest.test_case "closed" `Quick (check_range "bytes=0-9" (`Range { first = 0; last = 9 }));
    Alcotest.test_case "open end" `Quick (check_range "bytes=90-" (`Range { first = 90; last = 99 }));
    Alcotest.test_case "clamped" `Quick (check_range "bytes=90-500" (`Range { first = 90; last = 99 }));
    Alcotest.test_case "suffix" `Quick (check_range "bytes=-10" (`Range { first = 90; last = 99 }));
    Alcotest.test_case "suffix too big" `Quick (check_range "bytes=-500" (`Range { first = 0; last = 99 }));
    Alcotest.test_case "past end" `Quick (check_range "bytes=100-" `Unsatisfiable);
    Alcotest.test_case "suffix zero" `Quick (check_range "bytes=-0" `Unsatisfiable);
    Alcotest.test_case "multi" `Quick (check_range "bytes=0-1,5-6" `Ignore);
    Alcotest.test_case "inverted" `Quick (check_range "bytes=5-1" `Ignore);
    Alcotest.test_case "other unit" `Quick (check_range "items=0-1" `Ignore);
    Alcotest.test_case "garbage" `Quick (check_range "bytes=a-b" `Ignore);
  ]

(* ---- End to end ---------------------------------------------------------- *)

type behaviour =
  | Serve of string * float  (** body and a delay before answering *)
  | Status of int
  | Truncate of string * int  (** body sent, length claimed *)

type upstream = { mutable requests : string list; behaviour : string -> behaviour }

let http_response ~status ~length body =
  Printf.sprintf "HTTP/1.1 %d %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" status
    (if status = 200 then "OK" else "Error")
    length body

(* A minimal HTTP/1.1 origin on an ephemeral loopback port, driven by a
   behaviour table, that records every request path it receives. *)
let start_upstream ~sw ~net ~clock up =
  let sock =
    Eio.Net.listen ~sw ~backlog:64 ~reuse_addr:true net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = match Eio.Net.listening_addr sock with `Tcp (_, p) -> p | _ -> assert false in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Eio.Net.run_server sock
        ~on_error:(fun _ -> ())
        (fun flow _ ->
          let r = Eio.Buf_read.of_flow ~max_size:65536 flow in
          let request_line = Eio.Buf_read.line r in
          let rec skip_headers () = if Eio.Buf_read.line r <> "" then skip_headers () in
          skip_headers ();
          let path =
            match String.split_on_char ' ' request_line with _ :: p :: _ -> p | _ -> request_line
          in
          up.requests <- path :: up.requests;
          match up.behaviour path with
          | Serve (body, delay) ->
              Eio.Time.sleep clock delay;
              Eio.Flow.copy_string (http_response ~status:200 ~length:(String.length body) body) flow
          | Status n -> Eio.Flow.copy_string (http_response ~status:n ~length:0 "") flow
          | Truncate (body, claimed) ->
              Eio.Flow.copy_string (http_response ~status:200 ~length:claimed body) flow));
  port

type ctx = {
  client : Cohttp_eio.Client.t;
  base : string;  (** The cache's base URL. *)
  upstream_host : string;  (** [127.0.0.1:<port>] of the mock origin. *)
  up : upstream;
  root : Eio.Fs.dir_ty Eio.Path.t;
  net : [`Generic] Eio.Net.ty Eio.Resource.t;
}

let counter = ref 0

let with_setup ?(retries = 1) behaviour f () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env in
  incr counter;
  let root_name =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "fetcher-test-%d-%d" (Unix.getpid ()) !counter)
  in
  let root = Eio.Path.(Eio.Stdenv.fs env / root_name) in
  (try Eio.Path.rmtree root with _ -> ());
  Fun.protect ~finally:(fun () -> try Eio.Path.rmtree root with _ -> ())
  @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let up = { requests = []; behaviour } in
  let up_port = start_upstream ~sw ~net ~clock up in
  let store =
    Store.create ~sw ~fs:(Eio.Stdenv.fs env) ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock
      ~root:root_name ~retries ()
  in
  let sock =
    Eio.Net.listen ~sw ~backlog:64 ~reuse_addr:true net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = match Eio.Net.listening_addr sock with `Tcp (_, p) -> p | _ -> assert false in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Server.serve { Server.store; max_connections = 100 } sock;
      `Stop_daemon);
  let client = Cohttp_eio.Client.make ~https:None net in
  f
    {
      client;
      base = Printf.sprintf "http://127.0.0.1:%d" port;
      upstream_host = Printf.sprintf "127.0.0.1:%d" up_port;
      up;
      root;
      net = (net :> [`Generic] Eio.Net.ty Eio.Resource.t);
    }

(* cohttp's client does not know that a HEAD response has no body, so HEAD
   requests are made by hand over a raw socket. *)
let raw_request ctx ~net ~meth path =
  Eio.Switch.run @@ fun sw ->
  let port =
    match String.rindex_opt ctx.base ':' with
    | Some i -> int_of_string (String.sub ctx.base (i + 1) (String.length ctx.base - i - 1))
    | None -> assert false
  in
  let flow = Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) in
  Eio.Flow.copy_string
    (Printf.sprintf "%s %s HTTP/1.1\r\nHost: cache\r\nConnection: close\r\n\r\n" meth path)
    flow;
  let r = Eio.Buf_read.of_flow ~max_size:1_000_000 flow in
  let status_line = Eio.Buf_read.line r in
  let status =
    match String.split_on_char ' ' status_line with _ :: s :: _ -> int_of_string s | _ -> -1
  in
  let rec headers acc =
    match Eio.Buf_read.line r with
    | "" -> acc
    | l -> (
        match String.index_opt l ':' with
        | Some i ->
            headers
              ((String.lowercase_ascii (String.sub l 0 i),
                 String.trim (String.sub l (i + 1) (String.length l - i - 1)))
              :: acc)
        | None -> headers acc)
  in
  let h = Http.Header.of_list (headers []) in
  let body = Eio.Buf_read.take_all r in
  (status, h, body)

let request ?(headers = []) ?(meth = `GET) ctx path =
  Eio.Switch.run @@ fun sw ->
  let headers = Http.Header.of_list headers in
  let resp, body =
    Cohttp_eio.Client.call ctx.client ~sw ~headers meth (Uri.of_string (ctx.base ^ path))
  in
  let body = Eio.Buf_read.(parse_exn take_all) body ~max_size:max_int in
  (Http.Response.status resp |> Http.Status.to_int, Http.Response.headers resp, body)

let contains s sub =
  let n = String.length s and m = String.length sub in
  let rec go i = i + m <= n && (String.sub s i m = sub || go (i + 1)) in
  go 0

let cache_path ctx file = Printf.sprintf "/http/%s/%s" ctx.upstream_host file
let body_of n = String.init n (fun i -> Char.chr (i mod 251))
let header h name = Option.value ~default:"<none>" (Http.Header.get h name)

let test_miss_then_hit =
  with_setup (fun _ -> Serve (body_of 10_000, 0.)) @@ fun ctx ->
  let status, h, body = request ctx (cache_path ctx "pool/a.deb") in
  Alcotest.(check int) "status" 200 status;
  Alcotest.(check string) "x-cache" "MISS" (header h "x-cache");
  Alcotest.(check string) "body" (body_of 10_000) body;
  Alcotest.(check string) "content-length" "10000" (header h "content-length");
  let status, h, body = request ctx (cache_path ctx "pool/a.deb") in
  Alcotest.(check int) "status" 200 status;
  Alcotest.(check string) "x-cache" "HIT" (header h "x-cache");
  Alcotest.(check string) "body" (body_of 10_000) body;
  Alcotest.(check int) "one upstream request" 1 (List.length ctx.up.requests);
  Alcotest.(check (list string)) "upstream path" [ "/pool/a.deb" ] ctx.up.requests;
  let on_disk = Eio.Path.load Eio.Path.(ctx.root / ctx.upstream_host / "pool" / "a.deb") in
  Alcotest.(check string) "file in tree" (body_of 10_000) on_disk

let test_coalescing =
  with_setup (fun _ -> Serve (body_of 50_000, 0.5)) @@ fun ctx ->
  let results =
    Eio.Fiber.List.map
      (fun _ -> request ctx (cache_path ctx "big.tar.gz"))
      (List.init 20 Fun.id)
  in
  List.iter
    (fun (status, _, body) ->
      Alcotest.(check int) "status" 200 status;
      Alcotest.(check string) "body" (body_of 50_000) body)
    results;
  let outcomes = List.map (fun (_, h, _) -> header h "x-cache") results in
  Alcotest.(check int) "one miss" 1 (List.length (List.filter (( = ) "MISS") outcomes));
  Alcotest.(check int) "rest waited" 19 (List.length (List.filter (( = ) "WAIT") outcomes));
  Alcotest.(check int) "one upstream request" 1 (List.length ctx.up.requests)

let test_head_and_range =
  with_setup (fun _ -> Serve (body_of 1000, 0.)) @@ fun ctx ->
  let path = cache_path ctx "f.bin" in
  let status, h, body = raw_request ctx ~net:ctx.net ~meth:"HEAD" path in
  Alcotest.(check int) "HEAD status" 200 status;
  Alcotest.(check string) "HEAD length" "1000" (header h "content-length");
  Alcotest.(check string) "HEAD body" "" body;
  Alcotest.(check string) "accept-ranges" "bytes" (header h "accept-ranges");
  let status, h, body = request ~headers:[ ("range", "bytes=10-19") ] ctx path in
  Alcotest.(check int) "range status" 206 status;
  Alcotest.(check string) "content-range" "bytes 10-19/1000" (header h "content-range");
  Alcotest.(check string) "range body" (String.sub (body_of 1000) 10 10) body;
  let status, h, body = request ~headers:[ ("range", "bytes=990-") ] ctx path in
  Alcotest.(check int) "open range status" 206 status;
  Alcotest.(check string) "open range body" (String.sub (body_of 1000) 990 10) body;
  Alcotest.(check string) "open content-range" "bytes 990-999/1000" (header h "content-range");
  let status, h, _ = request ~headers:[ ("range", "bytes=5000-") ] ctx path in
  Alcotest.(check int) "unsatisfiable" 416 status;
  Alcotest.(check string) "unsatisfiable content-range" "bytes */1000" (header h "content-range");
  Alcotest.(check int) "one upstream request" 1 (List.length ctx.up.requests)

let test_upstream_404 =
  with_setup (fun _ -> Status 404) @@ fun ctx ->
  let status, _, _ = request ctx (cache_path ctx "missing") in
  Alcotest.(check int) "status passed through" 404 status;
  Alcotest.(check int) "one upstream request, no retry" 1 (List.length ctx.up.requests);
  Alcotest.(check bool) "nothing stored" false
    (Eio.Path.is_file Eio.Path.(ctx.root / ctx.upstream_host / "missing"))

let test_upstream_503 =
  with_setup ~retries:2 (fun _ -> Status 503) @@ fun ctx ->
  let status, _, body = request ctx (cache_path ctx "flaky") in
  Alcotest.(check int) "502" 502 status;
  Alcotest.(check bool) "body names upstream status" true
    (contains body "503");
  Alcotest.(check int) "retried" 2 (List.length ctx.up.requests)

let test_truncated =
  with_setup (fun _ -> Truncate (body_of 100, 5000)) @@ fun ctx ->
  let status, _, _ = request ctx (cache_path ctx "cut.bin") in
  Alcotest.(check int) "502" 502 status;
  Alcotest.(check bool) "nothing stored" false
    (Eio.Path.is_file Eio.Path.(ctx.root / ctx.upstream_host / "cut.bin"));
  let leftovers =
    match Eio.Path.read_dir Eio.Path.(ctx.root / ctx.upstream_host) with
    | l -> l
    | exception _ -> []
  in
  Alcotest.(check (list string)) "no part files" [] leftovers

let test_bad_requests =
  with_setup (fun _ -> Status 500) @@ fun ctx ->
  let status, _, _ = request ctx "/" in
  Alcotest.(check int) "banner" 200 status;
  let status, _, _ = request ctx "/ftp/example.com/x" in
  Alcotest.(check int) "bad scheme" 400 status;
  let status, _, _ = request ctx "/https/example.com/../x" in
  Alcotest.(check int) "dot dot" 400 status;
  let status, _, _ = request ctx "/https" in
  Alcotest.(check int) "too short" 400 status;
  let status, _, _ = request ~meth:`POST ctx (cache_path ctx "x") in
  Alcotest.(check int) "method" 405 status;
  Alcotest.(check int) "upstream untouched" 0 (List.length ctx.up.requests)

let test_delete_refetches =
  with_setup (fun _ -> Serve ("v1", 0.)) @@ fun ctx ->
  let _, _, body = request ctx (cache_path ctx "idx") in
  Alcotest.(check string) "first" "v1" body;
  Eio.Path.unlink Eio.Path.(ctx.root / ctx.upstream_host / "idx");
  let _, h, body = request ctx (cache_path ctx "idx") in
  Alcotest.(check string) "refetched" "v1" body;
  Alcotest.(check string) "miss again" "MISS" (header h "x-cache");
  Alcotest.(check int) "two upstream requests" 2 (List.length ctx.up.requests)

let test_client_download =
  with_setup (fun p -> if p = "/ok.bin" then Serve (body_of 3000, 0.) else Status 404)
  @@ fun ctx ->
  let out = Eio.Path.native_exn Eio.Path.(ctx.root / "downloaded") in
  let fs = Eio.Path.(ctx.root / "..") in
  let download ~url ~dest =
    Client.download ~net:ctx.net ~fs ~cache:ctx.base ~url ~dest
  in
  (match download ~url:(Printf.sprintf "http://%s/ok.bin" ctx.upstream_host) ~dest:(`File out) with
  | Ok () -> ()
  | Error e -> Alcotest.failf "download failed: %a" Client.pp_error e);
  Alcotest.(check string) "downloaded bytes" (body_of 3000) (Eio.Path.load Eio.Path.(ctx.root / "downloaded"));
  let buf = Buffer.create 3000 in
  (match
     download ~url:(Printf.sprintf "http://%s/ok.bin" ctx.upstream_host)
       ~dest:(`Sink (Eio.Flow.buffer_sink buf))
   with
  | Ok () -> ()
  | Error e -> Alcotest.failf "download to sink failed: %a" Client.pp_error e);
  Alcotest.(check string) "sink bytes" (body_of 3000) (Buffer.contents buf);
  (match download ~url:(Printf.sprintf "http://%s/missing" ctx.upstream_host) ~dest:(`File (out ^ "2")) with
  | Error (Client.Status (404, _)) -> ()
  | Error e -> Alcotest.failf "unexpected error: %a" Client.pp_error e
  | Ok () -> Alcotest.fail "404 reported as success");
  Alcotest.(check bool) "nothing written" false (Eio.Path.is_file Eio.Path.(ctx.root / "downloaded2"));
  (match download ~url:"ftp://x/y" ~dest:(`File out) with
  | Error (Client.Bad_url _) -> ()
  | _ -> Alcotest.fail "ftp accepted");
  Alcotest.(check int) "upstream requests" 2 (List.length ctx.up.requests)

let test_cache_base () =
  List.iter
    (fun (input, expected) -> Alcotest.(check string) input expected (Client.cache_base input))
    [
      ("localhost:8080", "http://localhost:8080");
      ("10.0.0.1", "http://10.0.0.1:8080");
      ("http://10.0.0.1:9000/", "http://10.0.0.1:9000");
      ("cache.example.com:80", "http://cache.example.com:80");
    ]

let test_clean_part_files () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let root_name = Filename.concat (Filename.get_temp_dir_name ()) "fetcher-test-parts" in
  let root = Eio.Path.(Eio.Stdenv.fs env / root_name) in
  (try Eio.Path.rmtree root with _ -> ());
  Eio.Path.mkdirs ~perm:0o755 Eio.Path.(root / "h" / "d");
  Eio.Path.save ~create:(`Or_truncate 0o644) Eio.Path.(root / "h" / "d" / "f.part-123") "x";
  Eio.Path.save ~create:(`Or_truncate 0o644) Eio.Path.(root / "h" / "d" / "f") "y";
  Eio.Path.save ~create:(`Or_truncate 0o644) Eio.Path.(root / "h" / "part-1") "z";
  let store =
    Store.create ~sw ~fs:(Eio.Stdenv.fs env) ~proc_mgr:(Eio.Stdenv.process_mgr env)
      ~clock:(Eio.Stdenv.clock env) ~root:root_name ()
  in
  Alcotest.(check int) "removed" 1 (Store.clean_part_files store);
  Alcotest.(check bool) "kept f" true (Eio.Path.is_file Eio.Path.(root / "h" / "d" / "f"));
  Alcotest.(check bool) "kept part-1" true (Eio.Path.is_file Eio.Path.(root / "h" / "part-1"));
  Alcotest.(check bool) "removed part" false
    (Eio.Path.is_file Eio.Path.(root / "h" / "d" / "f.part-123"));
  Eio.Path.rmtree root

let end_to_end_tests =
  [
    Alcotest.test_case "miss then hit" `Quick test_miss_then_hit;
    Alcotest.test_case "20 concurrent misses, one fetch" `Quick test_coalescing;
    Alcotest.test_case "HEAD and Range" `Quick test_head_and_range;
    Alcotest.test_case "upstream 404 passes through" `Quick test_upstream_404;
    Alcotest.test_case "upstream 503 retried then 502" `Quick test_upstream_503;
    Alcotest.test_case "truncated body stores nothing" `Quick test_truncated;
    Alcotest.test_case "bad requests" `Quick test_bad_requests;
    Alcotest.test_case "deleted file is fetched again" `Quick test_delete_refetches;
    Alcotest.test_case "stale part files removed" `Quick test_clean_part_files;
    Alcotest.test_case "client download" `Quick test_client_download;
    Alcotest.test_case "cache base normalisation" `Quick test_cache_base;
  ]

let () =
  Alcotest.run "fetcher"
    [
      ("cache_path", cache_path_tests);
      ("range", range_tests);
      ("end_to_end", end_to_end_tests);
    ]
