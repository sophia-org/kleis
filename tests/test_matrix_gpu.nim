## Built with -d:kleisGpuSoftwareTest: Mesa's software rasterizer, no device.
## KLEIS_GPU_TEST_RENDER_NODE also runs one frame on that real render node.
## Frames are checked both as handed over (the mapped readback) and copied,
## and on a device that must copy an RGBA readback.

import std/[options, os, posix, strutils, unittest]

import ../src/kleis/matrix
import ../src/kleis/matrix_gpu
import ../src/kleis/matrix_render
import ../src/kleis/matrix_worker
import ../src/kleis/ui

const motion = MatrixMotion(
  fallSpeed: 0.3, cycleSpeed: 0.03, raindropLength: 0.75, brightnessDecay: 1.0
)

proc atlasFor(width: int): MatrixGlyphAtlas =
  buildMatrixGlyphAtlas(initMatrixRenderer(matrixCellScale(0.0, width)))

proc words(pixels: var seq[uint32]): ptr UncheckedArray[uint32] =
  cast[ptr UncheckedArray[uint32]](addr pixels[0])

proc collect(gpu: MatrixGpu, readback: MatrixGpuFrame, mapped: bool): seq[uint32] =
  ## The frame `readback` holds: copied, or read through its mapping.
  result = newSeq[uint32](readback.width * readback.height)
  if mapped:
    let mapping = gpu.map(readback)
    doAssert not mapping.isNil, matrixGpuLastError()
    for i in 0 ..< result.len:
      result[i] = mapping[i]
    doAssert gpu.unmap(readback), matrixGpuLastError()
  else:
    doAssert gpu.read(readback, result.words), matrixGpuLastError()

proc frame(
    gpu: MatrixGpu, width, height: int, seconds: float, mapped = false
): seq[uint32] =
  var target = gpu.createTarget(width, height, atlasFor(width))
  doAssert not target.isNil, matrixGpuLastError()
  var readback = gpu.createFrame(width, height)
  doAssert not readback.isNil, matrixGpuLastError()
  doAssert gpu.render(target, readback, motion, seconds, MatrixReferenceFrameSeconds)
  result = gpu.collect(readback, mapped)
  gpu.destroy(readback)
  gpu.destroy(target)

proc marked(gpu: MatrixGpu, mapped: bool): seq[uint32] =
  var target = gpu.createTarget(64, 48, atlasFor(64))
  var readback = gpu.createFrame(64, 48)
  doAssert gpu.marks(target, readback), matrixGpuLastError()
  result = gpu.collect(readback, mapped)
  gpu.destroy(readback)
  gpu.destroy(target)

proc checkMarks(pixels: seq[uint32]) =
  ## Top left red, top right green, bottom left blue, the rest black: one
  ## vertical flip too many or too few moves the blue mark to the top.
  proc at(x, y: int): uint32 =
    pixels[y * 64 + x]

  check at(0, 0) == 0xffff0000'u32
  check at(3, 3) == 0xffff0000'u32
  check at(63, 0) == 0xff00ff00'u32
  check at(0, 47) == 0xff0000ff'u32
  check at(63, 47) == 0xff000000'u32
  check at(4, 4) == 0xff000000'u32
  check at(0, 4) == 0xff000000'u32

proc rainFallsDownward(pixels: seq[uint32], width, height: int) =
  ## Classify each cell by its brightest pixel: a pale head, a green trail
  ## or dark. Read upside down, trails would sit below heads instead.
  let cell = matrixCellSize(0.0, width)
  let cols = width div cell
  let rows = height div cell
  proc kind(col, row: int): int =
    ## 0 dark, 1 green trail, 2 pale head
    var best = 0'u32
    for y in row * cell ..< (row + 1) * cell:
      for x in col * cell ..< (col + 1) * cell:
        let p = pixels[y * width + x]
        if ((p shr 8) and 0xff) > ((best shr 8) and 0xff):
          best = p
    let green = (best shr 8) and 0xff
    let red = (best shr 16) and 0xff
    if green == 0:
      0
    elif red * 2 > green:
      2
    else:
      1

  var trailAbove, trailBelow = 0
  for col in 0 ..< cols:
    for row in 1 ..< rows - 1:
      if kind(col, row) == 2:
        if kind(col, row - 1) == 1:
          inc trailAbove
        if kind(col, row + 1) == 1:
          inc trailBelow
  check trailAbove > 10
  check trailAbove > 3 * trailBelow

suite "offscreen gpu matrix":
  var gpu = openMatrixGpuSoftwareTest()
  check gpu.isOpen
  check "llvmpipe" in gpu.identity or "softpipe" in gpu.identity

  check gpu.handsOff

  test "a clear reads back as opaque 0xAARRGGBB words, copied or mapped":
    var target = gpu.createTarget(64, 48, atlasFor(64))
    check not target.isNil
    var readback = gpu.createFrame(64, 48)
    check not readback.isNil
    for mapped in [false, true]:
      check gpu.clear(target, readback, 0x123456'u32)
      var pixels = gpu.collect(readback, mapped)
      for pixel in pixels:
        check pixel == 0xff123456'u32
      let bytes = cast[ptr UncheckedArray[uint8]](addr pixels[0])
      check [bytes[0], bytes[1], bytes[2], bytes[3]] == [0x56'u8, 0x34, 0x12, 0xff]
    gpu.destroy(readback)
    gpu.destroy(target)

  test "rows come back top first, copied or mapped, with no flip":
    checkMarks(gpu.marked(mapped = false))
    checkMarks(gpu.marked(mapped = true))

  test "a frame takes a readback only unmapped and at its target's size":
    var target = gpu.createTarget(64, 48, atlasFor(64))
    var other = gpu.createFrame(32, 48)
    check not gpu.clear(target, other, 0)
    var readback = gpu.createFrame(64, 48)
    check gpu.clear(target, readback, 0)
    check not gpu.map(readback).isNil
    check not gpu.clear(target, readback, 0)
    check gpu.unmap(readback)
    check not gpu.unmap(readback)
    check gpu.createFrame(0, 10).isNil
    gpu.destroy(other)
    gpu.destroy(readback)
    gpu.destroy(target)

  test "matrix frames are full size, opaque and depend only on time":
    let a = gpu.frame(640, 360, 3.0)
    let b = gpu.frame(640, 360, 3.0)
    check a == b
    check gpu.frame(640, 360, 3.0, mapped = true) == a
    var lit = 0
    for pixel in a:
      check (pixel shr 24) == 0xff
      if pixel != 0xff000000'u32:
        inc lit
    check lit > 0
    check lit < a.len div 2

  test "the rain falls downward: trails sit above their heads":
    rainFallsDownward(gpu.frame(640, 360, 5.0), 640, 360)
    rainFallsDownward(gpu.frame(640, 360, 5.0, mapped = true), 640, 360)

  test "a target needs a sane size and atlas":
    check gpu.createTarget(0, 10, atlasFor(64)).isNil
    check gpu.createTarget(10, 16385, atlasFor(64)).isNil
    check gpu.createTarget(64, 64, MatrixGlyphAtlas()).isNil

  gpu.close()

suite "a device without bgra readback copies":
  copyGpuReadback(true)
  var gpu = openMatrixGpuSoftwareTest()
  check gpu.isOpen
  check not gpu.handsOff

  test "rgba is copied as 0xAARRGGBB words, top row first, never mapped":
    checkMarks(gpu.marked(mapped = false))
    rainFallsDownward(gpu.frame(640, 360, 5.0), 640, 360)
    var target = gpu.createTarget(64, 48, atlasFor(64))
    var readback = gpu.createFrame(64, 48)
    check gpu.clear(target, readback, 0x123456'u32)
    check gpu.map(readback).isNil
    gpu.destroy(readback)
    gpu.destroy(target)

  gpu.close()
  copyGpuReadback(false)

proc softwareWorker(frameMs = 30): MatrixWorker =
  startMatrixWorker(
    MatrixWorkerConfig(
      renderNode: "/software",
      deviceMajor: 0,
      deviceMinor: 0,
      frameNs: int64(frameMs) * 1_000_000,
      motion: motion,
      softwareTest: true,
    ),
    View(kind: vkMatrix),
  )

proc next(w: MatrixWorker, allocation: uint64): FrameLease =
  for _ in 0 ..< 300:
    let lease = w.acquire(allocation)
    if lease.isSome:
      return lease.get
    sleep(10)
  doAssert false, "no frame"

proc settle(w: MatrixWorker, expected: LiveResources): LiveResources =
  result = w.liveResources
  for _ in 0 ..< 300:
    if result == expected:
      return
    sleep(10)
    result = w.liveResources

proc frames(w: MatrixWorker, expected: int): int =
  ## The worker's readback buffers once it reports `expected`, or the last
  ## count seen.
  result = w.liveResources.frames
  for _ in 0 ..< 300:
    if result == expected:
      return
    sleep(10)
    result = w.liveResources.frames

proc snapshot(lease: FrameLease): seq[uint32] =
  result = newSeq[uint32](lease.width * lease.height)
  for i in 0 ..< result.len:
    result[i] = lease.pixels[i]

suite "gpu worker handover":
  test "a leased frame stays unchanged while the other slot renders":
    let w = softwareWorker()
    w.setTargets([MatrixTarget(allocation: 1, width: 160, height: 96)])
    var held = w.next(1)
    check w.backend == mbGpu
    let before = held.snapshot
    # The worker renders the other slot meanwhile; take two of its frames.
    for _ in 0 ..< 2:
      var other = w.next(1)
      check other.pixels != held.pixels
      w.release(other)
    check held.snapshot == before
    check w.frames(2) == 2
    w.release(held)
    w.stop()

  test "a leased frame of a removed output keeps its buffer until release":
    let w = softwareWorker()
    w.setTargets([MatrixTarget(allocation: 2, width: 64, height: 48)])
    var held = w.next(2)
    let before = held.snapshot
    w.setTargets([])
    let waiting = w.settle(LiveResources(slots: 1, frames: 1))
    check (waiting.slots, waiting.frames) == (1, 1)
    check held.snapshot == before
    w.release(held)
    check w.settle(LiveResources()) == LiveResources()
    w.stop()

  test "a gpu failure keeps a held frame's buffer until it is released":
    let w = softwareWorker()
    w.setTargets([MatrixTarget(allocation: 3, width: 96, height: 64)])
    var held = w.next(3)
    let before = held.snapshot
    failNextGpuRender()
    var after = w.next(3)
    check w.backend == mbCpu
    # The held frame is still mapped, intact, and its device open; the new
    # one is on the cpu.
    check held.snapshot == before
    check w.frames(1) == 1
    check gpuDeviceOpen()
    w.release(after)
    w.release(held)
    let live = w.settle(LiveResources(slots: 2, cpuOutputs: 1, timings: 1, atlases: 1))
    check live.frames == 0
    check live.gpuTargets == 0
    # Only now, with nothing mapped, is the device closed.
    check not gpuDeviceOpen()
    var cpu = w.next(3)
    for i in 0 ..< cpu.width * cpu.height:
      check (cpu.pixels[i] shr 24) == 0xff
    w.release(cpu)
    w.stop()

  test "a device without bgra readback copies into heap frames":
    copyGpuReadback(true)
    let w = softwareWorker()
    w.setTargets([MatrixTarget(allocation: 4, width: 64, height: 48)])
    var lease = w.next(4)
    check w.backend == mbGpu
    for i in 0 ..< lease.width * lease.height:
      check (lease.pixels[i] shr 24) == 0xff
    w.release(lease)
    w.stop()
    copyGpuReadback(false)

suite "gpu worker resources":
  test "allocation churn returns to the current targets' gpu targets":
    var config = MatrixWorkerConfig(
      renderNode: "/software",
      deviceMajor: 0,
      deviceMinor: 0,
      frameNs: 30_000_000,
      motion: motion,
      softwareTest: true,
    )
    let w = startMatrixWorker(config, View(kind: vkMatrix))
    proc next(allocation: uint64): FrameLease =
      for _ in 0 ..< 300:
        let lease = w.acquire(allocation)
        if lease.isSome:
          return lease.get
        sleep(10)
      doAssert false, "no frame"

    for round in 1 .. 30:
      w.setTargets(
        [MatrixTarget(allocation: uint64(round), width: 64 + round * 8, height: 48)]
      )
      if round mod 5 == 0:
        var lease = next(uint64(round))
        w.release(lease)
    check w.backend == mbGpu
    w.setTargets([MatrixTarget(allocation: 99, width: 200, height: 100)])
    var lease = next(99)
    w.release(lease)
    let expected = LiveResources(
      slots: 2, frames: 2, gpuTargets: 1, cpuOutputs: 0, timings: 1, atlases: 1
    )
    var live = w.liveResources
    for _ in 0 ..< 300:
      if live == expected:
        break
      sleep(10)
      live = w.liveResources
    check live == expected
    w.stop()

suite "software renderers":
  test "renderer strings that name a software rasterizer are recognised":
    check isSoftwareRenderer("llvmpipe (LLVM 22.1.8, 256 bits)")
    check isSoftwareRenderer("softpipe")
    check isSoftwareRenderer("Mesa X11 swrast")
    check isSoftwareRenderer("Software Rasterizer")
    check not isSoftwareRenderer(
      "AMD Radeon RX 7900 GRE (radeonsi, navi31, ACO, DRM 3.64, 6.18.54_1)"
    )
    check not isSoftwareRenderer("Mesa Intel(R) Graphics (ADL GT2)")

suite "granted render node":
  test "only the named node, with matching device numbers, opens":
    check not openMatrixGpu("dev/dri/renderD128", 226, 128).isOpen
    check not openMatrixGpu("/nonexistent/renderD128", 226, 128).isOpen
    # A character device that is not the grant is refused by its numbers.
    check not openMatrixGpu("/dev/null", 226, 128).isOpen
    check "not the granted device" in matrixGpuLastError()

  test "an opt-in real render node renders one opaque frame":
    let node = getEnv("KLEIS_GPU_TEST_RENDER_NODE")
    if node.len == 0:
      skip()
    else:
      var status: Stat
      doAssert stat(node.cstring, status) == 0
      let rdev = uint64(status.st_rdev)
      let major = int64(((rdev shr 8) and 0xfff) or ((rdev shr 32) and not 0xfff'u64))
      let minor = int64((rdev and 0xff) or ((rdev shr 12) and not 0xff'u64))
      var gpu = openMatrixGpu(node, major, minor)
      check gpu.isOpen
      if gpu.isOpen:
        echo "  real node: ", gpu.identity, "; hands off: ", gpu.handsOff
        let pixels = gpu.frame(1920, 1080, 2.0)
        for pixel in pixels:
          check (pixel shr 24) == 0xff
        # Handed over, the mapping is the frame: byte for byte the copy.
        if gpu.handsOff:
          check gpu.frame(1920, 1080, 2.0, mapped = true) == pixels
        checkMarks(gpu.marked(mapped = false))
        if gpu.handsOff:
          checkMarks(gpu.marked(mapped = true))
        gpu.close()
      # Even with Mesa pushed to a software driver, the production open
      # never yields a software renderer: it opens hardware or refuses.
      putEnv("MESA_LOADER_DRIVER_OVERRIDE", "kms_swrast")
      var forced = openMatrixGpu(node, major, minor)
      echo "  forced software: ",
        (if forced.isOpen: forced.identity else: matrixGpuLastError())
      check not (forced.isOpen and isSoftwareRenderer(forced.identity))
      if forced.isOpen:
        forced.close()
      delEnv("MESA_LOADER_DRIVER_OVERRIDE")
