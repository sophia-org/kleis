## Built with -d:kleisGpuSoftwareTest: Mesa's software rasterizer, no device.
## KLEIS_GPU_TEST_RENDER_NODE also runs one frame on that real render node.

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

proc frame(gpu: MatrixGpu, width, height: int, seconds: float): seq[uint32] =
  var target = gpu.createTarget(width, height, atlasFor(width))
  doAssert not target.isNil, matrixGpuLastError()
  result = newSeq[uint32](width * height)
  doAssert gpu.render(target, motion, seconds, MatrixReferenceFrameSeconds)
  doAssert gpu.read(target, cast[ptr UncheckedArray[uint32]](addr result[0])),
    matrixGpuLastError()
  gpu.destroy(target)

suite "offscreen gpu matrix":
  var gpu = openMatrixGpuSoftwareTest()
  check gpu.isOpen
  check "llvmpipe" in gpu.identity or "softpipe" in gpu.identity

  test "a clear reads back as opaque 0xAARRGGBB words, top row first":
    var target = gpu.createTarget(64, 48, atlasFor(64))
    check not target.isNil
    var pixels = newSeq[uint32](64 * 48)
    check gpu.clear(target, 0x123456'u32)
    check gpu.read(target, cast[ptr UncheckedArray[uint32]](addr pixels[0]))
    for pixel in pixels:
      check pixel == 0xff123456'u32
    let bytes = cast[ptr UncheckedArray[uint8]](addr pixels[0])
    check [bytes[0], bytes[1], bytes[2], bytes[3]] == [0x56'u8, 0x34, 0x12, 0xff]
    gpu.destroy(target)

  test "matrix frames are full size, opaque and depend only on time":
    let a = gpu.frame(640, 360, 3.0)
    let b = gpu.frame(640, 360, 3.0)
    check a == b
    var lit = 0
    for pixel in a:
      check (pixel shr 24) == 0xff
      if pixel != 0xff000000'u32:
        inc lit
    check lit > 0
    check lit < a.len div 2

  test "the rain falls downward: trails sit above their heads":
    # Classify each cell by its brightest pixel: a pale head, a green trail
    # or dark. Read upside down, trails would sit below heads instead.
    const width = 640
    const height = 360
    let pixels = gpu.frame(width, height, 5.0)
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

  test "a target needs a sane size and atlas":
    check gpu.createTarget(0, 10, atlasFor(64)).isNil
    check gpu.createTarget(10, 16385, atlasFor(64)).isNil
    check gpu.createTarget(64, 64, MatrixGlyphAtlas()).isNil

  gpu.close()

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
    let expected =
      LiveResources(slots: 2, gpuTargets: 1, cpuOutputs: 0, timings: 1, atlases: 1)
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
        echo "  real node: ", gpu.identity
        let pixels = gpu.frame(1920, 1080, 2.0)
        for pixel in pixels:
          check (pixel shr 24) == 0xff
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
