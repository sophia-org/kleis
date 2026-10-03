## The lock provider loop: one Sophia lock connection, the screens it grants,
## and what each shows. Sophia starts kleis in a sandbox with no HOME; the
## socket and the config file arrive in SOPHIA_LOCK_9P_SOCKET and
## SOPHIA_LOCK_CONFIG. When the connection ends (refused, revoked or failed)
## kleis exits nonzero and Sophia starts a replacement under a fresh epoch.

import std/[monotimes, nativesockets, net, os, posix, tables]

import ./cli
import ./config
import ./frame
import ./matrix
import ./matrix_render
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
  frames: Table[uint64, OutputFrame] ## by allocation
  renderer: MatrixRenderer
  opts: Options
  lockGeneration: uint64
  lockDrawn: uint64 ## the lock epoch ui last started for
  pending: Action ## the record the SDK holds, until custody or refusal
  chunkGiven: bool
  ## The image being uploaded. The SDK borrows it until every byte is
  ## written, so it is never replaced while an upload is in flight, even if
  ## its screen goes away.
  uploadPixels: seq[uint32]
  nextTickAt: int64
  lastRetryAt: int64

proc fail(message: string) =
  stderr.writeLine("kleis: " & message)
  quit(1)

proc readLock(p: var Provider) =
  var generation, lockEpoch: uint64
  var phase, count: uint16
  if p.handle.lockObject(generation, phase, lockEpoch, count) == 0 or
      generation == p.lockGeneration:
    return
  p.lockGeneration = generation
  let drawing = phase in {PhaseLocking, PhaseLocked}
  var allocations: seq[Allocation]
  var widest = 0
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
        widest = max(widest, int(a.pixel_width))
  if drawing and lockEpoch != p.lockDrawn:
    p.ui.lockStarted(nowMs())
    p.lockDrawn = lockEpoch
  p.presenter.setLock(drawing, lockEpoch, allocations)
  # One renderer for every screen, sized for the widest.
  p.renderer = initMatrixRenderer(matrixEffectiveScale(p.opts.matrixCellScale, widest))
  var frames: Table[uint64, OutputFrame]
  for a in allocations:
    if a.allocation in p.frames and p.frames[a.allocation].width == a.width and
        p.frames[a.allocation].height == a.height:
      frames[a.allocation] = p.frames[a.allocation]
    else:
      frames[a.allocation] = initOutputFrame(a.width, a.height, p.renderer)
  p.frames = frames

proc drainEvents(p: var Provider) =
  var e: LockEvent
  while p.handle.lockEvent(e) != 0:
    let now = nowMs()
    let before = p.ui.view
    case e.kind
    of KindObjectPublished:
      p.readLock()
    of KindResourceStatus:
      p.presenter.uploadStatus(e.resource_id, e.status)
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
      p.presenter.markDirty()
    if p.handle.lockConsume() != 0:
      fail("the lock connection failed")

proc settlePending(p: var Provider) =
  ## A record counts once the server took custody of it, or refused it.
  if p.pending.kind == akNone:
    return
  var stage, error: uint32
  discard p.handle.lockSubmission(stage, error)
  if stage == SubmissionCustodied:
    p.presenter.applied(p.pending)
    p.pending = Action()
  elif stage == SubmissionRefused:
    p.presenter.refused(p.pending)
    p.pending = Action()
  elif stage == SubmissionStaged and nowMs() - p.lastRetryAt >= RetryAfterMs:
    # EAGAIN: the same bytes go again after a short wait.
    p.lastRetryAt = nowMs()
    discard p.handle.lockSubmitRetry()

proc driveUpload(p: var Provider) =
  let owner = p.presenter.uploadOwner()
  if p.handle.lockUploadPending() == 0:
    if owner >= 0 and p.pending.kind == akNone:
      # The upload ended without a status: an end or begin was refused.
      p.presenter.uploadStatus(p.presenter.outputs[owner].uploading, ResourceRejected)
    p.chunkGiven = false
    return
  if p.handle.lockUploadReady() == 0 or p.pending.kind != akNone:
    return
  if owner < 0 or p.presenter.cancelUpload:
    discard p.handle.lockUploadCancel()
  elif not p.chunkGiven:
    if p.handle.lockUploadChunk(addr p.uploadPixels[0], csize_t(p.uploadPixels.len * 4)) ==
        0:
      p.chunkGiven = true
  else:
    discard p.handle.lockUploadEnd()

proc act(p: var Provider) =
  if p.pending.kind != akNone:
    return
  let a = p.presenter.next()
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
    var f = addr p.frames[o.allocation]
    f[].render(p.ui.view, p.renderer)
    p.uploadPixels = f[].pixels
    p.chunkGiven = false
    r = p.handle.lockUploadBegin(
      a.transaction, a.resource, 1, uint32(o.width), uint32(o.height), 0
    )
  if r == 0:
    p.pending = a
  elif r != SdkBusy:
    fail("a lock record could not be submitted")

proc tickMatrix(p: var Provider, now: int64) =
  if p.ui.view.kind != vkMatrix:
    p.nextTickAt = 0
    return
  if p.nextTickAt == 0:
    p.nextTickAt = now + p.opts.matrixFrameMs
  elif now >= p.nextTickAt:
    for f in p.frames.mvalues:
      f.rain.advance()
    p.presenter.markDirty()
    p.nextTickAt = now + p.opts.matrixFrameMs

proc timeout(p: Provider, now: int64): cint =
  var deadline = now + 1000
  let ui = p.ui.nextDeadline
  if ui >= 0:
    deadline = min(deadline, ui)
  if p.nextTickAt > 0:
    deadline = min(deadline, p.nextTickAt)
  if p.pending.kind != akNone:
    deadline = min(deadline, now + RetryAfterMs)
  cint(max(0'i64, deadline - now))

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
  while true:
    if p.handle.lockService() != 0:
      case p.handle.lockState()
      of StateRefused:
        fail("Sophia refused the lock provider negotiation")
      of StateStale:
        fail("Sophia ended this lock connection")
      else:
        fail("the lock connection failed (error " & $p.handle.lockRemoteError() & ")")
    p.drainEvents()
    let now = nowMs()
    let before = p.ui.view
    p.ui.tick(now)
    if p.ui.view != before:
      p.presenter.markDirty()
    p.tickMatrix(now)
    p.settlePending()
    p.driveUpload()
    p.act()
    if p.handle.lockService() != 0:
      continue
    var pfd = TPollfd(fd: cint(fd), events: p.handle.lockPollEvents())
    discard poll(addr pfd, 1, p.timeout(nowMs()))
