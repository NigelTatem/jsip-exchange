exception ParseError of string

type verb =
  | Buy
  | Sell
  | Book
  | Subscribe
[@@deriving
  sexp
  , bin_io
  , compare
  , equal
  , enumerate
  , hash
  , string ~case_insensitive ~capitalize:"SCREAMING_SNAKE_CASE"]

type t =
  | Submit of Order.Request.t
  | Book of Symbol.t
  | Subscribe of Symbol.t

(* Default participant when no "as <name>" is specified in the command.
   [parse_command_with_default_participant] overrides this with the
   caller-supplied default. *)
let default_participant = Participant.of_string "anonymous"

let parse_command line =
  let line = String.strip line in
  if String.is_empty line
  then Error "empty command"
  else (
    let parts =
      String.split line ~on:' ' |> List.filter ~f:(Fn.non String.is_empty)
    in
    match parts with
    | [] -> Error "empty command"
    | side_str :: rest ->
      let open Result.Let_syntax in
      let%bind side =
        match String.uppercase side_str with
        | "BUY" -> Ok Verb.Buy
        | "SELL" -> Ok Verb.Sell
        | other ->
          Error [%string "unknown command: %{other} (expected BUY or SELL)"]
      in
      (match rest with
       | symbol_str :: size_str :: price_str :: rest ->
         let%bind size =
           match Int.of_string_opt size_str with
           | Some n when n > 0 -> Ok n
           | Some _ -> Error "size must be positive"
           | None -> Error [%string "invalid size: %{size_str}"]
         in
         let%bind price =
           try Ok (Price.of_string price_str) with
           | exn ->
             let exn_str = Exn.to_string exn in
             Error
               [%string "invalid price: %{price_str}\nexception: %{exn_str}"]
         in
         let%bind symbol =
           try Ok (Symbol.of_string symbol_str) with
           | exn ->
             let exn_str = Exn.to_string exn in
             Error
               [%string
                 "invalid symbol: %{symbol_str}\nexception: %{exn_str}"]
         in
         let%bind time_in_force, rest =
           match rest with
           | tif_str :: rest' ->
             (match String.uppercase tif_str with
              | "IOC" -> Ok (Time_in_force.Ioc, rest')
              | "DAY" -> Ok (Day, rest')
              | "AS" -> Ok (Day, rest)
              | _ ->
                Error
                  [%string
                    "unknown time-in-force: %{tif_str} (expected DAY or IOC)"])
           | [] -> Ok (Day, [])
         in
         let%bind participant =
           match rest with
           | "as" :: name :: _ | "AS" :: name :: _ ->
             Ok (Participant.of_string name)
           | [] -> Ok default_participant
           | _ ->
             let trailing = String.concat ~sep:" " rest in
             Error [%string "unexpected trailing arguments: %{trailing}"]
         in
         Ok
           ({ symbol
            ; participant
            ; side
            ; price
            ; size = Size.of_int size
            ; time_in_force
            }
            : Order.Request.t)
       | _ ->
         Error
           "expected: BUY|SELL <symbol> <size> <price> [DAY|IOC] [as <name>]"))
;;

let parse_command_with_default_participant line ~default =
  match parse_command line with
  | Error _ as err -> err
  | Ok request ->
    if Participant.equal request.participant default_participant
    then Ok { request with participant = default }
    else Ok request
;;

let parse verb = split " "
