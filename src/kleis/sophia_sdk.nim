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
{.compile: sdkSource / "launch_auth/client.c".}
{.compile: sdkSource / "lock_files/records.c".}
{.compile: sdkSource / "lock_files/client.c".}
{.compile: sdkSource / "lock_files/session.c".}
{.compile: sdkSource / "lock_files/revision.c".}
{.compile: sdkSource / "lock_files/image.c".}
{.compile: sdkSource / "lock_files/image_adapter.c".}
{.compile: sdkSource / "image_channel/discovery.c".}
{.compile: sdkSource / "image_channel/packet.c".}
{.compile: sdkSource / "image_channel/records.c".}
{.compile: sdkSource / "image_producer/producer.c".}
{.compile: sdkSource / "image_producer/offers.c".}
{.compile: sdkSource / "image_producer/io.c".}
{.compile: sdkSource / "image_producer/isb.c".}
{.compile: "lock_sdk.c".}
{.compile: "lock_auth.c".}

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
  fd: cint,
  endpointDir: cstring,
  chordCount: uint16,
  keysyms: ptr uint32,
  modifiers: ptr uint16,
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

# Sealed image channel states returned by lockImageChannel.
const
  ImageChannelPending* = 0.cint
  ImageChannelReady* = 1.cint
  ImageChannelClosed* = 2.cint
  # Producer offer states (sophia_ip_offer_state).
  OfferFree* = 0'u32
  OfferBegun* = 1'u32
  OfferRefused* = 2'u32
  OfferAdmitted* = 3'u32
  OfferSent* = 4'u32
  OfferAmbiguous* = 5'u32
  OfferExpired* = 6'u32
  OfferSettled* = 7'u32
  OfferUnknown* = 8'u32

proc lockImageChannel*(h: ptr LockHandle): cint {.importc: "kleis_lock_image_channel".}
proc lockImagePollFd*(h: ptr LockHandle): cint {.importc: "kleis_lock_image_poll_fd".}

proc lockImagePollEvents*(
  h: ptr LockHandle
): cshort {.importc: "kleis_lock_image_poll_events".}

proc lockImageTimeout*(
  h: ptr LockHandle, nowMs: uint64
): int64 {.importc: "kleis_lock_image_timeout".}

proc lockImageDispatch*(
  h: ptr LockHandle, revents: cshort, nowMs: uint64
): cint {.importc: "kleis_lock_image_dispatch".}

proc lockImageBegin*(
  h: ptr LockHandle,
  nowMs, resourceId, resourceGeneration, output, allocation, view: uint64,
  pixels: pointer,
  width, height: uint32,
  offer: var uint64,
): cint {.importc: "kleis_lock_image_begin".}

proc lockImageOffer*(
  h: ptr LockHandle, offer: uint64, state, status, disposition: var uint32
): cint {.importc: "kleis_lock_image_offer".}

proc lockImageForget*(
  h: ptr LockHandle, offer: uint64
): cint {.importc: "kleis_lock_image_forget".}

proc lockImageCancel*(
  h: ptr LockHandle, offer, nowMs: uint64
): cint {.importc: "kleis_lock_image_cancel".}

{.pop.}
