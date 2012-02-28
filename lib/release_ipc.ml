open Lwt

module type Ops = sig
  type request
  type response

  val string_of_request : request -> string
  val request_of_string : string -> request

  val string_of_response : response -> string
  val response_of_string : string -> response
end

module type S = sig
  type request
  type response

  val read : ?timeout:float
          -> Lwt_unix.file_descr
          -> [> `Data of string | `EOF | `Timeout ] Lwt.t

  val write : Lwt_unix.file_descr -> string -> unit Lwt.t

  val make_request : ?timeout:float
                  -> Lwt_unix.file_descr
                  -> request
                  -> ([`Response of response | `EOF | `Timeout] -> 'a Lwt.t)
                  -> 'a Lwt.t

  val handle_request : Lwt_unix.file_descr
                    -> (request -> response Lwt.t)
                    -> unit Lwt.t
end

module Make (O : Ops) : S
    with type request = O.request and type response = O.response =
struct
  type request = O.request
  type response = O.response

  let read ?timeout fd =
    match_lwt Release_io.read ?timeout fd 1 with
    | `Data b ->
        let siz = Release_bytes.read_byte b in
        Release_io.read ?timeout fd siz
    | other ->
        return other

  let write fd s =
    let siz = String.length s in
    let buf = Buffer.create siz in
    Release_bytes.write_byte siz buf;
    Buffer.add_string buf s;
    Release_io.write fd (Buffer.contents buf)

  let make_request ?timeout fd req handler =
    lwt () = write fd (O.string_of_request req) in
    lwt res = read ?timeout fd in
    handler
      (match res with
      | `Timeout -> `Timeout
      | `EOF -> `EOF
      | `Data resp -> `Response (O.response_of_string resp))

  let handle_request fd handler =
    match_lwt read fd with
    | `Timeout ->
        raise_lwt (Failure "read from slave shouldn't timeout")
    | `EOF ->
        lwt () = Lwt_log.notice "got EOF from slave" in
        Lwt_unix.close fd
    | `Data req ->
        lwt resp = handler (O.request_of_string req) in
        write fd (O.string_of_response resp)
end