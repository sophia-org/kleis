## Offscreen Matrix rendering on the render node Sophia grants
## (matrix_gpu_shim.c). A device and its targets belong to the one thread that
## opened them: the matrix worker.

import ./matrix
import ./matrix_render

const
  MatrixGpuPkgConfigDeps = "gbm egl glesv2"
  MatrixGpuPkgConfigCheck = gorgeEx("pkg-config --exists " & MatrixGpuPkgConfigDeps)

when MatrixGpuPkgConfigCheck.exitCode != 0:
  {.
    error:
      "missing system dependencies: install pkg-config plus development packages for gbm, egl and glesv2"
  .}

when defined(kleisGpuSoftwareTest):
  {.passC: "-DKLEIS_MATRIX_GPU_SOFTWARE_TEST".}
{.passC: "-Isrc -Isrc/kleis " & gorge("pkg-config --cflags " & MatrixGpuPkgConfigDeps).}
{.compile: "matrix_gpu_shim.c".}
{.passL: gorge("pkg-config --libs " & MatrixGpuPkgConfigDeps).}

type
  MatrixGpu* = object
    handle: pointer

  MatrixGpuTarget* = object
    handle: pointer
    width*, height*: int
    cellSize*: int

  MatrixGpuFrame* = object
    ## One frame's readback buffer. It belongs, like the device, to the
    ## worker thread: only that thread may map, unmap or destroy it, though
    ## any thread may read a mapping while it lasts.
    handle: pointer
    width*, height*: int

proc gpuOpen(
  renderNode: cstring, major, minor: int64
): pointer {.importc: "kleis_matrix_gpu_open", header: "kleis/matrix_gpu_shim.h".}

when defined(kleisGpuSoftwareTest):
  proc gpuOpenSoftwareTest(): pointer {.
    importc: "kleis_matrix_gpu_open_software_test", header: "kleis/matrix_gpu_shim.h"
  .}

proc gpuIdentity(
  handle: pointer
): cstring {.importc: "kleis_matrix_gpu_identity", header: "kleis/matrix_gpu_shim.h".}

proc gpuTargetCreate(
  handle: pointer,
  width, height, cellWidth, cellHeight, glyphCount: int32,
  atlasPixels: ptr UncheckedArray[uint8],
  atlasWidth, atlasHeight: int32,
): pointer {.
  importc: "kleis_matrix_gpu_target_create", header: "kleis/matrix_gpu_shim.h"
.}

proc gpuFrameCreate(
  handle: pointer, width, height: int32
): pointer {.
  importc: "kleis_matrix_gpu_frame_create", header: "kleis/matrix_gpu_shim.h"
.}

proc gpuHandsOff(
  handle: pointer
): int32 {.importc: "kleis_matrix_gpu_hands_off", header: "kleis/matrix_gpu_shim.h".}

proc gpuFrameMap(
  handle, frame: pointer
): ptr UncheckedArray[uint32] {.
  importc: "kleis_matrix_gpu_frame_map", header: "kleis/matrix_gpu_shim.h"
.}

proc gpuFrameUnmap(
  handle, frame: pointer
): int32 {.importc: "kleis_matrix_gpu_frame_unmap", header: "kleis/matrix_gpu_shim.h".}

proc gpuFrameRead(
  handle, frame: pointer, pixels: ptr UncheckedArray[uint32]
): int32 {.importc: "kleis_matrix_gpu_frame_read", header: "kleis/matrix_gpu_shim.h".}

proc gpuFrameDestroy(
  handle, frame: pointer
) {.importc: "kleis_matrix_gpu_frame_destroy", header: "kleis/matrix_gpu_shim.h".}

when defined(kleisGpuSoftwareTest):
  proc gpuTestFailNextRender() {.
    importc: "kleis_matrix_gpu_test_fail_next_render", header: "kleis/matrix_gpu_shim.h"
  .}

  proc gpuTestDeviceOpen(): int32 {.
    importc: "kleis_matrix_gpu_test_device_open", header: "kleis/matrix_gpu_shim.h"
  .}

  proc gpuTestCopyReadback(
    copy: int32
  ) {.
    importc: "kleis_matrix_gpu_test_copy_readback", header: "kleis/matrix_gpu_shim.h"
  .}

  proc gpuTestMarks(
    handle, target, frame: pointer
  ): int32 {.importc: "kleis_matrix_gpu_test_marks", header: "kleis/matrix_gpu_shim.h".}

proc gpuTargetRender(
  handle, target, frame: pointer,
  timeSeconds: cdouble,
  fallSpeed, cycleSpeed, raindropLength, brightnessDecay: cfloat,
): int32 {.
  importc: "kleis_matrix_gpu_target_render", header: "kleis/matrix_gpu_shim.h"
.}

proc gpuTargetClear(
  handle, target, frame: pointer, red, green, blue: cfloat
): int32 {.importc: "kleis_matrix_gpu_target_clear", header: "kleis/matrix_gpu_shim.h".}

proc gpuTargetDestroy(
  handle, target: pointer
) {.importc: "kleis_matrix_gpu_target_destroy", header: "kleis/matrix_gpu_shim.h".}

proc gpuClose(
  handle: pointer
) {.importc: "kleis_matrix_gpu_close", header: "kleis/matrix_gpu_shim.h".}

proc gpuLastError(): cstring {.
  importc: "kleis_matrix_gpu_last_error", header: "kleis/matrix_gpu_shim.h"
.}

proc gpuIsSoftwareRenderer(
  renderer: cstring
): int32 {.
  importc: "kleis_matrix_gpu_is_software_renderer", header: "kleis/matrix_gpu_shim.h"
.}

proc isSoftwareRenderer*(renderer: string): bool =
  ## The production open refuses these: a grant must give a hardware GPU.
  gpuIsSoftwareRenderer(renderer.cstring) != 0

proc matrixGpuLastError*(): string =
  $gpuLastError()

proc isOpen*(gpu: MatrixGpu): bool =
  not gpu.handle.isNil

proc isNil*(target: MatrixGpuTarget): bool =
  target.handle.isNil

proc isNil*(frame: MatrixGpuFrame): bool =
  frame.handle.isNil

proc openMatrixGpu*(renderNode: string, major, minor: int64): MatrixGpu =
  ## Exactly the granted node, or nothing: check isOpen, then the last error.
  MatrixGpu(handle: gpuOpen(renderNode.cstring, major, minor))

when defined(kleisGpuSoftwareTest):
  proc openMatrixGpuSoftwareTest*(): MatrixGpu =
    MatrixGpu(handle: gpuOpenSoftwareTest())

proc identity*(gpu: MatrixGpu): string =
  if gpu.isOpen:
    $gpuIdentity(gpu.handle)
  else:
    ""

proc createTarget*(
    gpu: MatrixGpu, width, height: int, atlas: MatrixGlyphAtlas
): MatrixGpuTarget =
  ## One output at full size with the atlas's cell size.
  if not gpu.isOpen or atlas.pixels.len == 0:
    return
  let handle = gpuTargetCreate(
    gpu.handle,
    width.int32,
    height.int32,
    atlas.cellWidth.int32,
    atlas.cellHeight.int32,
    atlas.glyphCount.int32,
    cast[ptr UncheckedArray[uint8]](unsafeAddr atlas.pixels[0]),
    atlas.width.int32,
    atlas.height.int32,
  )
  if not handle.isNil:
    result = MatrixGpuTarget(
      handle: handle, width: width, height: height, cellSize: atlas.cellWidth
    )

proc createFrame*(gpu: MatrixGpu, width, height: int): MatrixGpuFrame =
  ## A readback buffer for frames of this size; check isNil.
  if gpu.isOpen:
    let handle = gpuFrameCreate(gpu.handle, width.int32, height.int32)
    if not handle.isNil:
      result = MatrixGpuFrame(handle: handle, width: width, height: height)

proc handsOff*(gpu: MatrixGpu): bool =
  ## Whether a mapped frame is the frame itself (BGRA readback).
  gpu.isOpen and gpuHandsOff(gpu.handle) != 0

proc map*(gpu: MatrixGpu, frame: MatrixGpuFrame): ptr UncheckedArray[uint32] =
  ## Waits for the frame's readback and maps it: 0xAARRGGBB words, top row
  ## first, valid and unchanged until unmap or destroy. Nil on failure.
  gpuFrameMap(gpu.handle, frame.handle)

proc unmap*(gpu: MatrixGpu, frame: MatrixGpuFrame): bool =
  ## False when the mapping's contents were lost or GL failed.
  gpuFrameUnmap(gpu.handle, frame.handle) != 0

proc read*(
    gpu: MatrixGpu, frame: MatrixGpuFrame, pixels: ptr UncheckedArray[uint32]
): bool =
  ## Waits for the frame's readback and copies it as 0xAARRGGBB words.
  gpuFrameRead(gpu.handle, frame.handle, pixels) != 0

proc destroy*(gpu: MatrixGpu, frame: var MatrixGpuFrame) =
  ## Unmaps it if mapped, then frees it.
  if not frame.handle.isNil:
    gpuFrameDestroy(gpu.handle, frame.handle)
    frame.handle = nil

when defined(kleisGpuSoftwareTest):
  proc failNextGpuRender*() =
    ## Tests only: the open device's next render fails, as a GPU fault would.
    gpuTestFailNextRender()

  proc gpuDeviceOpen*(): bool =
    ## Tests only: whether a device is open, from any thread.
    gpuTestDeviceOpen() != 0

  proc copyGpuReadback*(copy: bool) =
    ## Tests only: devices opened from now copy an RGBA readback.
    gpuTestCopyReadback(int32(copy))

  proc marks*(gpu: MatrixGpu, target: MatrixGpuTarget, frame: MatrixGpuFrame): bool =
    ## Tests only: asymmetric corner marks and their readback.
    gpuTestMarks(gpu.handle, target.handle, frame.handle) != 0

proc render*(
    gpu: MatrixGpu,
    target: MatrixGpuTarget,
    frame: MatrixGpuFrame,
    motion: MatrixMotion,
    seconds, elapsedSeconds: float,
): bool =
  ## Queues the frame at `seconds` and its readback into `frame`. The shaders
  ## step glyph age and brightness once per frame, so those two take the
  ## share of the per-reference-frame rates that `elapsedSeconds` covers.
  let frames = max(elapsedSeconds, 0.0) / MatrixReferenceFrameSeconds
  gpuTargetRender(
    gpu.handle,
    target.handle,
    frame.handle,
    cdouble(seconds),
    cfloat(motion.fallSpeed),
    cfloat(max(motion.cycleSpeed, 0.001) * frames),
    cfloat(motion.raindropLength),
    cfloat(decayBlend(motion.brightnessDecay, elapsedSeconds)),
  ) != 0

proc clear*(
    gpu: MatrixGpu, target: MatrixGpuTarget, frame: MatrixGpuFrame, color: uint32
): bool =
  ## Queues one opaque 0xRRGGBB colour and its readback into `frame`.
  gpuTargetClear(
    gpu.handle,
    target.handle,
    frame.handle,
    cfloat(float((color shr 16) and 0xff) / 255.0),
    cfloat(float((color shr 8) and 0xff) / 255.0),
    cfloat(float(color and 0xff) / 255.0),
  ) != 0

proc destroy*(gpu: MatrixGpu, target: var MatrixGpuTarget) =
  if not target.handle.isNil:
    gpuTargetDestroy(gpu.handle, target.handle)
    target.handle = nil

proc close*(gpu: var MatrixGpu) =
  if gpu.isOpen:
    gpuClose(gpu.handle)
    gpu.handle = nil
