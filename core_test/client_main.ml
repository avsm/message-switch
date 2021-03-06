open Cohttp_lwt_unix
open Lwt
open Protocol
open Protocol_lwt

let port = ref 8080
let name = ref "server"
let payload = ref "hello"
let timeout = ref None

let main () =
	lwt c = Client.connect !port !name in
	let counter = ref 0 in
	let one () =
		incr counter;
		lwt x = Client.rpc c !payload in
		return () in
	let start = Unix.gettimeofday () in
	lwt () = match !timeout with
	| None -> one ()
	| Some t ->
		while_lwt (Unix.gettimeofday () -. start < t) do
			one ()
		done in
	let t = Unix.gettimeofday () -. start in
	Printf.printf "Finished %d RPCs in %.02f\n" !counter t;
	return ()

let _ =
	Arg.parse [
		"-port", Arg.Set_int port, (Printf.sprintf "port broker listens on (default %d)" !port);
		"-name", Arg.Set_string name, (Printf.sprintf "name to send message to (default %s)" !name);
		"-payload", Arg.Set_string payload, (Printf.sprintf "payload of message to send (default %s)" !payload);
		"-secs", Arg.String (fun x -> timeout := Some (float_of_string x)), (Printf.sprintf "number of seconds to repeat the same message for (default %s)" (match !timeout with None -> "None" | Some x -> string_of_float x));
	] (fun x -> Printf.fprintf stderr "Ignoring unexpected argument: %s" x)
		"Send a message to a name, optionally waiting for a response";

	Lwt_unix.run (main ()) 
