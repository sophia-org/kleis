## Bindings to the vendored C desktop SDK's lock client, through the flat
## shim in lock_sdk.c. Only the lock files and the generic 9P client are
## compiled in.

import std/os

const sdkSource =
  currentSourcePath().parentDir / ".." / ".." / "vendor" / "sophia-desktop-sdk" /
  "source" / "src"

{.passC: "-I" & sdkSource.}
{.passC: "-I" & currentSourcePath().parentDir.}
{.compile: sdkSource / "nine_p/client.c".}
{.compile: sdkSource / "nine_p/replies.c".}
{.compile: sdkSource / "nine_p/requests.c".}
{.compile: sdkSource / "lock_files/records.c".}
{.compile: sdkSource / "lock_files/client.c".}
{.compile: sdkSource / "lock_files/session.c".}
{.compile: sdkSource / "lock_files/upload.c".}
{.compile: "lock_sdk.c".}

const
  SdkBusy* = 2.cint
  StateBootstrap* = 0.cint
  StateReady* = 1.cint
  StateRefused* = 2.cint
  StateStale* = 3.cint
  StateFailed* = 4.cint
  # Record kinds (spec: sophia-lock-files-v1.kdl).
  KindObjectPublished* = 19'u16
  KindResourceStatus* = 33'u16
  KindResourceReleased* = 34'u16
  KindCandidateOutcome* = 35'u16
  KindFramePermit* = 36'u16
  KindEntry* = 40'u16
  KindChord* = 41'u16
  # Lock phases.
  PhaseUnlocked* = 1'u16
  PhaseLocking* = 2'u16
  PhaseLocked* = 3'u16
  PhaseUnlocking* = 4'u16
  # Resource statuses.
  ResourceAdmitted* = 1'u16
  ResourceAccepted* = 2'u16
  ResourceRejected* = 3'u16
  ResourceCancelled* = 4'u16
  # Candidate statuses.
  CandidatePrepared* = 1'u16
  CandidatePresented* = 2'u16
  CandidateRejected* = 3'u16
  CandidateSuperseded* = 4'u16
  CandidateRevoked* = 5'u16
  # Submission stages (sophia_lc_submission).
  SubmissionRefused* = 4'u32
  ModAlt* = 4'u16

{.push cdecl, header: "lock_sdk.h", raises: [].}

type
  LockHandle* {.importc: "kleis_lock", incompleteStruct.} = object
  LockEvent* {.importc: "kleis_lock_event_t", bycopy.} = object
    kind*: uint16
    sequence*: uint64
    lock_epoch*: uint64
    transaction*: uint64
    allocation*, allocation_generation*: uint64
    demand*, pacing_permit*: uint64
    expires_after_ms*: uint32
    resource_id*, resource_generation*: uint64
    status*, reason*: uint16
    candidate_generation*, output*: uint64
    entry*, empty_after*: uint16
    chord*: uint16
    object_generation*: uint64

  LockAllocation* {.importc: "kleis_lock_allocation_t", bycopy.} = object
    output*, output_generation*, allocation*, allocation_generation*: uint64
    pixel_width*, pixel_height*: uint32

proc lockOpen*(
  fd: cint, chordCount: uint16, keysyms: ptr uint32, modifiers: ptr uint16
): ptr LockHandle {.importc: "kleis_lock_open".}

proc lockFree*(h: ptr LockHandle) {.importc: "kleis_lock_free".}
proc lockService*(h: ptr LockHandle): cint {.importc: "kleis_lock_service".}
proc lockPollEvents*(h: ptr LockHandle): cshort {.importc: "kleis_lock_poll_events".}
proc lockState*(h: ptr LockHandle): cint {.importc: "kleis_lock_state".}
proc lockRemoteError*(h: ptr LockHandle): uint32 {.importc: "kleis_lock_remote_error".}
proc lockEvent*(
  h: ptr LockHandle, e: var LockEvent
): cint {.importc: "kleis_lock_event".}

proc lockConsume*(h: ptr LockHandle): cint {.importc: "kleis_lock_consume".}
proc lockObject*(
  h: ptr LockHandle,
  generation: var uint64,
  phase: var uint16,
  lockEpoch: var uint64,
  count: var uint16,
): cint {.importc: "kleis_lock_object".}

proc lockAllocation*(
  h: ptr LockHandle, index: uint16, a: var LockAllocation
): cint {.importc: "kleis_lock_allocation".}

proc lockLimits*(
  h: ptr LockHandle, uploadSlots: var uint16, maxResourceBytes: var uint64
): cint {.importc: "kleis_lock_limits".}

proc lockDemand*(
  h: ptr LockHandle,
  transaction, lockEpoch, allocation, allocationGeneration, demand: uint64,
): cint {.importc: "kleis_lock_demand".}

proc lockCandidate*(
  h: ptr LockHandle,
  transaction, lockEpoch, output, outputGeneration, allocation, allocationGeneration,
    candidateGeneration, pacingPermit, resourceId, resourceGeneration: uint64,
): cint {.importc: "kleis_lock_candidate".}

proc lockRetire*(
  h: ptr LockHandle, transaction, resourceId, resourceGeneration: uint64
): cint {.importc: "kleis_lock_retire".}

proc lockSubmission*(
  h: ptr LockHandle, stage: var uint32, submitError: var uint32
): cint {.importc: "kleis_lock_submission".}

proc lockSubmitRetry*(h: ptr LockHandle): cint {.importc: "kleis_lock_submit_retry".}
proc lockUploadBegin*(
  h: ptr LockHandle,
  transaction, resourceId, resourceGeneration: uint64,
  width, height: uint32,
  slot: uint16,
): cint {.importc: "kleis_lock_upload_begin".}

proc lockUploadChunk*(
  h: ptr LockHandle, bytes: pointer, count: csize_t
): cint {.importc: "kleis_lock_upload_chunk".}

proc lockUploadReady*(h: ptr LockHandle): cint {.importc: "kleis_lock_upload_ready".}
proc lockUploadPending*(
  h: ptr LockHandle
): cint {.importc: "kleis_lock_upload_pending".}

proc lockUploadEnd*(h: ptr LockHandle): cint {.importc: "kleis_lock_upload_end".}
proc lockUploadCancel*(h: ptr LockHandle): cint {.importc: "kleis_lock_upload_cancel".}

{.pop.}
