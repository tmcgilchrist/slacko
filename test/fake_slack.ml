(* A (currently pretty useless) fake slack implementation to run tests
   against. *)
open Lwt
open Cohttp
open Cohttp_lwt_unix


let channels_json = Yojson.Safe.from_file "channels.json"
let new_channel_json = Yojson.Safe.from_file "new_channel.json"
let authed_json = Yojson.Safe.from_file "authed.json"

let json_fields = function
  | `Assoc fields -> fields
  | _ -> failwith "Can't parse test json."


let resp ok fields =
  let body = `Assoc (("ok", `Bool ok) :: fields) |> Yojson.Safe.to_string in
  Server.respond_string ~status:`OK ~body ()

let ok_resp fields = resp true fields

let err_resp err fields = resp false (("error", `String err) :: fields)

let get_arg_opt arg req =
  Uri.get_query_param (Request.uri req) arg

let get_arg_default arg default req =
  match get_arg_opt arg req with
  | Some x -> x
  | None -> default

let get_arg arg req =
  match get_arg_opt arg req with
  | Some x -> x
  | None -> failwith @@ "Mandatory arg " ^ arg ^ " not given."

let check_auth f req body =
  match get_arg "token" req with
  | "xoxp-testtoken" -> f req body
  | _ -> err_resp "invalid_auth" []

(* Request handlers *)

let bad_path req body =
  let path = req |> Request.uri |> Uri.path in
  err_resp "unknown_method" ["req_method", `String path]

let api_test req body =
  let args = req |> Request.uri |> Uri.query in
  let field_of_arg (k, v) = k, `String (List.hd v) in
  let fields = match args with
    | [] -> []
    | args -> ["args", `Assoc (List.map field_of_arg args)]
  in
  match Uri.get_query_param (Request.uri req) "error" with
  | None -> ok_resp fields
  | Some err -> err_resp err fields

let auth_test req body =
  ok_resp (json_fields authed_json)

let channels_archive req body =
  match get_arg "channel" req with
  | "C3UK9TS3C" -> err_resp "cant_archive_general" []
  | "C3XTJPLFL" -> ok_resp []
  | "C3XTHDCTC" -> err_resp "already_archived" []
  | _ -> err_resp "channel_not_found" []

let channels_create req body =
  match get_arg "name" req with
  | "#general" | "#random" -> err_resp "name_taken" []
  | "#new_channel" | _ -> ok_resp ["channel", new_channel_json]

let channels_list req body =
  ok_resp ["channels", channels_json]

(* Dispatcher, etc. *)

let server ?(port=7357) ~stop () =
  let callback _conn req body =
    let handler = match req |> Request.uri |> Uri.path with
      | "/api/api.test" -> api_test
      | "/api/auth.test" -> check_auth auth_test
      | "/api/channels.archive" -> check_auth channels_archive
      | "/api/channels.create" -> check_auth channels_create
      | "/api/channels.list" -> check_auth channels_list
      | _ -> bad_path
    in
    handler req body
  in
  Server.create ~mode:(`TCP (`Port port)) ~stop (Server.make ~callback ())

let with_fake_slack f =
  let stop, wake = wait () in
  let srv = server ~stop () in
  let stop_server result = wakeup wake (); srv in
  finalize f stop_server
