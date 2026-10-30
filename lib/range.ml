type t = { first : int; last : int }

let length t = t.last - t.first + 1

let int_of_string_opt s =
  if s = "" || not (String.for_all (fun c -> c >= '0' && c <= '9') s) then None
  else int_of_string_opt s

let parse ~size header =
  let header = String.trim header in
  match String.index_opt header '=' with
  | Some i when String.lowercase_ascii (String.sub header 0 i) = "bytes" -> (
      let spec = String.sub header (i + 1) (String.length header - i - 1) |> String.trim in
      if String.contains spec ',' then `Ignore
      else
        match String.index_opt spec '-' with
        | None -> `Ignore
        | Some j -> (
            let a = String.trim (String.sub spec 0 j) in
            let b = String.trim (String.sub spec (j + 1) (String.length spec - j - 1)) in
            match (int_of_string_opt a, int_of_string_opt b) with
            | None, None -> `Ignore
            | None, Some suffix ->
                (* bytes=-N: the last N bytes *)
                if suffix = 0 || size = 0 then `Unsatisfiable
                else
                  let first = max 0 (size - suffix) in
                  `Range { first; last = size - 1 }
            | Some first, None ->
                if first >= size then `Unsatisfiable else `Range { first; last = size - 1 }
            | Some first, Some last ->
                if first > last then `Ignore
                else if first >= size then `Unsatisfiable
                else `Range { first; last = min last (size - 1) }))
  | _ -> `Ignore
