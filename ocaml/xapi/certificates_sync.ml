module D = Debug.Make (struct let name = "certificates_sync" end)

open D
module Unixext = Xapi_stdext_unix.Unixext
module Date = Xapi_stdext_date.Date
open Rresult

let add_certificate_to_db ~__context ~host certificate root_fingerprints =
  Ref.make ()

(* dummy *)

let verify_chain_of_trust cert ca_certs = R.ok true

let is_tls_verification_enabled ~__context = R.ok true

let get_stunnel_certs () =
  let path = !Xapi_globs.stunnel_cert_path in
  try
    Unixext.string_of_file path
    |> Cstruct.of_string
    |> X509.Certificate.decode_pem_multiple
    |> R.reword_error (fun _ ->
           Printf.sprintf "decoding %s failed" path |> R.msg)
  with e -> R.error_msgf "decoding %s failed: %s" path (Printexc.to_string e)

let get_server_cert () =
  Certificates.get_server_certificate ()
  |> Cstruct.of_string
  |> X509.Certificate.decode_pem
  |> R.reword_error (fun _ ->
         Printf.sprintf "decoding server cert failed" |> R.msg)

let is_same ~__context cert_ref cert =
  let cert_hash =
    X509.Certificate.fingerprint Mirage_crypto.Hash.(`SHA256) cert
    |> Certificates.pp_hash
  in
  let ref_hash = Db.Certificate.get_fingerprint ~__context ~self:cert_ref in
  cert_hash = ref_hash

let is_self_signed cert =
  let subject = X509.Certificate.subject cert in
  let issuer = X509.Certificate.issuer cert in
  X509.Distinguished_name.equal subject issuer

let is_valid ~__context cert =
  if is_self_signed cert then (
    info "New server certificate is self signed" ;
    R.ok true
  ) else (
    info "New server certificate is not self signed" ;
    get_stunnel_certs () >>= fun ca_certs ->
    verify_chain_of_trust cert ca_certs >>= fun verified ->
    is_tls_verification_enabled ~__context >>= fun tls_on ->
    match (verified, tls_on) with
    | false, true ->
        error "New server certificate is not valid but TLS requires it" ;
        R.ok false
    | true, true ->
        info "New server certificate is valid as required by TLS" ;
        R.ok true
    | false, false ->
        warn "New server certificate in not valid and TLS not enabled" ;
        R.ok true (* still ok as not required by TLS *)
    | true, false ->
        info "New server certificate is valid but TLS doesn't require it" ;
        R.ok true
  )

let install ~__context ~host cert =
  if is_self_signed cert then
    try
      let pem = X509.Certificate.encode_pem cert |> Cstruct.to_string in
      let hash =
        X509.Certificate.fingerprint Mirage_crypto.Hash.(`SHA256) cert
        |> Certificates.pp_hash
      in
      let ref = add_certificate_to_db ~__context ~host cert [hash] in
      let uuid = Db.Certificate.get_uuid ~__context ~self:ref in
      Certificates.(pool_install CA_Certificate ~__context ~name:uuid ~cert:pem) ;
      R.ok ()
    with e ->
      R.error_msgf "installation of certificate failed: %s"
        (Printexc.to_string e)
  else
    R.ok ()

let update ~__context =
  let host = Helpers.get_localhost ~__context in
  let host_uuid = Helpers.get_localhost_uuid () in
  let cert_refs = Db.Host.get_certificates ~__context ~self:host in
  get_server_cert () >>= fun cert ->
  match cert_refs with
  | [] ->
      info "Host %s has no active server certificate" host_uuid ;
      is_valid ~__context cert >>= fun valid -> install ~__context ~host cert
  | [cert_ref] when is_same ~__context cert_ref cert ->
      info "Active server certificate for host %s is unchanged" host_uuid ;
      R.ok ()
  | [cert_ref] -> (
      info "Server certificate for host %s changed - updating" host_uuid ;
      is_valid ~__context cert >>= function
      | true ->
          install ~__context ~host cert >>= fun () ->
          Db.Certificate.destroy ~__context ~self:cert_ref ;
          R.ok ()
      | false ->
          R.error_msgf "Updated host certificate is invalid"
    )
  | _ ->
      R.error_msgf "Host %s has multiple server certificates" host_uuid
