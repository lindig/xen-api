(*
   Copyright (C) Citrix Systems Inc.

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU Lesser General Public License as published
   by the Free Software Foundation; version 2.1 only. with the special
   exception on linking described in file LICENSE.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU Lesser General Public License for more details.
 *)

val create :
  __context:Context.t -> vM:[`VM] API.Ref.t -> is_unique:bool -> [`VTPM] Ref.t

val import :
  __context:Context.t -> vM:[`VM] API.Ref.t -> is_unique:bool -> [`VTPM] Ref.t

val assert_no_vtpm_associated : __context:Context.t -> [`VM] API.Ref.t -> unit

val copy :
  __context:Context.t -> vM:[`VM] Ref.t -> [`VTPM] Ref.t -> [`VTPM] Ref.t

val destroy : __context:Context.t -> self:[`VTPM] Ref.t -> unit

val get_contents : __context:Context.t -> self:[`VTPM] Ref.t -> string

val set_contents :
  __context:Context.t -> self:[`VTPM] Ref.t -> contents:string -> unit

val update_allowed_operations :
  __context:Context.t -> self:[`VTPM] API.Ref.t -> unit
