## Which lock-file record kleis sends next, for every output Sophia granted.
##
## Pure: the provider loop feeds it the lock object and events, asks it for
## one action, performs it through the SDK and reports whether the server took
## it. Per output the pipeline is: render and upload a fresh resource; once it
## is whole, ask for a frame (FrameDemand); offer it the moment the permit
## arrives, since permits expire within 250 ms and an upload can take longer;
## on Presented, retire the image it replaced. An output holds at most two
## live resources: the one shown and the next. Frames are coalesced, never
## queued: a change while an output is busy marks it dirty for the next round.

type
  Allocation* = object
    output*, outputGeneration*, allocation*, allocationGeneration*: uint64
    width*, height*: int

  Stage* = enum
    stIdle ## nothing in flight; `ready` may hold a whole image
    stUploading ## the upload of `uploading` is under way
    stDemanded ## a FrameDemand for `ready` is standing
    stPermitted ## a permit arrived; the candidate goes next
    stOffered ## a candidate for `ready` awaits its outcome

  Output* = object
    alloc*: Allocation
    stage*: Stage
    dirty*: bool
    frameAvailable*: bool
    animation*: bool
    viewGeneration*: uint64
    blocked*: bool ## the server refused a record; wait for a new lock object
    shown*, ready*, uploading*: uint64
    demand*, permit*, candidateGeneration*: uint64

  ActionKind* = enum
    akNone
    akRetire
    akCandidate
    akDemand
    akUpload

  Action* = object
    kind*: ActionKind
    index*: int
    target*: Allocation
    lockEpoch*, viewGeneration*: uint64
    animation*: bool
    resource*: uint64
    transaction*: uint64
    demand*, candidateGeneration*: uint64

  Presenter* = object
    drawing*: bool
    lockEpoch*: uint64
    outputs*: seq[Output]
    retiring*: seq[uint64]
    uploadCursor: int
    viewGeneration*: uint64
    animating*: bool
    cancelUpload*: bool ## the upload's output went away; cancel it
    nextTransaction*, nextResource*, nextDemand*, nextCandidate*: uint64

proc initPresenter*(): Presenter =
  Presenter(
    animating: true,
    nextTransaction: 1,
    nextResource: 1,
    nextDemand: 1,
    nextCandidate: 1,
  )

proc mint(counter: var uint64): uint64 =
  result = counter
  inc counter

proc retireOutput(p: var Presenter, o: Output) =
  for id in [o.shown, o.ready]:
    if id != 0:
      p.retiring.add id
  if o.uploading != 0:
    p.cancelUpload = true

proc find(p: Presenter, alloc: Allocation): int =
  for i, o in p.outputs:
    if o.alloc == alloc:
      return i
  -1

proc setLock*(
    p: var Presenter,
    drawing: bool,
    lockEpoch: uint64,
    allocations: openArray[Allocation],
) =
  ## A new lock object. Outputs whose allocation it no longer grants are
  ## retired; a new lock epoch voids anything offered or permitted.
  let epochChanged = lockEpoch != p.lockEpoch
  var kept: seq[Output]
  for o in p.outputs:
    if drawing and o.alloc in allocations:
      var o = o
      o.blocked = false
      o.dirty = true
      if epochChanged and o.stage in {stDemanded, stPermitted, stOffered}:
        o.stage = stIdle
        o.permit = 0
      kept.add o
    else:
      p.retireOutput(o)
  if drawing:
    for a in allocations:
      var present = false
      for o in kept:
        if o.alloc == a:
          present = true
      if not present:
        kept.add Output(alloc: a, dirty: true, frameAvailable: true)
  p.outputs = kept
  if kept.len > 0:
    p.uploadCursor = p.uploadCursor mod kept.len
  p.drawing = drawing
  p.lockEpoch = lockEpoch

proc markDirty*(p: var Presenter) =
  for o in p.outputs.mitems:
    o.dirty = true
    o.frameAvailable = true

proc noFrame*(p: var Presenter, index: int) =
  ## No ready worker slot: do not keep choosing this output until a wake.
  p.outputs[index].frameAvailable = false

proc setView*(p: var Presenter, generation: uint64, animation: bool) =
  ## Semantic changes supersede rain, not an already started feedback color.
  ## Repeated edits coalesce while that color finishes, so typing cannot keep
  ## cancelling every frame. Ordinary animation ticks use markDirty only.
  if generation == p.viewGeneration:
    return
  p.viewGeneration = generation
  p.animating = animation
  p.markDirty()
  for o in p.outputs.mitems:
    if o.animation and o.viewGeneration != generation:
      if o.stage == stUploading:
        p.cancelUpload = true
      elif o.stage in {stIdle, stDemanded, stPermitted} and o.ready != 0:
        p.retiring.add o.ready
        o.ready = 0
        o.permit = 0
        o.stage = stIdle

proc uploadOwner*(p: Presenter): int =
  for i, o in p.outputs:
    if o.stage == stUploading:
      return i
  -1

proc next*(p: var Presenter): Action =
  ## The one record to send now, by urgency: a permitted candidate before
  ## its permit lapses, then retirements that free budget, then demands, then
  ## a new upload. akNone when there is nothing to do.
  for i, o in p.outputs:
    if o.stage == stPermitted:
      return Action(
        kind: akCandidate,
        index: i,
        target: o.alloc,
        lockEpoch: p.lockEpoch,
        resource: o.ready,
        transaction: p.nextTransaction,
        candidateGeneration: p.nextCandidate,
      )
  if p.retiring.len > 0:
    return
      Action(kind: akRetire, resource: p.retiring[0], transaction: p.nextTransaction)
  if not p.drawing:
    return
  for i, o in p.outputs:
    # A whole image is always offered, even when a newer frame is due: an
    # upload can outlast the Matrix tick, and dropping every image that
    # arrives behind one would never show any.
    if o.stage == stIdle and o.ready != 0 and not o.blocked:
      return Action(
        kind: akDemand,
        index: i,
        target: o.alloc,
        lockEpoch: p.lockEpoch,
        transaction: p.nextTransaction,
        demand: p.nextDemand,
      )
  if p.uploadOwner() < 0 and not p.cancelUpload:
    for step in 0 ..< p.outputs.len:
      let i = (p.uploadCursor + step) mod p.outputs.len
      let o = p.outputs[i]
      if o.stage == stIdle and o.ready == 0 and o.dirty and o.frameAvailable and
          not o.blocked:
        return Action(
          kind: akUpload,
          index: i,
          target: o.alloc,
          lockEpoch: p.lockEpoch,
          resource: p.nextResource,
          viewGeneration: p.viewGeneration,
          animation: p.animating,
          transaction: p.nextTransaction,
        )

proc applied*(p: var Presenter, a: Action) =
  ## The server took the record `a` sent.
  discard p.nextTransaction.mint()
  let index =
    if a.lockEpoch == p.lockEpoch:
      p.find(a.target)
    else:
      -1
  if a.kind in {akUpload, akDemand, akCandidate} and index < 0:
    case a.kind
    of akUpload:
      discard p.nextResource.mint()
      p.cancelUpload = true
    of akDemand:
      discard p.nextDemand.mint()
    of akCandidate:
      discard p.nextCandidate.mint()
    else:
      discard
    return
  case a.kind
  of akNone:
    discard
  of akRetire:
    p.retiring.delete(0)
  of akCandidate:
    discard p.nextCandidate.mint()
    p.outputs[index].stage = stOffered
    p.outputs[index].candidateGeneration = a.candidateGeneration
    p.outputs[index].permit = 0
  of akDemand:
    discard p.nextDemand.mint()
    p.outputs[index].stage = stDemanded
    p.outputs[index].demand = a.demand
  of akUpload:
    discard p.nextResource.mint()
    p.outputs[index].stage = stUploading
    p.outputs[index].uploading = a.resource
    p.outputs[index].dirty = a.viewGeneration != p.viewGeneration
    p.outputs[index].animation = a.animation
    p.outputs[index].viewGeneration = a.viewGeneration
    p.uploadCursor = (index + 1) mod p.outputs.len
    if a.animation and a.viewGeneration != p.viewGeneration:
      p.cancelUpload = true

proc refused*(p: var Presenter, a: Action) =
  ## The server refused the record outright: nothing was journaled. The
  ## transaction is spent; the output waits for a new lock object.
  discard p.nextTransaction.mint()
  let index =
    if a.lockEpoch == p.lockEpoch:
      p.find(a.target)
    else:
      -1
  if a.kind in {akUpload, akDemand, akCandidate} and index < 0:
    return
  case a.kind
  of akRetire:
    p.retiring.delete(0)
  of akCandidate:
    p.outputs[index].stage = stIdle
    p.outputs[index].permit = 0
  of akDemand, akUpload:
    p.outputs[index].blocked = true
  of akNone:
    discard

proc uploadStatus*(p: var Presenter, resource: uint64, status: uint16) =
  ## ResourceStatus for an upload: 1 admitted, 2 accepted, 3 rejected,
  ## 4 cancelled.
  for o in p.outputs.mitems:
    if o.stage == stUploading and o.uploading == resource:
      case status
      of 2:
        if p.cancelUpload:
          p.retiring.add resource
          o.dirty = true
        else:
          o.ready = resource
        o.uploading = 0
        o.stage = stIdle
        p.cancelUpload = false
      of 3, 4:
        o.uploading = 0
        o.stage = stIdle
        p.cancelUpload = false
        o.dirty = true
        if status == 3:
          o.blocked = true
      else:
        discard
      return
  # The upload's output went away while it was in flight.
  if status == 2:
    p.retiring.add resource
  if status in {2'u16, 3'u16, 4'u16}:
    p.cancelUpload = false

proc uploadEnded*(p: var Presenter) =
  ## The SDK finished an upload whose output went away.
  p.cancelUpload = false

proc permit*(
    p: var Presenter, allocation, allocationGeneration, demand, pacingPermit: uint64
) =
  for o in p.outputs.mitems:
    if o.alloc.allocation == allocation and
        o.alloc.allocationGeneration == allocationGeneration and o.stage == stDemanded and
        o.demand == demand:
      o.stage = stPermitted
      o.permit = pacingPermit
      return

proc outcome*(
    p: var Presenter, allocation, candidateGeneration: uint64, status: uint16
) =
  ## 1 prepared, 2 presented, 3 rejected, 4 superseded, 5 revoked.
  for o in p.outputs.mitems:
    if o.alloc.allocation == allocation and o.stage == stOffered and
        o.candidateGeneration == candidateGeneration:
      case status
      of 2:
        if o.shown != 0:
          p.retiring.add o.shown
        o.shown = o.ready
        o.ready = 0
        o.stage = stIdle
      of 3, 4, 5:
        # The image is still whole: offer it again, or a newer one.
        o.stage = stIdle
      else:
        discard
      return
