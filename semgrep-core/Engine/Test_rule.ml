(* Yoann Padioleau
 *
 * Copyright (C) 2021 r2c
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License (GPL)
 * version 2 as published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * file license.txt for more details.
*)
open Common

module FT = File_type
module R = Rule
module E = Error_code

let logger = Logging.get_logger [__MODULE__]

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)
(*
let (lang_of_rules: Rule.t list -> Lang.t) = fun rs ->
  match rs |> Common.find_some_opt (fun r ->
    match r.R.languages with
    | R.L (l, _) -> Some l
    | _ -> None
  ) with
  | Some l -> l
  | None -> failwith "could not find a language"
*)

let (xlangs_of_rules: Rule.t list -> Rule.xlang list) = fun rs ->
  rs |> List.map (fun r -> r.R.languages) |> List.sort_uniq (compare)

(*****************************************************************************)
(* Entry point *)
(*****************************************************************************)

let test_rules xs =
  let fullxs =
    xs
    |> File_type.files_of_dirs_or_files (function
      | FT.Config (FT.Yaml (* | FT.Json*) | FT.Jsonnet) -> true | _ -> false)
    |> Skip_code.filter_files_if_skip_list ~root:xs
  in

  let newscore  = Common2.empty_score () in
  let ext = "rule" in
  let total_mismatch = ref 0 in

  fullxs |> List.iter (fun file ->
    logger#info "processing rule file %s" file;
    let rules = Parse_rule.parse file in
    (* just a sanity check *)
    (* rules |> List.iter Check_rule.check; *)

    let xlangs = xlangs_of_rules rules in
    let xlang =
      match xlangs with
      | [] -> failwith (spf "no language found in %s" file)
      | [x] -> x
      | _::_::_ -> failwith (spf "too many languages found in %s"file)
    in
    let target =
      try
        let (d,b,ext) = Common2.dbe_of_filename file in
        Common2.readdir_to_file_list d |> Common.find_some (fun file2 ->
          let (_,b2, ext2) = Common2.dbe_of_filename_noext_ok file2 in
          if b = b2 && ext <> ext2
          then Some (Filename.concat d file2)
          else None
        )
      with Not_found -> failwith (spf "could not find a target for %s" file)
    in
    logger#info "processing target %s" target;

    (* expected *)
    let expected_error_lines = E.expected_error_lines_of_files [target] in

    (* actual *)
    let lazy_ast_and_errors = lazy (
      match xlang with
      | R.L (lang, _) ->
          let {Parse_target. ast; errors; _} =
            Parse_target.parse_and_resolve_name_use_pfff_or_treesitter
              lang target
          in
          ast, errors
      | R.LNone | R.LGeneric -> raise Impossible
    )
    in
    E.g_errors := [];
    let matches, errors =
      try
        Semgrep.check false (fun _ _ -> ()) rules
          (target, xlang, lazy_ast_and_errors)
      with exn ->
        failwith (spf "exn on %s (exn = %s)" file (Common.exn_to_s exn))
    in
    matches |> List.iter JSON_report.match_to_error;
    if not (errors = [])
    then failwith (spf "parsing error on %s" file);

    let actual_errors = !E.g_errors in
    actual_errors |> List.iter (fun e ->
      logger#info "found error: %s" (E.string_of_error e)
    );
    try
      E.compare_actual_to_expected actual_errors expected_error_lines;
      Hashtbl.add newscore file (Common2.Ok)
    with (OUnitTest.OUnit_failure s) ->
      pr2 s;
      Hashtbl.add newscore file (Common2.Pb s);
      (* coupling: ugly: with Error_code.compare_actual_to_expected *)
      if s =~ "it should find all reported errors and no more (\\([0-9]+\\) errors)"
      then
        let n = Common.matched1 s |> int_of_string in
        total_mismatch := !total_mismatch + n
      else failwith (spf "wrong unit failure format: %s" s)
  );
  Parse_info.print_regression_information ~ext xs newscore;
  pr2 (spf "total mismatch: %d" !total_mismatch);
  ()
