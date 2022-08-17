(*
 * Copyright (C) 2006-2011 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
module D = Debug.Make (struct let name = "xapi_vgpu" end)

open D

(* Mutex to prevent duplicate VGPUs being created by accident *)
let m = Mutex.create ()

(* 1. Only device numbers in the range [0,20] are allowed due to space
      limitations on the guest PCI bus.
   2. The guest PCI bus slot will be equal to the device number plus 11.
   3. device = 0 is recognised as a special value to automatically pick the next
      available device number from the allowed range.
*)

let min_valid_vgpu_device = 0

let max_valid_vgpu_device = 20

let range low high =
  let rec aux low high = if low > high then [] else low :: aux (low + 1) high in
  aux low high

let all_valid_devices = range min_valid_vgpu_device max_valid_vgpu_device

let get_valid_device ~__context ~device ~vM ~vGPUs =
  let d = int_of_string device in
  let all_existing_devices =
    List.map
      (fun self -> Db.VGPU.get_device ~__context ~self |> int_of_string)
      vGPUs
  in
  let device_in_use device = List.mem device all_existing_devices in
  if d = 0 then
    try
      List.find (fun d -> not (device_in_use d)) all_valid_devices
      |> string_of_int
    with Not_found ->
      raise Api_errors.(Server_error (vm_pci_bus_full, [Ref.string_of vM]))
  else if device_in_use d then
    raise Api_errors.(Server_error (device_already_exists, [device]))
  else if d >= min_valid_vgpu_device && d <= max_valid_vgpu_device then
    device
  else
    raise Api_errors.(Server_error (invalid_device, [device]))

let create' ~__context ~vM ~gPU_group ~device ~other_config ~_type
    ~powerstate_check ~compatibility_metadata =
  let vgpu = Ref.make () in
  let uuid = Uuid.to_string (Uuid.make_uuid ()) in
  if not (Pool_features.is_enabled ~__context Features.GPU) then
    raise (Api_errors.Server_error (Api_errors.feature_restricted, [])) ;
  if powerstate_check then
    Xapi_vm_lifecycle.assert_initial_power_state_is ~__context ~self:vM
      ~expected:`Halted ;
  (* For backwards compatibility, convert Ref.null into the passthrough type. *)
  let _type =
    if _type = Ref.null then
      Xapi_vgpu_type.find_or_create ~__context Xapi_vgpu_type.passthrough_gpu
    else if Db.is_valid_ref __context _type then
      _type
    else
      raise
        (Api_errors.Server_error
           (Api_errors.invalid_value, ["type"; Ref.string_of _type])
        )
  in
  (* during multiple vgpus creation:
     1. Underlying vgpu_type should support multiple
     2. _type must be listed on the all vgpu_type's compatible lists*)
  let existing = Db.VM.get_VGPUs ~__context ~self:vM in
  let types =
    List.map (fun vgpu -> Db.VGPU.get_type ~__context ~self:vgpu) existing
  in
  let is_in_compatible_lists _type vgpu_type =
    let compatible_lists =
      Db.VGPU_type.get_compatible_types_in_vm ~__context ~self:vgpu_type
    in
    List.mem _type compatible_lists
  in
  if not (List.for_all (is_in_compatible_lists _type) types) then
    raise
      (Api_errors.Server_error
         (Api_errors.vgpu_type_not_compatible, [Ref.string_of _type])
      ) ;
  debug "Creating vGPU %s with metadata: [%s]" (Ref.string_of vgpu)
    (List.map fst compatibility_metadata |> String.concat ":") ;
  Stdext.Threadext.Mutex.execute m (fun () ->
      let device_id = get_valid_device ~__context ~device ~vM ~vGPUs:existing in
      Db.VGPU.create ~__context ~ref:vgpu ~uuid ~vM ~gPU_group ~device:device_id
        ~currently_attached:false ~other_config ~_type ~resident_on:Ref.null
        ~scheduled_to_be_resident_on:Ref.null ~compatibility_metadata
        ~extra_args:"" ~pCI:Ref.null
  ) ;
  debug "VGPU ref='%s' created (VM = '%s', type = '%s')" (Ref.string_of vgpu)
    (Ref.string_of vM) (Ref.string_of _type) ;
  vgpu

(* - create is defined by the autogenerated code, so we keep the same signature for it but add
   a new function create' that will accept extra parameters indicating the desired behaviour.
   - create may be called during VM.import(eg. VM cross pool migration with checkpoints), no need
   to constraint the power state in this case.
*)
let create ~__context ~vM ~gPU_group ~device ~other_config ~_type =
  let powerstate_check = not (Db.VM.get_is_a_snapshot ~__context ~self:vM) in
  create' ~__context ~vM ~gPU_group ~device ~other_config ~_type
    ~powerstate_check ~compatibility_metadata:[]

let destroy ~__context ~self =
  let vm = Db.VGPU.get_VM ~__context ~self in
  if Helpers.is_running ~__context ~self:vm then
    raise
      (Api_errors.Server_error
         ( Api_errors.operation_not_allowed
         , ["vGPU currently attached to a running VM"]
         )
      ) ;
  Db.VGPU.destroy ~__context ~self

let atomic_set_resident_on ~__context ~self ~value = assert false

let copy ~__context ~vm vgpu =
  let all = Db.VGPU.get_record ~__context ~self:vgpu in
  let vgpu =
    create' ~__context ~device:all.API.vGPU_device
      ~gPU_group:all.API.vGPU_GPU_group ~vM:vm
      ~other_config:all.API.vGPU_other_config ~_type:all.API.vGPU_type
      ~powerstate_check:false
      ~compatibility_metadata:all.API.vGPU_compatibility_metadata
  in
  if all.API.vGPU_currently_attached then
    Db.VGPU.set_currently_attached ~__context ~self:vgpu ~value:true ;
  vgpu

let requires_passthrough ~__context ~self =
  let _type = Db.VGPU.get_type ~__context ~self in
  Xapi_vgpu_type.requires_passthrough ~__context ~self:_type
