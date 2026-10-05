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
  chunkGiven: bool
  ## A worker slot is borrowed until the SDK has drained all issued writes,
  ## including cancel/rejection. Topology and view changes cannot free it.
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

proc drainEvents(p: var Provider): bool =
  var e: LockEvent
  for _ in 0 ..< 64:
    if p.handle.lockEvent(e) == 0:
      break
    result = true
    let now = nowMs()
    let before = p.ui.view
    case e.kind
    of KindObjectPublished:
      p.readLock()
    of KindResourceStatus:
      let blocked = p.presenter.blockedFlags()
      p.presenter.uploadStatus(e.resource_id, e.status)
      p.reportBlocked(blocked, "a rejected upload")
      if e.status != ResourceAdmitted:
        p.chunkGiven = false
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
  ## Retry SDK-owned End and Cancel too: they have no Presenter action.
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
  let owner = p.presenter.uploadOwner()
  if p.handle.lockUploadPending() == 0:
    if owner >= 0 and p.pending.kind == akNone:
      let blocked = p.presenter.blockedFlags()
      p.presenter.uploadStatus(p.presenter.outputs[owner].uploading, ResourceRejected)
      p.reportBlocked(blocked, "an upload that ended without a status")
    result = not p.lease.pixels.isNil or p.presenter.cancelUpload
    p.worker.release(p.lease)
    p.presenter.uploadEnded()
    p.chunkGiven = false
    p.cancelRequested = false
    return
  if p.pending.kind != akNone:
    return
  if owner < 0 or p.presenter.cancelUpload:
    if not p.cancelRequested and p.handle.lockUploadCancel() == 0:
      p.cancelRequested = true
      result = true
    return
  if p.handle.lockUploadReady() == 0:
    return
  if not p.chunkGiven:
    if p.lease.pixels.isNil:
      fail("an upload lost its frame lease")
    if p.handle.lockUploadChunk(
      p.lease.pixels, csize_t(p.lease.width * p.lease.height * 4)
    ) == 0:
      p.chunkGiven = true
      result = true
  else:
    result = p.handle.lockUploadEnd() == 0

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
    if p.handle.lockUploadPending() != 0:
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
    p.chunkGiven = false
    r = p.handle.lockUploadBegin(
      a.transaction, a.resource, 1, uint32(o.width), uint32(o.height), 0
    )
    if r != 0:
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
  p.handle = lockOpen(cint(fd), 1, addr keysyms[0], addr modifiers[0])
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
    var fds = [
      TPollfd(fd: cint(fd), events: p.handle.lockPollEvents()),
      TPollfd(fd: p.worker.readyFd(), events: POLLIN),
    ]
    discard poll(addr fds[0], 2, p.timeout(nowMs()))
    if (fds[1].revents and POLLIN) != 0:
      p.worker.clearReady()
      p.presenter.markDirty()
