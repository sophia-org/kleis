import std/[math, unittest]

import ../src/kleis/matrix
import ../src/kleis/matrix_render

const motion = MatrixMotion(
  fallSpeed: 0.3, cycleSpeed: 0.03, raindropLength: 0.75, brightnessDecay: 1.0
)

proc rendered(field: MatrixField, seconds: float, width, height: int): seq[uint32] =
  result = newSeq[uint32](width * height)
  let atlas = buildMatrixGlyphAtlas(initMatrixRenderer(matrixCellScale(0.0, width)))
  renderMatrixField(
    field,
    motion,
    seconds,
    atlas,
    cast[ptr UncheckedArray[uint32]](addr result[0]),
    width,
    height,
  )

suite "time-based matrix":
  test "automatic cells give 80 columns on each output; a fixed scale is fixed":
    check matrixCellSize(0.0, 2560) == 32
    check matrixCellSize(0.0, 1920) == 24
    check matrixFieldFor(0.0, 2560, 1440).cols == 80
    check matrixFieldFor(0.0, 1920, 1080).cols == 80
    check matrixCellSize(2.0, 1920) == 16
    check matrixCellSize(2.0, 2560) == 16

  test "brightness is a function of time alone":
    for col in [0, 7, 79]:
      for row in [0, 12, 44]:
        let a = rainBrightness(motion, 12.5, col, row, 45)
        check a == rainBrightness(motion, 12.5, col, row, 45)
        check a >= 0.0 and a <= 1.0
    var moved = false
    for col in 0 ..< 10:
      if rainBrightness(motion, 1.0, col, 3, 45) !=
          rainBrightness(motion, 1.5, col, 3, 45):
        moved = true
    check moved

  test "a faster fall moves the rain further in the same time":
    var fast = motion
    fast.fallSpeed = 0.6
    for col in 0 ..< 20:
      check abs(
        rainBrightness(fast, 2.0, col, 5, 45) - rainBrightness(motion, 4.0, col, 5, 45)
      ) < 1e-9

  test "decay compounds over elapsed time, not over frames":
    check decayBlend(1.0, 0.04) == 1.0
    check abs(decayBlend(0.5, MatrixReferenceFrameSeconds) - 0.5) < 1e-12
    check abs(decayBlend(0.5, 2 * MatrixReferenceFrameSeconds) - 0.75) < 1e-12
    check decayBlend(0.5, 0.0) == 0.0
    check decayBlend(0.0, 5.0) == 0.0

  test "full decay shows exactly the brightness of the moment":
    var field = initMatrixField(5, 4)
    field.step(motion, 3.0)
    field.step(motion, 9.0)
    for i in 0 ..< field.brightness.len:
      check abs(
        float(field.brightness[i]) - rainBrightness(motion, 9.0, i mod 5, i div 5, 4)
      ) < 1e-6

  test "glyphs cycle at the cycle speed":
    var changes = 0
    for col in 0 ..< 40:
      if rainSymbol(motion, 0.0, col, 3, 34) != rainSymbol(motion, 10.0, col, 3, 34):
        inc changes
      check rainSymbol(motion, 5.0, col, 3, 34) in 0 .. 33
    check changes > 20
    var still = motion
    still.cycleSpeed = 0.001
    var stillChanges = 0
    for col in 0 ..< 40:
      if rainSymbol(still, 0.0, col, 3, 34) != rainSymbol(still, 0.04, col, 3, 34):
        inc stillChanges
    check stillChanges <= 2

  test "a frame depends only on its time: no catch-up, opaque, black background":
    var a = matrixFieldFor(0.0, 640, 360)
    var b = matrixFieldFor(0.0, 640, 360)
    a.step(motion, 7.0)
    b.step(motion, 1.0)
    b.step(motion, 7.0) # a late frame after a gap
    let pa = rendered(a, 7.0, 640, 360)
    check pa == rendered(b, 7.0, 640, 360)
    var lit = 0
    for pixel in pa:
      check (pixel shr 24) == 0xff
      if pixel != 0xff000000'u32:
        inc lit
    check lit > 0
    check lit < pa.len
