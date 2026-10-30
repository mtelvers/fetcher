type t = {
  scheme : string;
  host : string;
  segments : string list;
  trailing_slash : bool;
  query : string option;
}

let ( let* ) = Result.bind

let has_control_char s =
  String.exists (fun c -> Char.code c < 0x20 || Char.code c = 0x7f) s

let valid_host_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '-' | '_' | ':' | '[' | ']' -> true
  | _ -> false

let check_segment seg =
  if seg = "." || seg = ".." then Error (Printf.sprintf "segment %S is not allowed" seg)
  else Ok seg

let split_query s =
  match String.index_opt s '?' with
  | None -> (s, None)
  | Some i -> (String.sub s 0 i, Some (String.sub s (i + 1) (String.length s - i - 1)))

let nonempty_segments path = String.split_on_char '/' path |> List.filter (fun s -> s <> "")

let make ~scheme ~host ~path ~query =
  let* () =
    if scheme = "http" || scheme = "https" then Ok ()
    else Error (Printf.sprintf "scheme must be http or https, got %S" scheme)
  in
  let* () =
    if host = "" then Error "empty host"
    else if not (String.for_all valid_host_char host) || String.starts_with ~prefix:"-" host
    then Error (Printf.sprintf "invalid host %S" host)
    else Ok ()
  in
  let* host = check_segment host in
  let* segments =
    List.fold_right
      (fun seg acc ->
        let* acc = acc in
        let* seg = check_segment seg in
        Ok (seg :: acc))
      (nonempty_segments path) (Ok [])
  in
  let trailing_slash = segments = [] || String.ends_with ~suffix:"/" path in
  Ok { scheme; host; segments; trailing_slash; query }

let of_request_path target =
  if has_control_char target then Error "control character in request path"
  else
    let path, query = split_query target in
    match nonempty_segments path with
    | [] | [ _ ] -> Error "expected /<scheme>/<host>/<path>"
    | scheme :: host :: rest ->
        (* Re-join the remainder, keeping only the information that matters:
           the segments and whether the original ended in a slash. *)
        let path =
          "/" ^ String.concat "/" rest
          ^ if rest <> [] && String.ends_with ~suffix:"/" path then "/" else ""
        in
        make ~scheme ~host ~path ~query

let of_url url =
  if has_control_char url then Error "control character in URL"
  else
    let url = match String.index_opt url '#' with None -> url | Some i -> String.sub url 0 i in
    match String.index_opt url ':' with
    | Some i when i + 2 < String.length url && String.sub url i 3 = "://" ->
        let scheme = String.sub url 0 i in
        let rest = String.sub url (i + 3) (String.length url - i - 3) in
        let rest, query = split_query rest in
        let host, path =
          match String.index_opt rest '/' with
          | None -> (rest, "/")
          | Some j -> (String.sub rest 0 j, String.sub rest j (String.length rest - j))
        in
        if String.contains host '@' then Error "userinfo in URL is not supported"
        else make ~scheme ~host ~path ~query
    | _ -> Error (Printf.sprintf "not an absolute http(s) URL: %S" url)

let path_string t =
  "/" ^ String.concat "/" t.segments ^ if t.trailing_slash && t.segments <> [] then "/" else ""

let query_suffix t = match t.query with None -> "" | Some q -> "?" ^ q
let upstream_url t = t.scheme ^ "://" ^ t.host ^ path_string t ^ query_suffix t
let request_path t = "/" ^ t.scheme ^ "/" ^ t.host ^ path_string t ^ query_suffix t

let relative_file t =
  let segments = if t.trailing_slash then t.segments @ [ "index.html" ] else t.segments in
  let file_query =
    match t.query with
    | None -> ""
    | Some q -> "?" ^ String.concat "%2F" (String.split_on_char '/' q)
  in
  (* [segments] is non-empty: an empty path has [trailing_slash = true]. *)
  match List.rev segments with
  | [] -> assert false
  | last :: rev_init -> String.concat "/" (t.host :: List.rev ((last ^ file_query) :: rev_init))
