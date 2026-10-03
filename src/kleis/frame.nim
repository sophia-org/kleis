## One output's image for Sophia: premultiplied BGRA8, rows of width * 4
## bytes, exactly the allocation's pixel size (spec: sophia-lock-files.md).
## Pixels are 0xAARRGGBB words, which little-endian memory stores as B, G, R,
## A; every pixel is opaque, so premultiplication changes nothing.

import ./matrix
import ./matrix_render
import ./ui

when cpuEndian != littleEndian:
  {.error: "kleis writes BGRA8 as little-endian 0xAARRGGBB words".}

type OutputFrame* = object
  width*, height*: int
  rain*: MatrixRain
  pixels*: seq[uint32]

proc initOutputFrame*(
    width, height: int, renderer: MatrixRenderer, seed = 0'i64
): OutputFrame =
  ## Refuses a size the renderer cannot hold. A zero seed takes the clock.
  let layout = matrixShmBufferLayout(width, height)
  if not layout.valid:
    raise newException(ValueError, "allocation size out of range")
  let geometry = matrixRenderGeometry(width, height, renderer)
  result.width = width
  result.height = height
  result.rain =
    if seed == 0:
      initMatrixRain(geometry.cols, geometry.rows)
    else:
      initMatrixRain(geometry.cols, geometry.rows, seed)
  result.pixels = newSeq[uint32](width * height)

proc render*(frame: var OutputFrame, view: View, renderer: MatrixRenderer) =
  case view.kind
  of vkMatrix:
    renderMatrix(
      frame.rain,
      renderer,
      cast[ptr UncheckedArray[uint32]](addr frame.pixels[0]),
      frame.width,
      frame.height,
    )
  of vkSolid:
    let pixel = 0xff000000'u32 or (view.color and 0x00ffffff'u32)
    for i in 0 ..< frame.pixels.len:
      frame.pixels[i] = pixel

proc byteCount*(frame: OutputFrame): int =
  frame.pixels.len * 4

proc bytes*(frame: var OutputFrame): ptr UncheckedArray[byte] =
  ## The upload's bytes, valid until the frame is resized or destroyed.
  cast[ptr UncheckedArray[byte]](addr frame.pixels[0])
