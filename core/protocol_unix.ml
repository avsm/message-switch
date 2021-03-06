open Protocol
open Cohttp

let whoami () = Printf.sprintf "%s:%d"
	(Filename.basename Sys.argv.(0)) (Unix.getpid ())

module IO = struct
	type 'a t = 'a
	let ( >>= ) a f = f a
	let (>>) m n = m >>= fun _ -> n

	let return a = a

	let iter = List.iter

	type ic = in_channel
	type oc = out_channel

	let read_line ic =
		try
			let line = input_line ic in
			let last = String.length line - 1 in
			let line = if line.[last] = '\r' then String.sub line 0 last else line in
			Some line
		with _ -> None

	let read_into_exactly ic buf ofs len =
		try
			really_input ic buf ofs len; true
		with _ -> false
	let read_exactly ic len =
		let buf = String.create len in
		read_into_exactly ic buf 0 len >>= function
		| true -> return (Some buf)
		| false -> return None

	let read ic n =
		let buf = String.make n '\000' in
		let actually_read = input ic buf 0 n in
		if actually_read = n
		then buf
		else String.sub buf 0 actually_read

	let write oc x = 
		output_string oc x; flush oc

	let connect port =
		let sockaddr = Unix.ADDR_INET(Unix.inet_addr_of_string "127.0.0.1", port) in
		let fd = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
		let () = Unix.connect fd sockaddr in
		Unix.setsockopt fd Unix.TCP_NODELAY true;
		let ic = Unix.in_channel_of_descr fd in
		let oc = Unix.out_channel_of_descr fd in
		(ic, oc)
end

module Connection = Protocol.Connection(IO)

exception Timeout

module Client = struct
	type 'a response = {
		mutable v: 'a option;
		mutable timed_out: bool;
		m: Mutex.t;
		c: Condition.t;
	}
	let task () = {
		v = None;
		timed_out = false;
		m = Mutex.create ();
		c = Condition.create ();
	}
	let with_lock m f =
		Mutex.lock m;
		try
			let r = f () in
			Mutex.unlock m;
			r
		with e ->
			Mutex.unlock m;
			raise e
	let wakeup_later r x =
		with_lock r.m
			(fun () ->
				r.v <- Some x;
				Condition.signal r.c
			)
	let timeout_later r =
		with_lock r.m
			(fun () ->
				r.timed_out <- true;
				Condition.signal r.c
			)
	let wait r =
		with_lock r.m
			(fun () ->
				while r.v = None && not r.timed_out do
					Condition.wait r.c r.m
				done;
				match r.v, r.timed_out with
				| _, true -> raise Timeout
				| Some x, _ -> x
				| None, false -> assert false
			)

	type t = {
		requests_conn: (IO.ic * IO.oc);
		events_conn: (IO.ic * IO.oc);
		requests_m: Mutex.t;
		wakener: (int, Protocol.Message.t response) Hashtbl.t;
		dest_queue_name: string;
		reply_queue_name: string; 
	}

	let rpc c frame = match Connection.rpc c frame with
		| Error e -> raise e
		| Ok raw -> raw

	let connect port dest_queue_name =
		let token = whoami () in
		let requests_conn = IO.connect port in
		let (_: string) = rpc requests_conn (In.Login token) in
		let events_conn = IO.connect port in
		let (_: string) = rpc events_conn (In.Login token) in

		let wakener = Hashtbl.create 10 in

		Protocol_unix_scheduler.start ();

		let (_ : Thread.t) =
			let rec loop from =
				let timeout = 5. in
				let frame = In.Transfer(from, timeout) in
				let raw = rpc events_conn frame in
				let transfer = Out.transfer_of_rpc (Jsonrpc.of_string raw) in
				match transfer.Out.messages with
				| [] -> loop from
				| m :: ms ->
					List.iter
						(fun (i, m) ->
							let (_: string) = rpc events_conn (In.Ack i) in
							if Hashtbl.mem wakener m.Message.correlation_id
							then wakeup_later (Hashtbl.find wakener m.Message.correlation_id) m;
						) transfer.Out.messages;
					let from = List.fold_left max (fst m) (List.map fst ms) in
					loop from in
			Thread.create loop (-1L) in
		let reply_queue_name = rpc requests_conn (In.Create None) in
		let (_: string) = rpc requests_conn (In.Subscribe reply_queue_name) in
		let (_: string) = rpc requests_conn (In.Create (Some dest_queue_name)) in
		{
			requests_conn = requests_conn;
			events_conn = events_conn;
			requests_m = Mutex.create ();
			wakener = wakener;
			dest_queue_name = dest_queue_name;
			reply_queue_name = reply_queue_name;
		}

	let rpc c ?timeout x =
		let correlation_id = Protocol.fresh_correlation_id () in
		let t = task () in
		Hashtbl.add c.wakener correlation_id t;
		let msg = In.Send(c.dest_queue_name, {
			Message.payload = x;
			correlation_id;
			reply_to = Some c.reply_queue_name
		}) in
		let timer = match timeout with
		| Some timeout ->
			Some (Protocol_unix_scheduler.(one_shot (Delta timeout) "rpc"
				(fun () -> timeout_later t)))
		| None ->
			None in
		let (_: string) = rpc c.requests_conn msg in
		let response = wait t in
		begin match timer with Some x -> Protocol_unix_scheduler.cancel x | None -> () end;
		response.Message.payload
end

module Server = Protocol.Server(IO)
