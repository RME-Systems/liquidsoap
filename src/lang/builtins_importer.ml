(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2021 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA

 *****************************************************************************)

module TypeValue = Lang.MkAbstractValue (Parser_helper.TypeTerm)

let raise exn =
  let bt = Printexc.get_raw_backtrace () in
  Lang.raise_as_runtime ~bt ~kind:"import" exn

(* Default module exports. *)
let () = Environment.add_builtin ["_exports_"] (([], Lang.unit_t), Lang.unit)

let () =
  let t = Lang.univ_t () in
  Lang.add_builtin "_internal_module_importer_" ~category:`Liquidsoap
    ~flags:[`Hidden] ~descr:"Internal module importer"
    [
      ("ty", TypeValue.t, None, Some "Imported type");
      ("", Lang.string_t, None, None);
    ] t (fun p ->
      let ty = TypeValue.of_value (List.assoc "ty" p) in
      let fname = Lang.to_string (List.assoc "" p) in
      try
        let ic = open_in fname in
        let fname = Utils.home_unrelate fname in
        let pwd = Unix.getcwd () in
        let lexbuf = Sedlexing.Utf8.from_channel ic in
        let expr =
          Tutils.finalize
            ~k:(fun () -> close_in ic)
            (fun () -> Runtime.mk_expr ~fname ~pwd Parser.export lexbuf)
        in
        let expr = Term.make (Term.Cast (expr, ty)) in
        Typechecking.check ~throw:raise ~ignored:true expr;
        let exports = Evaluation.eval expr in
        exports
      with exn -> raise exn)
