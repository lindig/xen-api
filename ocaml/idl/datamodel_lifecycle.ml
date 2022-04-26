let prototyped_of_class = function
  | _ ->
      None

let prototyped_of_field = function
  | "Repository", "gpgkey_path" ->
      Some "22.12.0"
  | "pool", "uefi_certificates" ->
      Some "22.17.0-next"
  | _ ->
      None

let prototyped_of_message = function
  | "Repository", "set_gpgkey_path" ->
      Some "22.12.0"
  | _ ->
      None
