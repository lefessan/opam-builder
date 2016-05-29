(**************************************************************************)
(*                                                                        *)
(*              OCamlPro-Inria-Irill Attribution AGPL                     *)
(*                                                                        *)
(*   Copyright OCamlPro-Inria-Irill 2011-2016. All rights reserved.       *)
(*   This file is distributed under the terms of the AGPL v3.0            *)
(*   (GNU Affero General Public Licence version 3.0) with                 *)
(*   a special OCamlPro-Inria-Irill attribution exception.                *)
(*                                                                        *)
(*     Contact: <typerex@ocamlpro.com> (http://www.ocamlpro.com/)         *)
(*                                                                        *)
(*  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,       *)
(*  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES       *)
(*  OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND              *)
(*  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS   *)
(*  BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN    *)
(*  ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN     *)
(*  CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE      *)
(*  SOFTWARE.                                                             *)
(**************************************************************************)



(*

  Naming conventions for short variables:
  * p : the package
  * v : the version of the package p (often p.package_version)
  * c : the commit
  * st : the state
  * dirs : the directories (often st.dirs)
*)

open CheckTypes.V
open CheckTypes
open StringCompat
open CopamInstall

let auto_fix = ref false
let arg_lint = ref false
let arg_lint_only = ref false
let opam_pull = ref true
let arg_build = ref true

let last_commit_cmd = "git rev-parse --short HEAD > last-commit.txt"

let command cmd =
  let exit = Sys.command cmd in
  if exit <> 0 then begin
    Printf.eprintf "Error: command failed with exit status %d:\n   %s\n%!"
      exit cmd;
    false
  end else true

let save_commit kind commit_hash =
  let oc = Printf.kprintf open_out "%s-commit.txt" kind in
  output_string oc commit_hash;
  output_string oc "\n";
  close_out oc

let load_commit kind =
  let ic = Printf.kprintf open_in "%s-commit.txt" kind in
  let commit = input_line ic in
  close_in ic;
  commit

let for_each_new_commit f =
  save_commit "previous" "reboot";
  while true do
    if
      (not !opam_pull ||
       command "git checkout master" &&
       command "git pull ocaml master") &&
      command last_commit_cmd then begin
        let previous_commit = load_commit "previous" in
        let current_commit = load_commit "last" in
        Sys.remove "last-commit.txt";

        if current_commit <> previous_commit then begin

          f current_commit;

          save_commit "previous" current_commit;
        end

    end;
    if not !opam_pull then exit 0;
    Unix.sleep 60;
  done



let () =
  List.iter (fun var ->
    try
      ignore (Sys.getenv var);
      Printf.eprintf "Error: %s is set\n%!" var;
      exit 2
    with Not_found -> ()
  ) [ "OCAMLPARAM"; "OCAMLRUNPARAM"; "OCAMLLIB"; "CAML_LD_LIBRARY_PATH" ]

let () = Unix.putenv "OCAMLRUNPARAM" "b=1"

let () =
  let path = OcpString.split (Sys.getenv "PATH") ':' in
  List.iter (fun cmd ->
    let rec iter path cmd =
      match path with
      | [] -> ()
      | dir :: path ->
        let file = Filename.concat dir cmd in
        if Sys.file_exists file then begin
          Printf.eprintf "%s is in your PATH. You should clean it !\n%!" file;
          exit 2
        end else iter path cmd
    in
    iter path cmd
  ) [ "ocamlc"; "camlp4"; "ocp-manager"; "opam-manager" ]

(* Add an option "-fix NV" that will remove all packages that have been
   compiled using a wrong version of NV. *)



let action_on_commit st commit =
  Printf.eprintf "action_on_commit %s\n%!" commit;

  let lint = !arg_lint in

  let dirs = st.dirs in

  let switches = Array.map (fun sw ->
    sw.sw_cudf := None; (* universe must have changed for every switch *)
    sw.sw_name) st.sws in

  let c = CheckUpdate.check_commit ~lint ~commit dirs switches in


  StringMap.iter (fun package_name p ->
    match p.package_transitive_checksum with
    | None -> assert false
    | Some (checksum, closure) ->

      let package_dir = Filename.concat dirs.cache_dir package_name in
      if not (Sys.file_exists package_dir) then Unix.mkdir package_dir 0o775;

      CheckCudf.check_installability st checksum package_dir package_name;

      StringMap.iter (fun version_name v ->
        let version_dir = Filename.concat package_dir version_name in
        if not (Sys.file_exists version_dir) then Unix.mkdir version_dir 0o775;
        CheckCudf.check_installability st checksum version_dir version_name;
      ) p.package_versions;

  ) c.packages;

  (* 6/ Load all the dependencies *)

  StringMap.iter (fun _ p ->
    let package_dir = Filename.concat dirs.cache_dir p.package_name in
    p.package_status <- Array.map (fun switch ->
      CheckCudf.status_of_files package_dir p.package_name switch
    ) c.switches;
    StringMap.iter (fun _ v ->
      let version_dir = Filename.concat package_dir v.version_name in
      v.version_status <- Array.map (fun switch ->
        CheckCudf.status_of_files version_dir v.version_name switch
      ) c.switches;
    ) p.package_versions;
  ) c.packages;

  (* 7/ Print an HTML report *)

  CheckHtml.print_commit_report st c;

  c





let arg_import = ref false

let current_dir = Sys.getcwd ()

let cache_dir = Filename.concat current_dir "cache"
let repo_dir = "."
let opam_dir = Filename.concat current_dir ".opam"
let report_dir = Filename.concat current_dir "reports"
let _ =
  let switches = ref [] in
  let arg_list = Arg.align [
    "--no-pull",
    Arg.Clear opam_pull, " Dont pull new versions of opam-repo";
    "--lint",
    Arg.Set arg_lint, " Call opam lint on all modified opam files";
    "--lint-only",
    Arg.Set arg_lint_only, " Loop on opam lint on all modified opam files";
    "--auto-fix",
    Arg.Unit (fun () ->
      auto_fix := true;
      opam_pull := false;
      arg_lint_only := true;
    ), " Fix using lint information";
    "--no-build", Arg.Clear arg_build, " Do not build, generate the report.";
    "--import", Arg.Set arg_import, " Import from directories";
  ] in
  let arg_anon s = switches :=  s :: !switches in
  let arg_usage = "opam-builder [OPTIONS] : backup all archives of an opam-repository" in
  Arg.parse arg_list arg_anon arg_usage;

  let dirs = {
    repo_dir; cache_dir; opam_dir; current_dir; report_dir;
  } in
  if not !arg_import
      && (not (Sys.file_exists "packages") || not (Sys.file_exists ".git"))
  then begin
    Printf.eprintf "opam-archive should be run at the root of an opam-repository clone.\n%!";
    exit 2
  end;

  List.iter (fun dir ->
    if not (Sys.file_exists dir) then Unix.mkdir dir 0o755
  ) [ cache_dir; report_dir ];

  if !arg_lint_only then begin

    let lint = true in
    for_each_new_commit (fun commit ->
      let c = CheckUpdate.check_commit ~lint ~commit dirs [||] in
      let c =
        if !auto_fix then begin
          CheckLint.autofix_packages dirs c;
          CheckUpdate.check_commit ~lint
            ~commit:(commit ^ "-autofix") dirs [||]
        end else
          c
      in
      CheckLint.analyze dirs c;
      CheckLint.export dirs c;

    )

  end else

  if !arg_import then begin
    let state = CheckImport.init !switches in
    while true do
      CheckImport.import state;
      Unix.sleep 60;
    done
  end else begin

    let st = CheckBuild.init dirs !switches in

    for_each_new_commit (fun commit ->

        if command (CopamInstall.opam_cmd st.root "update") then begin

          let c = action_on_commit st commit in
          let commit_file = Filename.concat report_dir (commit ^ ".check") in

          CheckIO.save commit_file c;
          let stats = CheckGraph.analyze st c in

          if !arg_build then CheckBuild.install_popular st c stats;
          CheckBuild.report st c stats;
          CheckBuild.export st c stats;

          CopamIssues.rotate ();
        end else begin
          Printf.eprintf "Error: opam update failed\n%!";
          exit 2
        end;

    )
  end
