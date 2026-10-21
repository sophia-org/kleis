## The lock provider loop: one Sophia lock connection, the screens it grants,
## and what each shows. Sophia starts kleis in a sandbox with no HOME; the
## socket and the config file arrive in SOPHIA_LOCK_9P_SOCKET and
## SOPHIA_LOCK_CONFIG. When the connection ends (refused, revoked or failed)
## kleis exits nonzero and Sophia starts a replacement under a fresh epoch.

import std/[monotimes, nativesockets, net, options, os, posix]

import ./cli
import ./config
import ./matrix_worker
import ./presenter
import ./sophia_sdk
import ./ui

const
  AltB = 0x62'u32 ## keysym b; registered first, so it is BlankChord
  SubmissionStaged = 1'u32
  SubmissionCustodied = 3'u32
  RetryAfterMs = 8'i64
  ProducerAccepted = 1'u32
  ProducerRejected = 2'u32
  ProducerCancelled = 3'u32

proc nowMs(): int64 =
  getMonoTime().ticks div 1_000_000

type Provider = object
  handle: ptr LockHandle
  ui: Ui
  presenter: Presenter
  worker: MatrixWorker
  opts: Options
  lockGeneration: uint64
  lockDrawn: uint64 ## the lock epoch ui last started for
  pending: Action ## the record the SDK holds, until custody or refusal
  ## The live sealed image offer, its resource, and the readiness the
  ## last poll saw on the producer socket.
  imageOffer: uint64
  imageResource: uint64
  imageRevents: cshort
  ## A worker slot is borrowed until its pixels are copied into the
  ## sealed source (or the begin is refused). Topology and view changes
  ## cannot free it before then.
  lease: FrameLease
  cancelRequested: bool
  lastRetryAt: int64

proc fail(message: string) =
  raise newException(OSError, message)

proc syncView(p: var Provider) =
  let view = p.ui.view
  let generation = p.worker.setView(view)
  p.presenter.setView(generation, view.kind == vkMatrix)

proc readLock(p: var Provider) =
  var generation, lockEpoch: uint64
  var phase, count: uint16
  if p.handle.lockObject(generation, phase, lockEpoch, count) == 0 or
      generation == p.lockGeneration:
    return
  p.lockGeneration = generation
  let drawing = phase in {PhaseLocking, PhaseLocked}
  var allocations: seq[Allocation]
  if drawing:
    for i in 0'u16 ..< count:
      var a: LockAllocation
      if p.handle.lockAllocation(i, a) != 0:
        allocations.add Allocation(
          output: a.output,
          outputGeneration: a.output_generation,
          allocation: a.allocation,
          allocationGeneration: a.allocation_generation,
          width: int(a.pixel_width),
          height: int(a.pixel_height),
        )
  if drawing and lockEpoch != p.lockDrawn:
    p.ui.lockStarted(nowMs())
    p.lockDrawn = lockEpoch
  p.presenter.setLock(drawing, lockEpoch, allocations)
  var targets: seq[MatrixTarget]
  for a in allocations:
    targets.add MatrixTarget(allocation: a.allocation, width: a.width, height: a.height)
  p.worker.setTargets(targets)
  p.syncView()

proc reportBlocked(p: Provider, before: openArray[bool], cause: string) =
  ## One line per output the presenter just blocked (t308): it stays blocked,
  ## drawing nothing new, until the next lock object.
  for a in p.presenter.newlyBlocked(before):
    stderr.writeLine(
      "kleis: output " & $a.output & " (allocation " & $a.allocation & " generation " &
        $a.allocationGeneration & ") blocked after " & cause &
        "; waiting for a new lock object"
    )

proc settlePending(p: var Provider): bool

proc drainEvents(p: var Provider): bool =
  var e: LockEvent
  for _ in 0 ..< 64:
    # Service and consume can decode a Submitted immediately before the
    # next visible event. Apply its custody before its permit or outcome;
    # otherwise the presenter is still in the previous stage and drops it.
    result = p.settlePending() or result
    if p.handle.lockEvent(e) == 0:
      break
    result = true
    let now = nowMs()
    let before = p.ui.view
    case e.kind
    of KindObjectPublished:
      p.readLock()
    of KindResourceStatus:
      # An image offer's Accepted is only custody progress: the
      # presenter hears status 2 from the producer once the source is
      # released (Settled, disposition 1). A rejection still blocks.
      if p.imageOffer != 0 and e.resource_id == p.imageResource and
          e.status == ResourceAccepted:
        discard
      elif e.status == ResourceRejected:
        let blocked = p.presenter.blockedFlags()
        p.presenter.uploadStatus(e.resource_id, e.status)
        p.reportBlocked(blocked, "a rejected upload")
      else:
        p.presenter.uploadStatus(e.resource_id, e.status)
    of KindCandidateOutcome:
      p.presenter.outcome(e.allocation, e.candidate_generation, e.status)
    of KindFramePermit:
      p.presenter.permit(
        e.allocation, e.allocation_generation, e.demand, e.pacing_permit
      )
    of KindEntry:
      if e.entry in 1'u16 .. 7'u16:
        p.ui.entry(LockEntry(e.entry), e.empty_after != 0, now)
    of KindChord:
      p.ui.chord(e.chord, now)
    else:
      discard
    if p.ui.view != before:
      p.syncView()
    if p.handle.lockConsume() != 0:
      fail("the lock connection failed")

proc settlePending(p: var Provider): bool =
  ## Retry image and cancellation submissions as well as presenter records.
  var stage, error: uint32
  discard p.handle.lockSubmission(stage, error)
  if stage == SubmissionStaged and nowMs() - p.lastRetryAt >= RetryAfterMs:
    p.lastRetryAt = nowMs()
    result = p.handle.lockSubmitRetry() == 0
  if p.pending.kind == akNone:
    return
  if stage == SubmissionCustodied:
    p.presenter.applied(p.pending)
    p.pending = Action()
    result = true
  elif stage == SubmissionRefused:
    let blocked = p.presenter.blockedFlags()
    p.presenter.refused(p.pending)
    p.reportBlocked(blocked, "a refused record")
    p.pending = Action()
    result = true

proc driveUpload(p: var Provider): bool =
  ## Settle the live sealed offer. The presenter hears Accepted only
  ## once the producer reports Settled with disposition 1 (Retained);
  ## a cancelled offer settles with disposition 4. Nothing here ever
  ## retries a byte upload: there is none.
  if p.imageOffer == 0:
    if p.presenter.cancelUpload:
      p.presenter.uploadEnded()
      p.cancelRequested = false
      result = true
    return
  if p.presenter.cancelUpload and not p.cancelRequested:
    if p.handle.lockImageCancel(p.imageOffer, uint64(nowMs())) == 0:
      p.cancelRequested = true
      result = true
    # Accepted may already have won the race; still inspect settlement.
  var state, status, disposition: uint32
  if p.handle.lockImageOffer(p.imageOffer, state, status, disposition) != 0:
    fail("the image offer vanished before settlement")
  case state
  of OfferSettled:
    let resource = p.imageResource
    if p.handle.lockImageForget(p.imageOffer) != 0:
      fail("a settled image offer could not be forgotten")
    p.imageOffer = 0
    p.imageResource = 0
    p.cancelRequested = false
    if status == ProducerCancelled and disposition == 4:
      p.presenter.uploadStatus(resource, ResourceCancelled)
    elif status == ProducerAccepted and disposition == 1:
      p.presenter.uploadStatus(resource, ResourceAccepted)
    elif status == ProducerRejected and disposition == 3:
      let blocked = p.presenter.blockedFlags()
      p.presenter.uploadStatus(resource, ResourceRejected)
      p.reportBlocked(blocked, "a rejected image")
    else:
      fail("the image settled without Accepted and Settled disposition 1")
    result = true
  of OfferAmbiguous, OfferExpired, OfferUnknown:
    fail("the image transfer ended without settlement")
  of OfferRefused:
    let resource = p.imageResource
    discard p.handle.lockImageForget(p.imageOffer)
    p.imageOffer = 0
    p.imageResource = 0
    p.cancelRequested = false
    let blocked = p.presenter.blockedFlags()
    p.presenter.uploadStatus(resource, ResourceRejected)
    p.reportBlocked(blocked, "an image offer that ended before settlement")
    result = true
  else:
    discard

proc act(p: var Provider): bool =
  if p.pending.kind != akNone:
    return
  var a = p.presenter.next()
  let lockEpoch = p.presenter.lockEpoch
  var r: cint
  case a.kind
  of akNone:
    return
  of akRetire:
    r = p.handle.lockRetire(a.transaction, a.resource, 1)
  of akDemand:
    let o = p.presenter.outputs[a.index].alloc
    r = p.handle.lockDemand(
      a.transaction, lockEpoch, o.allocation, o.allocationGeneration, a.demand
    )
  of akCandidate:
    let o = p.presenter.outputs[a.index]
    r = p.handle.lockCandidate(
      a.transaction, lockEpoch, o.alloc.output, o.alloc.outputGeneration,
      o.alloc.allocation, o.alloc.allocationGeneration, a.candidateGeneration, o.permit,
      a.resource, 1,
    )
  of akUpload:
    let o = p.presenter.outputs[a.index].alloc
    if p.imageOffer != 0:
      return
    # No image moves before ChannelReady; a closed channel is a
    # startup/session failure, never a byte-upload fallback.
    case p.handle.lockImageChannel()
    of ImageChannelClosed:
      fail("the sealed image channel is unavailable")
    of ImageChannelReady:
      discard
    else:
      return
    let frame = p.worker.acquire(o.allocation)
    if frame.isNone:
      p.presenter.noFrame(a.index)
      return true
    p.lease = frame.get()
    if p.lease.width != o.width or p.lease.height != o.height:
      p.worker.release(p.lease)
      p.presenter.noFrame(a.index)
      return true
    a.viewGeneration = p.lease.viewGeneration
    a.animation = p.ui.view.kind == vkMatrix
    var offer: uint64
    r = p.handle.lockImageBegin(
      uint64(nowMs()),
      a.resource,
      1,
      o.output,
      o.allocation,
      a.viewGeneration,
      p.lease.pixels,
      uint32(o.width),
      uint32(o.height),
      offer,
    )
    if r == 0:
      # The sealed source now owns a copy of the frame.
      p.imageOffer = offer
      p.imageResource = a.resource
      p.worker.release(p.lease)
    else:
      p.worker.release(p.lease, retry = r == SdkBusy)

  if r == 0:
    p.pending = a
    result = true
  elif r != SdkBusy:
    fail("a lock record could not be submitted")

proc timeout(p: Provider, now: int64): cint =
  var deadline = high(int64)
  let ui = p.ui.nextDeadline
  if ui >= 0:
    deadline = min(deadline, ui)
  var stage, error: uint32
  discard p.handle.lockSubmission(stage, error)
  if stage == SubmissionStaged:
    deadline = min(deadline, p.lastRetryAt + RetryAfterMs)
  let imageDue = p.handle.lockImageTimeout(uint64(now))
  if imageDue >= 0:
    deadline = min(deadline, now + imageDue)
  if deadline == high(int64):
    -1.cint
  else:
    cint(clamp(deadline - now, 0'i64, int64(high(cint))))

proc runProvider*(opts: var Options) =
  let socketPath = getEnv("SOPHIA_LOCK_9P_SOCKET")
  if socketPath.len == 0:
    raise
      newException(ValueError, "SOPHIA_LOCK_9P_SOCKET is not set; Sophia starts kleis")
  let configPath = getEnv("SOPHIA_LOCK_CONFIG")
  if configPath.len > 0:
    opts.applyConfigFile(configPath)
  let socket = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
  socket.connectUnix(socketPath)
  let fd = socket.getFd()
  fd.setBlocking(false)
  var keysyms = [AltB]
  var modifiers = [ModAlt]
  var p = Provider(opts: opts, presenter: initPresenter())
  let endpointDir = socketPath.parentDir
  p.handle =
    lockOpen(cint(fd), endpointDir.cstring, 1, addr keysyms[0], addr modifiers[0])
  if p.handle.isNil:
    fail("the lock client could not start")
  p.ui = initUi(opts, nowMs())
  p.worker = startMatrixWorker(matrixWorkerConfig(opts), p.ui.view)
  p.syncView()
  defer:
    # Dispose the wire before returning borrowed storage to the worker.
    socket.close()
    p.handle.lockFree()
    p.worker.release(p.lease)
    p.worker.stop()
  while true:
    if p.handle.lockService() != 0:
      case p.handle.lockState()
      of StateRefused:
        fail("Sophia refused the lock provider negotiation")
      of StateStale:
        fail("Sophia ended this lock connection")
      else:
        fail("the lock connection failed (error " & $p.handle.lockRemoteError() & ")")
    if p.handle.lockImageDispatch(p.imageRevents, uint64(nowMs())) != 0:
      fail("the sealed image channel failed")
    p.imageRevents = 0
    var progressed = p.drainEvents()
    let now = nowMs()
    let before = p.ui.view
    p.ui.tick(now)
    if p.ui.view != before:
      p.syncView()
    progressed = p.settlePending() or progressed
    progressed = p.driveUpload() or progressed
    # At most one choice per output if the first has no worker frame ready.
    for _ in 0 ..< max(p.presenter.outputs.len, 1):
      progressed = p.act() or progressed
      if p.pending.kind != akNone:
        break
    # SDK calls above stage local work. Service it before sleeping; do not
    # decode events in a second service call and then sleep with them held.
    if progressed:
      continue
    let imageFd = p.handle.lockImagePollFd()
    var fds = [
      TPollfd(fd: cint(fd), events: p.handle.lockPollEvents()),
      TPollfd(fd: p.worker.readyFd(), events: POLLIN),
      TPollfd(
        fd: imageFd,
        events:
          if imageFd >= 0:
            p.handle.lockImagePollEvents()
          else:
            0'i16,
      ),
    ]
    discard poll(addr fds[0], 3, p.timeout(nowMs()))
    if (fds[1].revents and POLLIN) != 0:
      p.worker.clearReady()
      p.presenter.markDirty()
    if imageFd >= 0:
      p.imageRevents = fds[2].revents
