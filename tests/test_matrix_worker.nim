## The worker on the CPU backend (--no-gpu), plus the GPU grant's refusals.
## KLEIS_GPU_TEST_RENDER_NODE also runs the worker on that real render node.

import std/[options, os, posix, times, unittest]

import ../src/kleis/cli
import ../src/kleis/matrix
import ../src/kleis/matrix_worker
import ../src/kleis/ui

const matrixView = View(kind: vkMatrix)

proc config(frameMs = 40): MatrixWorkerConfig =
  MatrixWorkerConfig(
    noGpu: true,
    deviceMajor: -1,
    deviceMinor: -1,
    frameNs: int64(frameMs) * 1_000_000,
    cellScale: 0.0,
    motion: MatrixMotion(
      fallSpeed: 0.3, cycleSpeed: 0.03, raindropLength: 0.75, brightnessDecay: 1.0
    ),
  )

proc waitReady(w: MatrixWorker, ms = 3000): bool =
  var fd = TPollfd(fd: w.readyFd, events: POLLIN)
  result = poll(addr fd, 1, cint(ms)) > 0
  if result:
    w.clearReady()

proc next(w: MatrixWorker, allocation: uint64, ms = 3000): Option[FrameLease] =
  ## The next frame of `allocation`, waiting for the worker if needed.
  let deadline = epochTime() + ms / 1000
  while epochTime() < deadline:
    result = w.acquire(allocation)
    if result.isSome:
      return
    discard w.waitReady(50)

proc allPixels(lease: FrameLease, pixel: uint32): bool =
  for i in 0 ..< lease.width * lease.height:
    if lease.pixels[i] != pixel:
      return false
  true

proc opaque(lease: FrameLease): bool =
  for i in 0 ..< lease.width * lease.height:
    if (lease.pixels[i] shr 24) != 0xff:
      return false
  true

suite "matrix worker":
  test "busy admission preserves a one-shot solid without another wake":
    let w = startMatrixWorker(config(), View(kind: vkSolid, color: 0x112233))
    w.setTargets([MatrixTarget(allocation: 1, width: 32, height: 24)])
    # Observe the initial signal before checking that retry emits none.
    check w.waitReady()
    var frame = w.acquire(1).get
    w.clearReady()
    let sequence = frame.sequence
    let pixels = frame.pixels
    w.release(frame, retry = true)
    check frame.pixels.isNil
    check not w.waitReady(20) # Admission progress, not readiness, drives retry.
    var retried = w.acquire(1).get
    check retried.sequence == sequence and retried.pixels == pixels
    check retried.allPixels(0xff112233'u32)
    w.release(retried)
    w.stop()

  test "busy admission cannot revive an old view or displace a newer frame":
    let w = startMatrixWorker(config(frameMs = 10), matrixView)
    w.setTargets([MatrixTarget(allocation: 1, width: 32, height: 24)])
    var older = w.next(1).get
    var newer = w.next(1).get
    let sequence = newer.sequence
    w.release(newer, retry = true)
    w.release(older, retry = true)
    var latest = w.acquire(1).get
    check latest.sequence >= sequence
    let generation = w.setView(View(kind: vkSolid, color: 0xaabbcc))
    w.release(latest, retry = true)
    var solid = w.next(1).get
    check solid.viewGeneration == generation
    check solid.allPixels(0xffaabbcc'u32)
    w.release(solid)
    w.setTargets([])
    w.stop()

  test "every output gets full-size opaque frames of the current view":
    let w = startMatrixWorker(config(), matrixView)
    w.setTargets(
      [
        MatrixTarget(allocation: 1, width: 320, height: 200),
        MatrixTarget(allocation: 2, width: 160, height: 90),
      ]
    )
    var a = w.next(1).get
    var b = w.next(2).get
    check w.backend == mbCpu
    check (a.width, a.height, a.viewGeneration) == (320, 200, 1'u64)
    check (b.width, b.height, b.viewGeneration) == (160, 90, 1'u64)
    check a.opaque and b.opaque
    w.release(a)
    w.release(b)
    w.stop()

  test "two slots per output: the worker never writes a leased frame":
    let w = startMatrixWorker(config(frameMs = 30), matrixView)
    w.setTargets([MatrixTarget(allocation: 7, width: 64, height: 64)])
    var first = w.next(7).get
    let copy = @(toOpenArray(first.pixels, 0, 64 * 64 - 1))
    var second = w.next(7).get
    check second.sequence > first.sequence
    # Both slots are leased: nothing more can be rendered or acquired.
    sleep(200)
    check w.acquire(7).isNone
    check @(toOpenArray(first.pixels, 0, 64 * 64 - 1)) == copy
    w.release(first)
    var third = w.next(7).get
    check third.sequence > second.sequence
    w.release(second)
    w.release(third)
    w.release(third) # twice is harmless
    w.stop()

  test "views have increasing generations; equal views change nothing":
    let w = startMatrixWorker(config(), matrixView)
    check w.viewGeneration == 1
    check w.setView(matrixView) == 1
    check w.setView(View(kind: vkSolid, color: 0x112233)) == 2
    check w.setView(View(kind: vkSolid, color: 0x112233)) == 2
    check w.setView(View(kind: vkSolid, color: 0x445566)) == 3
    check w.setView(matrixView) == 4
    w.stop()

  test "only current-view frames are acquired; a leased old frame stays borrowed":
    let w = startMatrixWorker(config(), matrixView)
    w.setTargets([MatrixTarget(allocation: 3, width: 48, height: 32)])
    var old = w.next(3).get
    let copy = @(toOpenArray(old.pixels, 0, 48 * 32 - 1))
    discard w.waitReady(500) # let the other slot fill with the old view
    let solid = w.setView(View(kind: vkSolid, color: 0xabcdef))
    var fresh = w.next(3).get
    check fresh.viewGeneration == solid
    check fresh.allPixels(0xffabcdef'u32)
    check old.viewGeneration == 1
    check @(toOpenArray(old.pixels, 0, 48 * 32 - 1)) == copy
    w.release(old)
    w.release(fresh)
    w.stop()

  test "rapid view changes coalesce into the newest":
    let w = startMatrixWorker(config(), View(kind: vkSolid, color: 0))
    w.setTargets([MatrixTarget(allocation: 4, width: 32, height: 32)])
    var last = 0'u64
    for color in 1'u32 .. 200'u32:
      last = w.setView(View(kind: vkSolid, color: color))
    var lease = w.next(4).get
    check lease.viewGeneration == last
    check lease.allPixels(0xff0000c8'u32)
    w.release(lease)
    w.stop()

  test "a new size replaces the output even for the same allocation":
    let w = startMatrixWorker(config(), matrixView)
    w.setTargets([MatrixTarget(allocation: 5, width: 64, height: 40)])
    var old = w.next(5).get
    let copy = @(toOpenArray(old.pixels, 0, 64 * 40 - 1))
    w.setTargets([MatrixTarget(allocation: 5, width: 96, height: 60)])
    var resized = w.next(5).get
    check (resized.width, resized.height) == (96, 60)
    check (old.width, old.height) == (64, 40)
    check @(toOpenArray(old.pixels, 0, 64 * 40 - 1)) == copy
    w.release(old) # freed now: its output no longer owns it
    w.setTargets([])
    check w.acquire(5).isNone
    w.release(resized)
    w.stop()

proc settle(w: MatrixWorker, expected: LiveResources, ms = 3000): LiveResources =
  ## The worker's resources once it has caught up with the current targets.
  let deadline = epochTime() + ms / 1000
  result = w.liveResources
  while result != expected and epochTime() < deadline:
    sleep(10)
    result = w.liveResources

suite "matrix worker resources":
  test "allocation churn returns to the current targets' resources":
    let w = startMatrixWorker(config(frameMs = 30), matrixView)
    var held: seq[FrameLease]
    for round in 1 .. 60:
      let size = 32 + (round mod 5) * 16
      w.setTargets(
        [
          MatrixTarget(allocation: uint64(round), width: size * 2, height: size),
          MatrixTarget(allocation: 1000, width: 64 + (round mod 3) * 640, height: 48),
        ]
      )
      if round mod 10 == 0:
        let lease = w.next(uint64(round))
        if lease.isSome:
          held.add lease.get
    check held.len > 0
    for lease in held.mitems:
      w.release(lease)
    w.setTargets(
      [
        MatrixTarget(allocation: 1, width: 320, height: 200),
        MatrixTarget(allocation: 2, width: 1920, height: 100),
      ]
    )
    var a = w.next(1).get
    var b = w.next(2).get
    w.release(a)
    w.release(b)
    # Two outputs: four slots, one CPU field and timing each, and an atlas
    # for each cell size (8 and 24 pixels).
    let expected =
      LiveResources(slots: 4, gpuTargets: 0, cpuOutputs: 2, timings: 2, atlases: 2)
    check w.settle(expected) == expected
    w.setTargets([])
    check w.settle(LiveResources()) == LiveResources()
    w.stop()

  test "a leased frame of a removed output is freed on release":
    let w = startMatrixWorker(config(), matrixView)
    w.setTargets([MatrixTarget(allocation: 6, width: 40, height: 30)])
    var lease = w.next(6).get
    w.setTargets([])
    check w.settle(LiveResources(slots: 1)).slots == 1
    w.release(lease)
    check w.settle(LiveResources()) == LiveResources()
    w.stop()

suite "gpu grant":
  test "the grant comes from Sophia's environment, in direct mode only":
    putEnv("SOPHIA_SHELL_GPU_MODE", "direct")
    putEnv("SOPHIA_SHELL_GPU_RENDER_NODE", "/dev/dri/renderD128")
    putEnv("SOPHIA_SHELL_GPU_DEVICE_MAJOR", "226")
    putEnv("SOPHIA_SHELL_GPU_DEVICE_MINOR", "128")
    var opts = defaultOptions()
    let granted = matrixWorkerConfig(opts)
    check granted.renderNode == "/dev/dri/renderD128"
    check (granted.deviceMajor, granted.deviceMinor) == (226'i64, 128'i64)
    check granted.frameNs == 1_000_000_000'i64 div int64(opts.matrixFps)
    putEnv("SOPHIA_SHELL_GPU_MODE", "denied")
    check matrixWorkerConfig(opts).renderNode == ""
    delEnv("SOPHIA_SHELL_GPU_MODE")
    check matrixWorkerConfig(opts).renderNode == ""
    for name in [
      "SOPHIA_SHELL_GPU_RENDER_NODE", "SOPHIA_SHELL_GPU_DEVICE_MAJOR",
      "SOPHIA_SHELL_GPU_DEVICE_MINOR",
    ]:
      delEnv(name)

  test "no grant, an incomplete grant or a wrong node renders on the cpu":
    for (node, major, minor) in [
      ("", -1'i64, -1'i64),
      ("/dev/null", -1'i64, -1'i64),
      ("/dev/null", 226'i64, 128'i64),
      ("/nonexistent/renderD128", 226'i64, 128'i64),
    ]:
      var c = config()
      c.noGpu = false
      c.renderNode = node
      c.deviceMajor = major
      c.deviceMinor = minor
      let w = startMatrixWorker(c, matrixView)
      w.setTargets([MatrixTarget(allocation: 9, width: 32, height: 32)])
      var lease = w.next(9).get
      check w.backend == mbCpu
      check lease.opaque
      w.release(lease)
      w.stop()

  test "an opt-in real render node renders on the gpu":
    let node = getEnv("KLEIS_GPU_TEST_RENDER_NODE")
    if node.len == 0:
      skip()
    else:
      var status: Stat
      doAssert stat(node.cstring, status) == 0
      let rdev = uint64(status.st_rdev)
      var c = config()
      c.noGpu = false
      c.renderNode = node
      c.deviceMajor =
        int64(((rdev shr 8) and 0xfff) or ((rdev shr 32) and not 0xfff'u64))
      c.deviceMinor = int64((rdev and 0xff) or ((rdev shr 12) and not 0xff'u64))
      let w = startMatrixWorker(c, matrixView)
      w.setTargets([MatrixTarget(allocation: 10, width: 2560, height: 1440)])
      var lease = w.next(10).get
      check w.backend == mbGpu
      check lease.opaque
      w.release(lease)
      w.stop()
