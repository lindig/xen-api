open Fe_debug

let setup sock cmdargs id_to_fd_map syslog_stdout redirect_stderr_to_stdout env
    =
  let fd_sock_path =
    Printf.sprintf "%s/fd_%s" Forkhelpers.temp_dir_server
      Uuidx.(to_string (make ()))
  in
  let fd_sock = Fecomms.open_unix_domain_sock () in
  Xapi_stdext_unix.Unixext.unlink_safe fd_sock_path ;
  debug "About to bind to %s" fd_sock_path ;
  Unix.bind fd_sock (Unix.ADDR_UNIX fd_sock_path) ;
  Unix.listen fd_sock 5 ;
  debug "bound, listening" ;
  let result = Unix.fork () in
  if result = 0 then (
    debug "Child here!" ;
    let result2 = Unix.fork () in
    if result2 = 0 then (
      debug "Grandchild here!" ;
      (* Grandchild *)
      let state =
        {
          Child.cmdargs
        ; env
        ; id_to_fd_map
        ; syslog_stdout=
            {
              Child.enabled= syslog_stdout.Fe.enabled
            ; Child.key= syslog_stdout.Fe.key
            }
        ; redirect_stderr_to_stdout
        ; ids_received= []
        ; fd_sock2= None
        ; finished= false
        }
      in
      Child.run state sock fd_sock fd_sock_path
    ) else (* Child *)
      exit 0
  ) else (
    (* Parent *)
    debug "Waiting for process %d to exit" result ;
    ignore (Unix.waitpid [] result) ;
    Unix.close fd_sock ;
    Some {Fe.fd_sock_path}
  )

let _ =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore ;

  let test_path =
    Option.bind (Sys.getenv_opt "FE_TEST") (fun _ ->
        Sys.getenv_opt "XDG_RUNTIME_DIR"
    )
  in

  let runtime_path = Option.value ~default:"/var" test_path in
  let main_sock =
    Fecomms.open_unix_domain_sock_server (runtime_path ^ "/xapi/forker/main")
  in
  Xapi_stdext_unix.Unixext.mkdir_rec Forkhelpers.temp_dir_server 0o755 ;

  let module Daemon = Xapi_stdext_unix.Unixext.Daemon in
  if Daemon.systemd_booted () && not (Daemon.systemd_notify Daemon.State.Ready)
  then
    warn "Sending systemd notification failed at %s" __LOC__ ;

  (* At this point the init.d script should return and we are listening on our socket. *)
  while true do
    try
      let sock, _addr = Unix.accept main_sock in
      reset () ;
      let cmd = Fecomms.read_raw_rpc sock in
      match cmd with
      | Ok (Fe.Setup s) -> (
          let result =
            setup sock s.Fe.cmdargs s.Fe.id_to_fd_map s.Fe.syslog_stdout
              s.Fe.redirect_stderr_to_stdout s.Fe.env
          in
          match result with
          | Some response ->
              ( try Fecomms.write_raw_rpc sock (Fe.Setup_response response)
                with Unix.Unix_error (Unix.EPIPE, _, _) -> ()
              ) ;
              Unix.close sock
          | _ ->
              ()
        )
      | Ok msg ->
          debug "Ignoring invalid message (%s)" (Fe.ferpc_to_string msg) ;
          Unix.close sock
      | Error msg ->
          debug "Ignoring invalid message (%s)" msg ;
          Unix.close sock
    with e -> debug "Caught exception at top level: %s" (Printexc.to_string e)
  done
