type error =
  | Bad_url of string
  | Cannot_connect of string
  | Status of int * string
  | Write_failed of string

let pp_error ppf = function
  | Bad_url msg -> Fmt.pf ppf "%s" msg
  | Cannot_connect msg -> Fmt.pf ppf "cannot reach the cache: %s" msg
  | Status (code, body) ->
      if body = "" then Fmt.pf ppf "cache returned HTTP %d" code
      else Fmt.pf ppf "cache returned HTTP %d: %s" code body
  | Write_failed msg -> Fmt.pf ppf "cannot write output: %s" msg

let cache_base s =
  let s = String.trim s in
  let s = if String.ends_with ~suffix:"/" s then String.sub s 0 (String.length s - 1) else s in
  let has_scheme = String.starts_with ~prefix:"http://" s || String.starts_with ~prefix:"https://" s in
  let s = if has_scheme then s else "http://" ^ s in
  (* Add the default port to a bare host. *)
  let after_scheme = String.index s ':' + 3 in
  let authority = String.sub s after_scheme (String.length s - after_scheme) in
  if String.contains authority ':' || String.contains authority '/' then s else s ^ ":8080"

let cache_url ~cache key = cache_base cache ^ Cache_path.request_path key

(* Eio's exception printer spreads over several lines; one line is enough. *)
let one_line s =
  String.split_on_char '\n' s |> List.map String.trim |> List.filter (( <> ) "") |> String.concat " "

let read_all body = Eio.Buf_read.(parse_exn take_all) body ~max_size:65536

let download ~net ~fs ~cache ~url ~dest =
  match Cache_path.of_url url with
  | Error msg -> Error (Bad_url msg)
  | Ok key -> (
      let uri = Uri.of_string (cache_url ~cache key) in
      Eio.Switch.run @@ fun sw ->
      let client = Cohttp_eio.Client.make ~https:None net in
      match Cohttp_eio.Client.get client ~sw uri with
      | exception (Eio.Io _ as exn) -> Error (Cannot_connect (one_line (Printexc.to_string exn)))
      | resp, body -> (
          match Http.Response.status resp |> Http.Status.to_int with
          | 200 -> (
              match dest with
              | `Sink sink ->
                  Eio.Flow.copy body sink;
                  Ok ()
              | `File path -> (
                  let part = Eio.Path.(fs / Printf.sprintf "%s.part-%d" path (Unix.getpid ())) in
                  let remove_part () = try Eio.Path.unlink part with _ -> () in
                  try
                    Eio.Path.with_open_out ~create:(`Or_truncate 0o644) part (fun f ->
                        Eio.Flow.copy body f);
                    Eio.Path.rename part Eio.Path.(fs / path);
                    Ok ()
                  with
                  | Eio.Io _ as exn ->
                      remove_part ();
                      Error (Write_failed (one_line (Printexc.to_string exn)))
                  | End_of_file ->
                      remove_part ();
                      Error (Cannot_connect "connection closed before the body was complete")))
          | code -> Error (Status (code, String.trim (read_all body)))))
