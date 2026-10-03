import std/unittest

import ../src/kleis/frame
import ../src/kleis/matrix
import ../src/kleis/matrix_render
import ../src/kleis/ui

suite "frame":
  test "a solid view fills every pixel opaque, in BGRA byte order":
    let renderer = initMatrixRenderer(1.0)
    var frame = initOutputFrame(3, 2, renderer, seed = 7)
    frame.render(View(kind: vkSolid, color: 0x123456'u32), renderer)
    check frame.byteCount == 3 * 2 * 4
    let bytes = frame.bytes
    for i in 0 ..< 6:
      check bytes[i * 4 + 0] == 0x56 # blue
      check bytes[i * 4 + 1] == 0x34 # green
      check bytes[i * 4 + 2] == 0x12 # red
      check bytes[i * 4 + 3] == 0xff # alpha

  test "the image is exactly the allocation, not the glyph grid":
    let renderer = initMatrixRenderer(1.0)
    var frame = initOutputFrame(101, 37, renderer, seed = 7)
    frame.render(View(kind: vkMatrix), renderer)
    check frame.pixels.len == 101 * 37
    for pixel in frame.pixels:
      check (pixel shr 24) == 0xff'u32

  test "a fixed seed renders the same Matrix":
    let renderer = initMatrixRenderer(2.0)
    var a = initOutputFrame(320, 200, renderer, seed = 42)
    var b = initOutputFrame(320, 200, renderer, seed = 42)
    for _ in 0 ..< 5:
      a.rain.advance()
      b.rain.advance()
    a.render(View(kind: vkMatrix), renderer)
    b.render(View(kind: vkMatrix), renderer)
    check a.pixels == b.pixels
    var lit = 0
    for pixel in a.pixels:
      if (pixel and 0x00ffffff'u32) != 0:
        inc lit
    check lit > 0

  test "an allocation the renderer cannot hold is refused":
    let renderer = initMatrixRenderer(1.0)
    expect ValueError:
      discard initOutputFrame(0, 10, renderer)
    expect ValueError:
      discard initOutputFrame(16385, 10, renderer)
