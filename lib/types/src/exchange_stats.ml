open! Core

module Subscriber = struct
  type t =
    { label : string
    ; pipe_length : int
    }
  [@@deriving sexp_of, bin_io, compare, equal]
end

module Connection = struct
  type t =
    { peer : string
    ; participant : Participant.t option
    ; bytes_to_write : int
    }
  [@@deriving sexp_of, bin_io, compare, equal]
end

module Participant_activity = struct
  type t =
    { participant : Participant.t
    ; submits : int
    ; resting_orders : int
    }
  [@@deriving sexp_of, bin_io, compare, equal]
end

module Symbol_depth = struct
  type t =
    { symbol : Symbol.t
    ; bbo : Bbo.t
    ; bid_depth : Size.t
    ; ask_depth : Size.t
    }
  [@@deriving sexp_of, bin_io, compare, equal]
end

module Engine = struct
  type t =
    { max_gap_since_last_snapshot : Time_ns.Span.t
    ; request_queue_length : int
    }
  [@@deriving sexp_of, bin_io, compare, equal]
end

type t =
  { taken_at : Time_ns.t
  ; subscribers : Subscriber.t list
  ; connections : Connection.t list
  ; participants : Participant_activity.t list
  ; symbols : Symbol_depth.t list
  ; engine : Engine.t
  ; events_dispatched : int
  ; evictions : int
  }
[@@deriving sexp_of, bin_io, compare, equal]
