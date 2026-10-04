## The matrix worker renders every output's frames on its own thread, on the
## GPU Sophia granted or on the CPU, so the provider thread never renders,
## never waits for a GPU and never reads pixels back.
##
## Each output has two frame slots. A slot is free, rendering, ready or
## leased. The worker writes only free slots; a newer ready frame frees an
## older unleased one; a leased frame belongs to the provider until it is
## released, whatever happens to its output or view meanwhile.
##
## Storage bounds per output of W x H pixels:
## - two slot buffers of W * H * 4 bytes (the frames the provider uploads);
## - on the GPU: a W x H RGBA8 renderbuffer, a W * H * 4 byte pack buffer,
##   four grid-sized state textures and one glyph atlas row;
## - on the CPU: one float per cell and one glyph atlas row per cell size.
## After a resize or removal, the old geometry's slots that are still leased
## or rendering stay allocated until released or finished: at most two more.
## The worker drops every other per-output resource of a removed or resized
## output on its own thread (GPU targets, CPU fields, timings and atlas sizes
## no output uses), so churn returns to these bounds; liveResources counts
## them.

import std/[locks, monotimes, options, os, posix, strutils, tables]
import ./cli
import ./matrix
import ./matrix_gpu
import ./matrix_render
import ./ui

type
  MatrixBackend* = enum
    mbStarting ## the worker has not chosen yet
    mbCpu
    mbGpu

  MatrixWorkerConfig* = object
    noGpu*: bool
    renderNode*: string ## empty unless Sophia granted a render node
    deviceMajor*, deviceMinor*: int64 ## -1 when absent
    frameMs*: int
    cellScale*: float ## MatrixCellScaleAuto, or a fixed cell scale
    motion*: MatrixMotion
    when defined(kleisGpuSoftwareTest):
      softwareTest*: bool ## tests only: Mesa's software rasterizer, no device

  LiveResources* = object
    ## What the worker holds now; it returns to the current targets' bounds.
    slots*: int ## slot records, including detached ones not yet released
    gpuTargets*: int
    cpuOutputs*: int
    timings*: int
    atlases*: int

  MatrixTarget* = object
    allocation*: uint64
    width*, height*: int

  SlotState = enum
    ssFree
    ssRendering
    ssReady
    ssLeased

  Slot = object
    state: SlotState
    attached: bool ## false once its output is removed or resized
    width, height: int
    viewGeneration: uint64
    sequence: uint64
    pixels: ptr UncheckedArray[uint32]

  FrameLease* = object
    ## A frame the provider holds. Its pixels stay valid, unchanged, until
    ## release.
    allocation*: uint64
    viewGeneration*: uint64
    sequence*: uint64
    width*, height*: int
    pixels*: ptr UncheckedArray[uint32]
    slot: ptr Slot

  OutputSlots = object
    target: MatrixTarget
    slots: array[2, ptr Slot]
    due: bool ## owes a frame now: new view, new geometry or none yet
    nextAt: int64 ## next animation frame, monotonic nanoseconds

  Shared = object
    lock: Lock
    config: MatrixWorkerConfig
    outputs: seq[OutputSlots]
    view: View
    viewGeneration: uint64
    sequence: uint64
    stopping: bool
    backend: MatrixBackend
    targetsVersion: uint64 ## increases with every setTargets
    slots: int ## live slot records
    live: LiveResources ## the worker's own resources, as last reported
    wakeFd: cint ## provider to worker
    readyFd: cint ## worker to provider

  MatrixWorker* = ref object
    shared: ptr Shared
    thread: Thread[ptr Shared]

const
  GpuModeEnv = "SOPHIA_SHELL_GPU_MODE"
  GpuRenderNodeEnv = "SOPHIA_SHELL_GPU_RENDER_NODE"
  GpuDeviceMajorEnv = "SOPHIA_SHELL_GPU_DEVICE_MAJOR"
  GpuDeviceMinorEnv = "SOPHIA_SHELL_GPU_DEVICE_MINOR"
  EfdCloexec = 0o2000000.cint
  EfdNonblock = 0o4000.cint

proc eventfd(initval: cuint, flags: cint): cint {.importc, header: "<sys/eventfd.h>".}

proc signal(fd: cint) =
  ## EAGAIN only means the counter is already non-zero: the wake stands.
  var one = 1'u64
  while posix.write(fd, addr one, 8) < 0 and errno == EINTR:
    discard

proc drain(fd: cint) =
  ## EAGAIN means there was nothing to clear.
  var count: uint64
  while posix.read(fd, addr count, 8) < 0 and errno == EINTR:
    discard

proc nowNs(): int64 =
  getMonoTime().ticks

proc parseDevice(value: string): int64 =
  try:
    parseBiggestInt(value)
  except ValueError:
    -1

proc matrixWorkerConfig*(opts: Options): MatrixWorkerConfig =
  ## The worker's settings, with the GPU grant Sophia passes in the
  ## environment. A render node counts only with direct mode.
  result = MatrixWorkerConfig(
    noGpu: opts.noGpu,
    deviceMajor: -1,
    deviceMinor: -1,
    frameMs: max(opts.matrixFrameMs, 1),
    cellScale: opts.matrixCellScale,
    motion: MatrixMotion(
      fallSpeed: opts.matrixFallSpeed,
      cycleSpeed: opts.matrixCycleSpeed,
      raindropLength: opts.matrixRaindropLength,
      brightnessDecay: opts.matrixBrightnessDecay,
    ),
  )
  if getEnv(GpuModeEnv) == "direct":
    result.renderNode = getEnv(GpuRenderNodeEnv)
    result.deviceMajor = parseDevice(getEnv(GpuDeviceMajorEnv))
    result.deviceMinor = parseDevice(getEnv(GpuDeviceMinorEnv))

# Slot records change only with the shared lock held.

proc newSlot(s: ptr Shared): ptr Slot =
  result = createShared(Slot)
  result.attached = true
  inc s.slots

proc freeSlot(s: ptr Shared, slot: ptr Slot) =
  if not slot.pixels.isNil:
    deallocShared(slot.pixels)
  freeShared(slot)
  dec s.slots

proc detach(s: ptr Shared, slot: ptr Slot) =
  ## The output no longer owns `slot`. A slot the worker is filling or the
  ## provider holds is freed by whichever finishes with it.
  if slot.state in {ssRendering, ssLeased}:
    slot.attached = false
  else:
    s.freeSlot(slot)

proc newOutput(s: ptr Shared, target: MatrixTarget): OutputSlots =
  OutputSlots(target: target, slots: [s.newSlot(), s.newSlot()], due: true)

# The worker thread.

type
  Job = object
    slot: ptr Slot
    allocation: uint64
    width, height: int
    view: View
    viewGeneration: uint64

  CpuOutput = object
    width, height: int
    field: MatrixField

  GpuOutput = object
    target: MatrixGpuTarget

  Renderer = object
    config: MatrixWorkerConfig
    backend: MatrixBackend
    gpu: MatrixGpu
    gpuOutputs: Table[uint64, GpuOutput]
    cpuOutputs: Table[uint64, CpuOutput]
    atlases: Table[int, MatrixGlyphAtlas] ## by cell size
    lastSeconds: Table[uint64, float]

proc log(message: string) =
  stderr.writeLine("kleis: matrix renderer: " & message)

proc atlasFor(r: var Renderer, width: int): MatrixGlyphAtlas =
  let cell = matrixCellSize(r.config.cellScale, width)
  if cell notin r.atlases:
    r.atlases[cell] = buildMatrixGlyphAtlas(
      initMatrixRenderer(matrixCellScale(r.config.cellScale, width))
    )
  r.atlases[cell]

proc startRenderer(config: MatrixWorkerConfig): Renderer =
  ## Chooses the backend once and says so once.
  result.config = config
  result.backend = mbCpu
  if config.noGpu:
    log("cpu (--no-gpu)")
  elif config.renderNode.len == 0:
    log("cpu (no gpu grant)")
  elif config.deviceMajor < 0 or config.deviceMinor < 0:
    log("cpu (incomplete gpu grant)")
  else:
    when defined(kleisGpuSoftwareTest):
      if config.softwareTest:
        result.gpu = openMatrixGpuSoftwareTest()
        result.backend = if result.gpu.isOpen: mbGpu else: mbCpu
        return
    result.gpu =
      openMatrixGpu(config.renderNode, config.deviceMajor, config.deviceMinor)
    if result.gpu.isOpen:
      result.backend = mbGpu
      log("gpu " & result.gpu.identity & " on " & config.renderNode)
    else:
      log("cpu (gpu unavailable: " & matrixGpuLastError() & ")")

proc stopGpu(r: var Renderer) =
  for output in r.gpuOutputs.mvalues:
    r.gpu.destroy(output.target)
  r.gpuOutputs.clear()
  r.gpu.close()

proc fallBack(r: var Renderer) =
  ## A GPU failure is final for this run: the CPU renders from here on.
  log("gpu failed (" & matrixGpuLastError() & "); continuing on the cpu")
  r.stopGpu()
  r.backend = mbCpu

proc reconcile(r: var Renderer, targets: seq[MatrixTarget]) =
  ## Keeps per-output state only for the current targets at their current
  ## sizes. On the worker thread with no lock held: it frees GL objects.
  proc current(allocation: uint64, width, height: int): bool =
    for target in targets:
      if target.allocation == allocation:
        return target.width == width and target.height == height
    false

  var gone: seq[uint64]
  for allocation, output in r.gpuOutputs:
    if output.target.isNil or
        not current(allocation, output.target.width, output.target.height):
      gone.add allocation
  for allocation in gone:
    var output = r.gpuOutputs[allocation]
    r.gpu.destroy(output.target)
    r.gpuOutputs.del allocation
  gone.setLen(0)
  for allocation, output in r.cpuOutputs:
    if not current(allocation, output.width, output.height):
      gone.add allocation
  for allocation in gone:
    r.cpuOutputs.del allocation
  gone.setLen(0)
  for allocation in r.lastSeconds.keys:
    var present = false
    for target in targets:
      present = present or target.allocation == allocation
    if not present:
      gone.add allocation
  for allocation in gone:
    r.lastSeconds.del allocation
  var unused: seq[int]
  for cell in r.atlases.keys:
    var used = false
    for target in targets:
      used = used or matrixCellSize(r.config.cellScale, target.width) == cell
    if not used:
      unused.add cell
  for cell in unused:
    r.atlases.del cell

proc live(r: Renderer): LiveResources =
  LiveResources(
    gpuTargets: r.gpuOutputs.len,
    cpuOutputs: r.cpuOutputs.len,
    timings: r.lastSeconds.len,
    atlases: r.atlases.len,
  )

proc fill(job: Job) =
  let pixel = 0xff000000'u32 or (job.view.color and 0x00ffffff'u32)
  for i in 0 ..< job.width * job.height:
    job.slot.pixels[i] = pixel

proc elapsed(r: var Renderer, allocation: uint64, seconds: float): float =
  result =
    seconds -
    r.lastSeconds.getOrDefault(allocation, seconds - MatrixReferenceFrameSeconds)
  r.lastSeconds[allocation] = seconds

proc renderCpu(r: var Renderer, job: Job, seconds: float) =
  if job.view.kind == vkSolid:
    job.fill()
    return
  var output = r.cpuOutputs.getOrDefault(job.allocation)
  if output.width != job.width or output.height != job.height:
    output = CpuOutput(
      width: job.width,
      height: job.height,
      field: matrixFieldFor(r.config.cellScale, job.width, job.height),
    )
  discard r.elapsed(job.allocation, seconds)
  output.field.step(r.config.motion, seconds)
  renderMatrixField(
    output.field,
    r.config.motion,
    seconds,
    r.atlasFor(job.width),
    job.slot.pixels,
    job.width,
    job.height,
  )
  r.cpuOutputs[job.allocation] = output

proc gpuTarget(r: var Renderer, job: Job): MatrixGpuTarget =
  var output = r.gpuOutputs.getOrDefault(job.allocation)
  if output.target.isNil or output.target.width != job.width or
      output.target.height != job.height:
    r.gpu.destroy(output.target)
    output.target = r.gpu.createTarget(job.width, job.height, r.atlasFor(job.width))
    r.gpuOutputs[job.allocation] = output
  output.target

proc renderAll(r: var Renderer, jobs: seq[Job], seconds: float) =
  ## Queues every output's GPU frame before waiting for any of them.
  var queued: seq[(Job, MatrixGpuTarget)]
  if r.backend == mbGpu:
    for job in jobs:
      if job.view.kind == vkSolid:
        job.fill()
        continue
      let target = r.gpuTarget(job)
      if target.isNil or
          not r.gpu.render(
            target, r.config.motion, seconds, r.elapsed(job.allocation, seconds)
          ):
        r.fallBack()
        break
      queued.add((job, target))
    if r.backend == mbGpu:
      for (job, target) in queued:
        if not r.gpu.read(target, job.slot.pixels):
          r.fallBack()
          break
    if r.backend == mbGpu:
      return
  for job in jobs:
    r.renderCpu(job, seconds)

proc collect(s: ptr Shared, now: int64): seq[Job] =
  ## Claims a free slot of every output that owes a frame.
  let frameNs = int64(s.config.frameMs) * 1_000_000
  for output in s.outputs.mitems:
    let animated = s.view.kind == vkMatrix
    if not (output.due or (animated and now >= output.nextAt)):
      continue
    var slot: ptr Slot = nil
    for candidate in output.slots:
      if candidate.state == ssFree:
        slot = candidate
        break
    if slot.isNil:
      continue
    let target = output.target
    if slot.pixels.isNil or slot.width != target.width or slot.height != target.height:
      if not slot.pixels.isNil:
        deallocShared(slot.pixels)
      slot.pixels =
        cast[ptr UncheckedArray[uint32]](allocShared(target.width * target.height * 4))
      slot.width = target.width
      slot.height = target.height
    slot.state = ssRendering
    slot.viewGeneration = s.viewGeneration
    output.due = false
    output.nextAt = now + frameNs
    result.add Job(
      slot: slot,
      allocation: target.allocation,
      width: target.width,
      height: target.height,
      view: s.view,
      viewGeneration: s.viewGeneration,
    )

proc waitMs(s: ptr Shared, now: int64): cint =
  ## Until the next animation frame an output with a free slot owes.
  if s.view.kind != vkMatrix:
    return -1
  var earliest = high(int64)
  for output in s.outputs:
    if output.slots[0].state == ssFree or output.slots[1].state == ssFree:
      earliest = min(earliest, output.nextAt)
  if earliest == high(int64):
    return -1
  cint(clamp((earliest - now + 999_999) div 1_000_000, 0, 1000))

proc publish(s: ptr Shared, jobs: seq[Job]): bool =
  ## Hands finished frames over. A frame of an older view is dropped and its
  ## output owes a new one.
  for job in jobs:
    let slot = job.slot
    if not slot.attached:
      s.freeSlot(slot)
      continue
    var output: ptr OutputSlots = nil
    for candidate in s.outputs.mitems:
      if slot in candidate.slots:
        output = addr candidate
    if job.viewGeneration != s.viewGeneration:
      slot.state = ssFree
      if not output.isNil:
        output.due = true
      continue
    inc s.sequence
    slot.state = ssReady
    slot.sequence = s.sequence
    if not output.isNil:
      for other in output.slots:
        if other != slot and other.state == ssReady:
          other.state = ssFree
    result = true

proc workerMain(s: ptr Shared) {.thread.} =
  {.cast(gcsafe).}:
    var renderer = startRenderer(s.config)
    withLock s.lock:
      s.backend = renderer.backend
    let origin = nowNs()
    var seenTargets = 0'u64
    while true:
      var jobs: seq[Job]
      var timeout: cint
      var targets: Option[seq[MatrixTarget]]
      withLock s.lock:
        if s.stopping:
          break
        jobs = collect(s, nowNs())
        timeout = waitMs(s, nowNs())
        if s.targetsVersion != seenTargets:
          seenTargets = s.targetsVersion
          var current: seq[MatrixTarget]
          for output in s.outputs:
            current.add output.target
          targets = some(current)
      if targets.isSome:
        renderer.reconcile(targets.get)
        withLock s.lock:
          s.live = renderer.live
      if jobs.len == 0:
        var wake = TPollfd(fd: s.wakeFd, events: POLLIN)
        if poll(addr wake, 1, timeout) > 0:
          drain(s.wakeFd)
        continue
      let seconds = float(nowNs() - origin) / 1e9
      renderer.renderAll(jobs, seconds)
      var ready: bool
      withLock s.lock:
        s.backend = renderer.backend
        s.live = renderer.live
        ready = publish(s, jobs)
      if ready:
        signal(s.readyFd)
    if renderer.backend == mbGpu:
      renderer.stopGpu()

# The provider's side. Every call is short and never waits for rendering.

proc wake(w: MatrixWorker) =
  signal(w.shared.wakeFd)

proc startMatrixWorker*(config: MatrixWorkerConfig, view: View): MatrixWorker =
  let shared = createShared(Shared)
  initLock(shared.lock)
  shared.config = config
  shared.view = view
  shared.viewGeneration = 1
  shared.backend = mbStarting
  shared.wakeFd = eventfd(0, EfdCloexec or EfdNonblock)
  shared.readyFd = eventfd(0, EfdCloexec or EfdNonblock)
  if shared.wakeFd < 0 or shared.readyFd < 0:
    raise newException(OSError, "the matrix worker could not create its eventfds")
  result = MatrixWorker(shared: shared)
  createThread(result.thread, workerMain, shared)

proc backend*(w: MatrixWorker): MatrixBackend =
  withLock w.shared.lock:
    result = w.shared.backend

proc readyFd*(w: MatrixWorker): cint =
  ## Readable when an output has a newer frame. Poll it beside the lock fd.
  w.shared.readyFd

proc clearReady*(w: MatrixWorker) =
  drain(w.shared.readyFd)

proc liveResources*(w: MatrixWorker): LiveResources =
  withLock w.shared.lock:
    result = w.shared.live
    result.slots = w.shared.slots

proc viewGeneration*(w: MatrixWorker): uint64 =
  withLock w.shared.lock:
    result = w.shared.viewGeneration

proc sameView(a, b: View): bool =
  a.kind == b.kind and
    (a.kind == vkMatrix or (a.color and 0x00ffffff'u32) == (b.color and 0x00ffffff'u32))

proc setView*(w: MatrixWorker, view: View): uint64 =
  ## Returns the view's generation, which increases with every change. An
  ## equal view changes nothing. Ready frames of the old view are dropped; a
  ## leased one stays the provider's until released. Views set while a frame
  ## renders coalesce: the worker draws the newest next.
  withLock w.shared.lock:
    let s = w.shared
    if not sameView(s.view, view):
      s.view = view
      inc s.viewGeneration
      for output in s.outputs.mitems:
        output.due = true
        for slot in output.slots:
          if slot.state == ssReady:
            slot.state = ssFree
    result = s.viewGeneration
  w.wake()

proc setTargets*(w: MatrixWorker, targets: openArray[MatrixTarget]) =
  ## The outputs to render, by allocation. A changed size replaces the
  ## output's slots even when the allocation is the same; leased frames are
  ## never freed here.
  withLock w.shared.lock:
    let s = w.shared
    var outputs: seq[OutputSlots]
    inc s.targetsVersion
    for target in targets:
      var kept = false
      for i in 0 ..< s.outputs.len:
        if s.outputs[i].target.allocation == target.allocation:
          if s.outputs[i].target == target:
            outputs.add s.outputs[i]
            s.outputs[i].slots = [nil, nil]
            kept = true
          break
      if not kept:
        outputs.add s.newOutput(target)
    for output in s.outputs:
      for slot in output.slots:
        if not slot.isNil:
          s.detach(slot)
    s.outputs = outputs
  w.wake()

proc acquire*(w: MatrixWorker, allocation: uint64): Option[FrameLease] =
  ## The output's newest frame of the current view, if one is ready. It
  ## stays leased, unchanged, until release.
  withLock w.shared.lock:
    let s = w.shared
    for output in s.outputs:
      if output.target.allocation != allocation:
        continue
      var best: ptr Slot = nil
      for slot in output.slots:
        if slot.state == ssReady and slot.viewGeneration == s.viewGeneration and
            (best.isNil or slot.sequence > best.sequence):
          best = slot
      if not best.isNil:
        best.state = ssLeased
        result = some(
          FrameLease(
            allocation: allocation,
            viewGeneration: best.viewGeneration,
            sequence: best.sequence,
            width: best.width,
            height: best.height,
            pixels: best.pixels,
            slot: best,
          )
        )

proc release*(w: MatrixWorker, lease: var FrameLease, retry = false) =
  ## After the upload's custody, cancel or rejection. Releasing twice is
  ## harmless. If admission was busy before the SDK borrowed the pixels,
  ## retry returns a current frame to Ready unless a newer one exists. The
  ## caller already knows it is ready; ringing readyFd here would busy-spin
  ## against the same blocked admission.
  if lease.slot.isNil:
    return
  withLock w.shared.lock:
    if lease.slot.attached:
      var keep = retry and lease.viewGeneration == w.shared.viewGeneration
      if keep:
        for output in w.shared.outputs:
          if lease.slot in output.slots:
            for other in output.slots:
              if other.state == ssReady and other.sequence > lease.sequence:
                keep = false
      lease.slot.state = if keep: ssReady else: ssFree
    else:
      w.shared.freeSlot(lease.slot)
  lease.slot = nil
  lease.pixels = nil
  w.wake()

proc stop*(w: MatrixWorker) =
  ## Ends the worker. Release every lease first.
  withLock w.shared.lock:
    w.shared.stopping = true
  w.wake()
  joinThread(w.thread)
  let s = w.shared
  for output in s.outputs:
    for slot in output.slots:
      s.freeSlot(slot)
  s.outputs.setLen(0)
  discard posix.close(s.wakeFd)
  discard posix.close(s.readyFd)
  deinitLock(s.lock)
  `=destroy`(s[])
  freeShared(s)
