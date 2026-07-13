open! Core
open Jsip_types

(* A price level: the orders resting at a single price, plus their aggregated
   remaining size.

   Orders are keyed by [Order_id.t]. Because ids are handed out monotonically
   in arrival order, [Map.min_elt] is the oldest order at this price, so the
   map doubles as a FIFO queue with no separate queue to maintain.

   [total_size] is the sum of every order's remaining size. It is kept in sync
   on every [add]/[remove] so that top-of-book and snapshot queries can read a
   level's size in [O(log price_levels)] instead of re-summing its orders. This
   cache is the whole point of the by-price layout — and its invariant (the
   sum is always exact) is the cost we take on in exchange. *)
module Price_level = struct
  type t =
    { orders : Order.t Map.M(Order_id).t
    ; total_size : Size.t
    }
  [@@deriving sexp_of]

  let empty =
    { orders = Map.empty (module Order_id); total_size = Size.zero }
  ;;

  let is_empty t = Map.is_empty t.orders

  (* Oldest order at this price (earliest arrival), or [None] if empty. *)
  let front t = Option.map (Map.min_elt t.orders) ~f:snd

  let add t order =
    { orders =
        Map.set t.orders ~key:(Order.order_id order) ~data:order
    ; total_size = Size.( + ) t.total_size (Order.remaining_size order)
    }
  ;;

  (* Remove [order_id] from this level, keeping [total_size] exact. Returns
     the level unchanged if the id is not present. *)
  let remove t order_id =
    match Map.find t.orders order_id with
    | None -> t
    | Some order ->
      { orders = Map.remove t.orders order_id
      ; total_size = Size.( - ) t.total_size (Order.remaining_size order)
      }
  ;;
end

type t =
  { symbol : Symbol_id.t
  ; mutable bids : Price_level.t Map.M(Price).t
  ; mutable asks : Price_level.t Map.M(Price).t
  ; mutable order_ids : (Price.t * Side.t) Map.M(Order_id).t
  }
[@@deriving sexp_of]

let create symbol =
  { symbol
  ; bids = Map.empty (module Price)
  ; asks = Map.empty (module Price)
  ; order_ids = Map.empty (module Order_id)
  }
;;

let symbol t = t.symbol

let side_map t side =
  match (side : Side.t) with Buy -> t.bids | Sell -> t.asks
;;

let set_side_map t side orders =
  match (side : Side.t) with
  | Buy -> t.bids <- orders
  | Sell -> t.asks <- orders
;;

let add t order =
  let side = Order.side order in
  let price = Order.price order in
  let id = Order.order_id order in
  let price_map = side_map t side in
  let level =
    Map.find price_map price |> Option.value ~default:Price_level.empty
  in
  let level = Price_level.add level order in
  set_side_map t side (Map.set price_map ~key:price ~data:level);
  t.order_ids <- Map.set t.order_ids ~key:id ~data:(price, side)
;;

let remove' t order_id =
  match Map.find t.order_ids order_id with
  | None -> None
  | Some (price, side) ->
    let price_map = side_map t side in
    (match Map.find price_map price with
     | None -> None
     | Some level ->
       let found_order = Map.find level.orders order_id in
       let level = Price_level.remove level order_id in
       let price_map =
         if Price_level.is_empty level
         then Map.remove price_map price
         else Map.set price_map ~key:price ~data:level
       in
       set_side_map t side price_map;
       t.order_ids <- Map.remove t.order_ids order_id;
       found_order)
;;

let remove t order_id = ignore (remove' t order_id : Order.t option)

let find t order_id =
  match Map.find t.order_ids order_id with
  | None -> None
  | Some (price, side) ->
    (match Map.find (side_map t side) price with
     | None -> None
     | Some level -> Map.find level.orders order_id)
;;

(* The best price level on a side: lowest ask, highest bid. [O(log P)] where
   [P] is the number of distinct price levels. *)
let best_level_entry t side : (Price.t * Price_level.t) option =
  match (side : Side.t) with
  | Sell -> Map.min_elt (side_map t side)
  | Buy -> Map.max_elt (side_map t side)
;;

(* The single best resting order on a side: front of the best level, i.e. the
   most aggressively priced order, breaking ties by earliest arrival. *)
let best_resting_order t side =
  match best_level_entry t side with
  | None -> None
  | Some (_price, level) -> Price_level.front level
;;

let find_match t (incoming_order : Order.t) : Order.t option =
  let incoming_side = Order.side incoming_order in
  let opposite_side = Side.flip incoming_side in
  match best_resting_order t opposite_side with
  | None -> None
  | Some resting ->
    (match
       Price.is_marketable
         incoming_side
         ~price:(Order.price incoming_order)
         ~resting_price:(Order.price resting)
     with
     | true -> Some resting
     | false -> None)
;;

let orders_on_side t side =
  Map.to_alist (side_map t side)
  |> List.concat_map ~f:(fun (_price, level) ->
    Map.data level.Price_level.orders)
;;

let is_empty t = Map.is_empty t.bids && Map.is_empty t.asks

let count t side =
  Map.fold (side_map t side) ~init:0 ~f:(fun ~key:_ ~data:level acc ->
    acc + Map.length level.Price_level.orders)
;;

(* Reads the cached [total_size] — no per-order sweep. *)
let best_level t side : Level.t option =
  match best_level_entry t side with
  | None -> None
  | Some (price, level) -> Some { Level.price; size = level.total_size }
;;

let best_bid_offer t : Bbo.t =
  { bid = best_level t Buy; ask = best_level t Sell }
;;

let snapshot_side t (side : Side.t) =
  (* Each price level already carries its aggregated size, so a snapshot is
     just the price map read out best-first: [Map.to_alist] is ascending by
     price, which is best-first for asks; bids reverse it. *)
  let levels =
    Map.to_alist (side_map t side)
    |> List.map ~f:(fun (price, level) ->
      { Level.price; size = level.Price_level.total_size })
  in
  match side with Buy -> List.rev levels | Sell -> levels
;;

let snapshot t =
  { Book.symbol = symbol t
  ; bids = snapshot_side t Buy
  ; asks = snapshot_side t Sell
  ; bbo = best_bid_offer t
  }
;;

module For_testing = struct
  let remove = remove'
end
