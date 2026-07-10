open! Core

type t =
  { symbol : Symbol_id.t
  ; bids : Level.t list
  ; asks : Level.t list
  ; bbo : Bbo.t
  }
[@@deriving sexp, bin_io]

let to_string ~render_symbol { symbol; bids; asks; bbo } =
  let format_side label levels =
    match levels with
    | [] -> [%string "  %{label}: (empty)"]
    | _ ->
      let lines =
        List.map levels ~f:(fun level -> [%string "    %{level#Level}"])
        |> String.concat ~sep:"\n"
      in
      [%string "  %{label}:\n%{lines}"]
  in
  let symbol = render_symbol symbol in
  String.concat
    ~sep:"\n"
    [ [%string "=== %{symbol} ==="]
    ; format_side "BIDS" bids
    ; format_side "ASKS" asks
    ; [%string "  BBO: %{bbo#Bbo}"]
    ]
;;
