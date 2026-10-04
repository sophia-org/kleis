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

proc gpuTargetRender(
  handle, target: pointer,
  timeSeconds: cdouble,
  fallSpeed, cycleSpeed, raindropLength, brightnessDecay: cfloat,
): int32 {.
  importc: "kleis_matrix_gpu_target_render", header: "kleis/matrix_gpu_shim.h"
.}

proc gpuTargetClear(
  handle, target: pointer, red, green, blue: cfloat
): int32 {.importc: "kleis_matrix_gpu_target_clear", header: "kleis/matrix_gpu_shim.h".}

proc gpuTargetRead(
  handle, target: pointer, pixels: ptr UncheckedArray[uint32]
): int32 {.importc: "kleis_matrix_gpu_target_read", header: "kleis/matrix_gpu_shim.h".}

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

proc render*(
    gpu: MatrixGpu,
    target: MatrixGpuTarget,
    motion: MatrixMotion,
    seconds, elapsedSeconds: float,
): bool =
  ## Queues the frame at `seconds` and its readback. The shaders step glyph
  ## age and brightness once per frame, so those two take the share of the
  ## per-reference-frame rates that `elapsedSeconds` covers.
  let frames = max(elapsedSeconds, 0.0) / MatrixReferenceFrameSeconds
  gpuTargetRender(
    gpu.handle,
    target.handle,
    cdouble(seconds),
    cfloat(motion.fallSpeed),
    cfloat(max(motion.cycleSpeed, 0.001) * frames),
    cfloat(motion.raindropLength),
    cfloat(decayBlend(motion.brightnessDecay, elapsedSeconds)),
  ) != 0

proc clear*(gpu: MatrixGpu, target: MatrixGpuTarget, color: uint32): bool =
  ## Queues one opaque 0xRRGGBB colour and its readback.
  gpuTargetClear(
    gpu.handle,
    target.handle,
    cfloat(float((color shr 16) and 0xff) / 255.0),
    cfloat(float((color shr 8) and 0xff) / 255.0),
    cfloat(float(color and 0xff) / 255.0),
  ) != 0

proc read*(
    gpu: MatrixGpu, target: MatrixGpuTarget, pixels: ptr UncheckedArray[uint32]
): bool =
  ## Waits for the last queued frame and writes it as 0xAARRGGBB words.
  gpuTargetRead(gpu.handle, target.handle, pixels) != 0

proc destroy*(gpu: MatrixGpu, target: var MatrixGpuTarget) =
  if not target.handle.isNil:
    gpuTargetDestroy(gpu.handle, target.handle)
    target.handle = nil

proc close*(gpu: var MatrixGpu) =
  if gpu.isOpen:
    gpuClose(gpu.handle)
    gpu.handle = nil
