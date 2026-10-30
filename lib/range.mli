(** HTTP [Range] header parsing for a file of known size. *)

type t = { first : int; last : int }
(** An inclusive byte range, satisfiable within the file. *)

val length : t -> int

val parse : size:int -> string -> [ `Range of t | `Unsatisfiable | `Ignore ]
(** [parse ~size header] interprets a [Range] header value for a file of
    [size] bytes. A single [bytes=] range is returned clamped to the file;
    one that lies wholly outside the file is [`Unsatisfiable]; anything else
    (multiple ranges, other units, syntax errors) is [`Ignore], and the caller
    should serve the whole file with status 200. *)
