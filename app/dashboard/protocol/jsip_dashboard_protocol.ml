open! Core
open Jsip_types
module Rpc = Async_rpc_kernel.Rpc

module Recent_samples = struct
  module Query = struct
    type t = { since : Time_ns.t option } [@@deriving sexp, bin_io, equal]
  end

  module Response = struct
    type t =
      { samples : Exchange_stats.t list
      ; exchange_connected : bool
      }
    [@@deriving sexp_of, bin_io]
  end
end

let recent_samples_rpc =
  Rpc.Rpc.create
    ~name:"recent-samples"
    ~version:1
    ~bin_query:Recent_samples.Query.bin_t
    ~bin_response:Recent_samples.Response.bin_t
    ~include_in_error_count:Only_on_exn
;;
