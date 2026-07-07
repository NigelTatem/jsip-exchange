(* Style tokens for the dashboard client, composing the CSS custom properties
   defined on [:root] in the server's index.html. All styles are plain
   [style] attribute strings — this project has no ppx_css (see the
   bonsai-web skill's Styling section). *)

open! Core
open! Bonsai_web

let style value = Vdom.Attr.create "style" value

let page =
  style
    "height:100%; display:flex; flex-direction:column; overflow:hidden; \
     font-size:var(--font-size-sm)"
;;

(* --- Header band --- *)

let header =
  style
    "display:flex; align-items:center; gap:var(--space-lg); \
     padding:var(--space-md) var(--space-lg); border-bottom:1px solid \
     var(--color-border-1); background:var(--color-bg-1); flex:none"
;;

let title =
  style
    "font-size:var(--font-size-md); \
     font-weight:var(--font-weight-semibold); margin:0"
;;

let header_spacer = style "flex:1"

let badge =
  style
    "display:inline-flex; align-items:center; gap:6px; \
     font-size:var(--font-size-xs); color:var(--color-text-secondary); \
     white-space:nowrap"
;;

let dot color =
  style
    [%string
      "width:8px; height:8px; border-radius:9999px; background:%{color}; \
       flex:none"]
;;

let muted = style "color:var(--color-text-tertiary)"
let quiet = style "color:var(--color-text-quaternary)"

(* --- Panel grid --- *)

let grid =
  style
    "flex:1; overflow:auto; display:grid; \
     grid-template-columns:repeat(auto-fit, minmax(430px, 1fr)); \
     gap:var(--space-lg); padding:var(--space-lg); align-content:start"
;;

let panel =
  style
    "background:var(--color-bg-1); border:1px solid var(--color-border-1); \
     border-radius:var(--radius-lg); box-shadow:var(--shadow-1); \
     padding:var(--space-md) var(--space-lg) var(--space-lg); display:flex; \
     flex-direction:column; gap:var(--space-sm); min-height:140px"
;;

let panel_title =
  style
    "font-size:var(--font-size-xs); \
     font-weight:var(--font-weight-semibold); text-transform:uppercase; \
     color:var(--color-text-tertiary); margin:0"
;;

let empty =
  style "color:var(--color-text-quaternary); padding:var(--space-sm) 0"
;;

(* --- Tables --- *)

let table_wrap = style "overflow:auto; max-height:300px"

let table =
  style "width:100%; border-collapse:collapse; font-size:var(--font-size-sm)"
;;

let th =
  style
    "text-align:left; font-size:var(--font-size-xs); \
     font-weight:var(--font-weight-medium); \
     color:var(--color-text-quaternary); text-transform:uppercase; \
     padding:2px var(--space-sm) 6px 0; position:sticky; top:0; \
     background:var(--color-bg-1)"
;;

let th_num =
  style
    "text-align:right; font-size:var(--font-size-xs); \
     font-weight:var(--font-weight-medium); \
     color:var(--color-text-quaternary); text-transform:uppercase; \
     padding:2px 0 6px var(--space-sm); position:sticky; top:0; \
     background:var(--color-bg-1)"
;;

let td =
  style
    "padding:4px var(--space-sm) 4px 0; border-top:1px solid \
     var(--color-border-1); color:var(--color-text-secondary)"
;;

let td_mono =
  style
    "padding:4px var(--space-sm) 4px 0; border-top:1px solid \
     var(--color-border-1); font-family:var(--font-mono); \
     color:var(--color-text-secondary)"
;;

let td_num =
  style
    "padding:4px 0 4px var(--space-sm); border-top:1px solid \
     var(--color-border-1); text-align:right; font-family:var(--font-mono); \
     color:var(--color-text-primary)"
;;

(* --- Stat tiles --- *)

let stat_row = style "display:flex; gap:var(--space-xl); flex-wrap:wrap"
let stat = style "min-width:110px"

let stat_label =
  style
    "font-size:var(--font-size-xs); color:var(--color-text-quaternary); \
     text-transform:uppercase"
;;

let stat_value =
  style
    "font-family:var(--font-mono); font-size:var(--font-size-md); \
     font-weight:var(--font-weight-semibold); \
     color:var(--color-text-primary)"
;;

let stat_value_warn =
  style
    "font-family:var(--font-mono); font-size:var(--font-size-md); \
     font-weight:var(--font-weight-semibold); color:var(--color-warn)"
;;

(* --- Sparklines --- *)

let spark_row ~height =
  style
    [%string
      "display:flex; align-items:flex-end; gap:1px; height:%{height#Int}px; \
       margin-top:var(--space-xs)"]
;;

let spark_bar ~pct =
  style
    [%string
      "flex:1 1 0; min-width:1px; height:%{pct#Float}%; \
       background:var(--color-accent); border-radius:1px 1px 0 0"]
;;

(* A discontinuity (counter reset) renders as a short quiet stub, not a value
   — absence must not look like zero traffic. *)
let spark_gap =
  style
    "flex:1 1 0; min-width:1px; height:3px; \
     background:var(--color-text-quaternary); border-radius:1px"
;;

let spark_label =
  style
    "font-size:var(--font-size-xs); color:var(--color-text-quaternary); \
     margin-top:2px"
;;
