open! Core
open Jsip_types

module Verb = struct
  type t =
    | Buy
    | Sell
    | Book
    | Subscribe
    | Cancel
  [@@deriving
    sexp
    , bin_io
    , compare
    , equal
    , enumerate
    , hash
    , string ~case_insensitive ~capitalize:"SCREAMING_SNAKE_CASE"]
end

type t =
  | Submit of Order.Request.t
  | Book of Symbol.t
  | Subscribe of Symbol.t
  | Cancel of Client_order_id.t

let parse ?default_participant line : t Or_error.t =
  let default_participant =
    Option.value
      default_participant
      ~default:(Participant.of_string "anonymous")
  in
  let line = String.strip line in
  if String.is_empty line
  then Or_error.error_string "empty command"
  else (
    let parts =
      String.split line ~on:' ' |> List.filter ~f:(Fn.non String.is_empty)
    in
    match parts with
    | [] -> Or_error.error_string "empty command"
    | verb_str :: rest ->
      let open Or_error.Let_syntax in
      let%bind verb =
        match Verb.of_string verb_str with
        | v -> Ok v
        | exception _ -> Or_error.errorf "unknown command: %s" verb_str
      in
      (match verb with
       | Verb.Buy | Verb.Sell ->
         let side =
           if Verb.equal verb Verb.Buy then Side.Buy else Side.Sell
         in
         (match rest with
          | client_id_str :: symbol_str :: size_str :: price_str :: rest ->
            let%bind client_order_id =
              match Int.of_string_opt client_id_str with
              | Some n -> Ok n
              | None ->
                Or_error.errorf "invalid client order id: %s" client_id_str
            in
            let%bind size =
              match Int.of_string_opt size_str with
              | Some n when n > 0 -> Ok n
              | Some _ -> Or_error.error_string "size must be positive"
              | None -> Or_error.errorf "invalid size: %s" size_str
            in
            let%bind price =
              Or_error.try_with (fun () -> Price.of_string price_str)
            in
            let%bind symbol =
              Or_error.try_with (fun () -> Symbol.of_string symbol_str)
            in
            let%bind time_in_force, rest =
              match rest with
              | tif_str :: rest' ->
                (match Time_in_force.of_string tif_str with
                 | tif -> Ok (tif, rest')
                 | exception _ ->
                   Or_error.errorf
                     "unknown time-in-force: %s (expected %s)"
                     tif_str
                     Time_in_force.all_str)
              | [] -> Ok (Time_in_force.Day, [])
            in
            let%bind participant =
              match rest with
              | [] -> Ok default_participant
              | _ ->
                Or_error.errorf
                  "unexpected trailing arguments: %s"
                  (String.concat ~sep:" " rest)
            in
            Ok
              (Submit
                 ({ symbol
                  ; participant
                  ; side
                  ; price
                  ; size = Size.of_int size
                  ; time_in_force
                  ; client_order_id
                  }
                  : Order.Request.t))
          | _ ->
            Or_error.errorf
              "expected: <client_id> <symbol> <size> <price> [%s]"
              Time_in_force.all_str)
       | Verb.Book ->
         (match rest with
          | [ symbol_str ] ->
            let%bind symbol =
              Or_error.try_with (fun () -> Symbol.of_string symbol_str)
            in
            Ok (Book symbol)
          | [] -> Or_error.error_string "expected: BOOK <symbol>"
          | _ ->
            Or_error.errorf
              "unexpected trailing arguments: %s"
              (String.concat ~sep:" " rest))
       | Verb.Subscribe ->
         (match rest with
          | [ symbol_str ] ->
            let%bind symbol =
              Or_error.try_with (fun () -> Symbol.of_string symbol_str)
            in
            Ok (Subscribe symbol)
          | [] -> Or_error.error_string "expected: SUBSCRIBE <symbol>"
          | _ ->
            Or_error.errorf
              "unexpected trailing arguments: %s"
              (String.concat ~sep:" " rest))
       | Verb.Cancel ->
         (match rest with
          | [ id_str ] ->
            let%bind client_order_id =
              match Int.of_string_opt id_str with
              | Some n -> Ok (Client_order_id.of_int n)
              | None -> Or_error.errorf "invalid client order id: %s" id_str
            in
            Ok (Cancel client_order_id)
          | [] -> Or_error.error_string "expected: CANCEL <client_order_id>"
          | _ ->
            Or_error.errorf
              "unexpected trailing arguments: %s"
              (String.concat ~sep:" " rest))))
;;
