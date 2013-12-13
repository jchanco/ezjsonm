(*
 * Copyright (c) 2013 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

(* From http://erratique.ch/software/jsonm/doc/Jsonm.html#datamodel *)
type t =
  [ `Null
  | `Bool of bool
  | `Float of float
  | `String of string
  | `A of t list
  | `O of (string * t) list ]

exception Escape of ((int * int) * (int * int)) * Jsonm.error

let json_of_src src =
  let d = Jsonm.decoder src in
  let dec () = match Jsonm.decode d with
    | `Lexeme l -> l
    | `Error e  -> raise (Escape (Jsonm.decoded_range d, e))
    | `End
    | `Await    -> assert false
  in
  let rec value v k = match v with
    | `Os -> obj [] k
    | `As -> arr [] k
    | `Null
    | `Bool _
    | `String _
    | `Float _ as v -> k v
    | _ -> assert false
  and arr vs k = match dec () with
    | `Ae -> k (`A (List.rev vs))
    | v   -> value v (fun v -> arr (v :: vs) k)
  and obj ms k = match dec () with
    | `Oe     -> k (`O (List.rev ms))
    | `Name n -> value (dec ()) (fun v -> obj ((n, v) :: ms) k)
    | _       -> assert false
  in
  try `JSON (value (dec ()) (fun v -> v))
  with Escape (r, e) -> `Error (r, e)

let to_dst ?(minify=true) dst (json:t) =
  let enc e l = ignore (Jsonm.encode e (`Lexeme l)) in
  let rec value v k e = match v with
    | `A vs -> arr vs k e
    | `O ms -> obj ms k e
    | `Null | `Bool _ | `Float _ | `String _ as v -> enc e v; k e
  and arr vs k e = enc e `As; arr_vs vs k e
  and arr_vs vs k e = match vs with
    | v :: vs' -> value v (arr_vs vs' k) e
    | [] -> enc e `Ae; k e
  and obj ms k e = enc e `Os; obj_ms ms k e
  and obj_ms ms k e = match ms with
    | (n, v) :: ms -> enc e (`Name n); value v (obj_ms ms k) e
    | [] -> enc e `Oe; k e
  in
  let e = Jsonm.encoder ~minify dst in
  let finish e = ignore (Jsonm.encode e `End) in
  match json with
  | `A _ | `O _ as json -> value json finish e
  | _ -> invalid_arg "invalid json text"

let to_buffer ?minify buf json =
  to_dst ?minify (`Buffer buf) json

let to_string ?minify json =
  let buf = Buffer.create 1024 in
  to_buffer ?minify buf json;
  Buffer.contents buf

let to_channel ?minify oc json =
  to_dst ?minify (`Channel oc) json

exception Parse_error of t * string

let parse_error t fmt =
  Printf.kprintf (fun msg ->
      raise (Parse_error (t, msg))
    ) fmt

let string_of_error error =
  Jsonm.pp_error Format.str_formatter error;
  Format.flush_str_formatter ()

let from_src src: t =
  match json_of_src src with
  | `JSON j      -> j
  | `Error (_,e) -> parse_error `Null "JSON.of_buffer %s" (string_of_error e)

let from_string str = from_src (`String str)

let from_channel chan = from_src (`Channel chan)

(* unit *)
let unit = `Null

let get_unit = function
  | `Null  -> ()
  | j      -> parse_error j "Ezjsonm.get_unit"

(* bool *)
let bool b = `Bool b

let get_bool = function
  | `Bool b -> b
  | j       -> parse_error j "Ezjsonm.get_bool"

(* string *)
let string s = `String s

let get_string = function
  | `String s -> s
  | j         -> parse_error j "Ezjsonm.get_string"

(* int *)
let int i = `Float (float_of_int i)

let get_int = function
  | `Float f -> int_of_float f
  | j        -> parse_error j "Ezjsonm.get_int"

(* flooat *)
let float f = `Float f

let get_float = function
  | `Float f -> f
  | j        -> parse_error j "Ezjsonm.get_float"

(* list *)
let list fn l =
  `A (List.map fn l)

let get_list fn = function
  | `A ks -> List.map fn ks
  | j     -> parse_error j "Ezjsonm.get_list"

(* string lists *)
let strings = list string

let get_strings = get_list get_string

(* options *)
let option fn = function
  | None   -> `Null
  | Some x -> fn x

let get_option fn (json:t) = match json with
  | `Null  -> None
  |  _     -> Some (fn json)

(* dict *)
let dict d : t = `O d

let get_dict = function
  | `O d -> d
  | j    -> parse_error j "Ezjsonm.get_dict"

(* pairs *)
let pair fk fv (k, v) =
  `A [fk k; fv v]

let get_pair fk fv = function
  | `A [k; v] -> (fk k, fv v)
  | j         -> parse_error j "Ezjsonm.get_pair"

let mem (t:t) path =
  let rec aux j p = match p, j with
    | []   , _    -> true
    | h::tl, `O o -> List.mem_assoc h o && aux (List.assoc h o) tl
    | _           -> false in
  aux t path

let find (t:t) path =
  let rec aux j p = match p, j with
    | []   , j    -> j
    | h::tl, `O o -> aux (List.assoc h o) tl
    | _           -> raise Not_found in
  aux t path

let map_dict f dict label =
  let rec aux acc = function
    | []    ->
      begin match f `Null with
        | None   -> List.rev acc
        | Some j -> List.rev_append acc [label, j]
      end
    | (l,j) as e :: dict ->
      if l = label then
        match f j with
        | None   -> List.rev_append acc dict
        | Some j -> List.rev_append acc ((l,j)::dict)
      else
        aux (e::acc) dict in
  aux [] dict

let map (f:t -> t option) (t:t) path =
  let rec aux t = function
    | []    -> f t
    | h::tl ->
      match t with
      | `O d -> Some (`O (map_dict (fun t -> aux t tl) d h))
      | j    -> None in
  match aux t path with
  | None   -> raise Not_found
  | Some j -> j

let update (t:t) path (v:t option) =
  map (fun _ -> v) t path
