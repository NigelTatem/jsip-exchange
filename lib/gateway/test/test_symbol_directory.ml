open! Core
open Jsip_types
open Jsip_gateway

let directory =
  Symbol_directory.of_names
    [ Symbol.of_string "AAPL"
    ; Symbol.of_string "TSLA"
    ; Symbol.of_string "GOOG"
    ]
;;

let%expect_test "of_names assigns id i to symbol i, both directions" =
  List.iter (Symbol_directory.to_pairs directory) ~f:(fun (name, id) ->
    print_endline [%string "%{name#Symbol} -> %{id#Symbol_id}"]);
  (* to_pairs is name-sorted, so the order is alphabetical, not by id. *)
  [%expect {|
    AAPL -> 0
    GOOG -> 2
    TSLA -> 1
    |}];
  (* ids come back in numeric order — the order the engine's book array
     wants. *)
  print_s [%sexp (Symbol_directory.ids directory : Symbol_id.t list)];
  [%expect {| (0 1 2) |}]
;;

let%expect_test "name <-> id round-trips" =
  let tsla =
    Symbol_directory.id_of_name directory (Symbol.of_string "TSLA")
  in
  print_s [%sexp (tsla : Symbol_id.t option)];
  [%expect {| (1) |}];
  let back = Option.bind tsla ~f:(Symbol_directory.name_of_id directory) in
  print_s [%sexp (back : Symbol.t option)];
  [%expect {| (TSLA) |}]
;;

let%expect_test "unknown name and id resolve to None" =
  print_s
    [%sexp
      (Symbol_directory.id_of_name directory (Symbol.of_string "ZZZZ")
       : Symbol_id.t option)];
  [%expect {| () |}];
  print_s
    [%sexp
      (Symbol_directory.name_of_id directory (Symbol_id.of_int 9)
       : Symbol.t option)];
  [%expect {| () |}]
;;

let%expect_test "render shows the name, falling back to the id" =
  print_endline (Symbol_directory.render directory (Symbol_id.of_int 0));
  [%expect {| AAPL |}];
  (* An id with no name — e.g. one the directory never learned — stays
     printable rather than raising. *)
  print_endline (Symbol_directory.render directory (Symbol_id.of_int 9));
  [%expect {| 9 |}];
  (* The empty directory a server without a name map serves: everything is an
     id. *)
  print_endline
    (Symbol_directory.render Symbol_directory.empty (Symbol_id.of_int 0));
  [%expect {| 0 |}]
;;

let%expect_test "round-trip: a name parses to an id and renders back as the \
                 name"
  =
  (* This is the whole point of Phase 2: the human types a name, the id
     crosses the wire, and the same directory renders the name again. *)
  let event =
    match Exchange_command.parse "BOOK AAPL" ~directory with
    | Ok (Book id) ->
      Exchange_event.Best_bid_offer_update
        { symbol = id; bbo = { bid = None; ask = None } }
    | _ -> failwith "expected a BOOK command"
  in
  let render_symbol = Symbol_directory.render directory in
  print_endline (Event_format.format_event ~render_symbol event);
  [%expect {| BBO AAPL bid=- ask=- |}]
;;
