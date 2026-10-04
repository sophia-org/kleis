import std/math

import ./matrix
import ./font64x128

type
  MatrixRenderGeometry* = object
    width*, height*: int
    cols*, rows*: int
    scale*: float

  MatrixShmBufferLayout* = object
    valid*: bool
    stride*: int
    size*: int

  MatrixRenderer* = ref object
    scale*: float

  MatrixGlyphAtlas* = object
    cellWidth*, cellHeight*: int
    width*, height*: int
    glyphCount*: int
    pixels*: seq[uint8]

const
  GlyphWidth = 8
  GlyphHeight = 8
  MatrixTargetColumns* = 80
  MatrixShmMaxDimension* = 16384
  MatrixShmBytesPerPixel = 4

proc matrixShmBufferLayout*(width, height: int): MatrixShmBufferLayout =
  if width <= 0 or height <= 0:
    return
  if width > MatrixShmMaxDimension or height > MatrixShmMaxDimension:
    return

  let stride64 = int64(width) * int64(MatrixShmBytesPerPixel)
  let size64 = stride64 * int64(height)
  if stride64 > int64(high(int32)) or size64 > int64(high(int32)):
    return

  MatrixShmBufferLayout(valid: true, stride: int(stride64), size: int(size64))

proc scaledDimension(base: int, scale: float): int =
  max(1, int(float(base) * max(scale, 1.0) + 0.5))

proc matrixAutoScale*(surfaceWidth: int): float =
  max(1.0, float(max(surfaceWidth, 0)) / float(MatrixTargetColumns * GlyphWidth))

proc matrixEffectiveScale*(configuredScale: float, surfaceWidth: int): float =
  if configuredScale > 0.0:
    max(configuredScale, 1.0)
  else:
    matrixAutoScale(surfaceWidth)

proc matrixRenderGeometry*(
    surfaceWidth, surfaceHeight: int, scale = 1.0
): MatrixRenderGeometry =
  let cellScale = max(scale, 1.0)
  let cellWidth = scaledDimension(GlyphWidth, cellScale)
  let cellHeight = scaledDimension(GlyphHeight, cellScale)
  result.scale = cellScale
  result.cols = max(surfaceWidth, 0) div cellWidth
  result.rows = max(surfaceHeight, 0) div cellHeight
  result.width = result.cols * cellWidth
  result.height = result.rows * cellHeight

proc initMatrixRenderer*(bitmapScale: float): MatrixRenderer =
  MatrixRenderer(scale: max(bitmapScale, 1.0))

proc close*(renderer: MatrixRenderer) =
  discard

proc matrixRenderGeometry*(
    surfaceWidth, surfaceHeight: int, renderer: MatrixRenderer
): MatrixRenderGeometry =
  let scale = if renderer.isNil: 1.0 else: renderer.scale
  matrixRenderGeometry(surfaceWidth, surfaceHeight, scale)

proc drawScaledGlyph(
  data: ptr UncheckedArray[uint32],
  width, height: int,
  x, y: int,
  glyphIdx: int,
  color: uint32,
  cellWidth, cellHeight: int,
  font: HighResFont,
)

proc drawGlyph*(
    data: ptr UncheckedArray[uint32],
    width, height: int,
    x, y: int,
    glyphIdx: int,
    color: uint32,
    scale = 1,
) =
  if glyphIdx < 0 or glyphIdx >= KoineHighResFont.len:
    return
  let cellScale = max(scale, 1)
  drawScaledGlyph(
    data,
    width,
    height,
    x,
    y,
    glyphIdx,
    color,
    GlyphWidth * cellScale,
    GlyphHeight * cellScale,
    KoineHighResFont,
  )

proc highResGlyphAlpha(glyph: HighResGlyph, x, y: int): float =
  if x < 0 or x >= HighResGlyphWidth or y < 0 or y >= HighResGlyphHeight:
    return 0.0
  float(glyph[y * HighResGlyphWidth + x]) / 255.0

proc sampleHighResGlyph(glyph: HighResGlyph, srcX, srcY: float): uint8 =
  let x = srcX - 0.5
  let y = srcY - 0.5
  let x0 = int(floor(x))
  let y0 = int(floor(y))
  let fx = x - float(x0)
  let fy = y - float(y0)
  let a00 = highResGlyphAlpha(glyph, x0, y0)
  let a10 = highResGlyphAlpha(glyph, x0 + 1, y0)
  let a01 = highResGlyphAlpha(glyph, x0, y0 + 1)
  let a11 = highResGlyphAlpha(glyph, x0 + 1, y0 + 1)
  let top = a00 * (1.0 - fx) + a10 * fx
  let bottom = a01 * (1.0 - fx) + a11 * fx
  uint8(int((top * (1.0 - fy) + bottom * fy) * 255.0 + 0.5))

proc div255Floor(x: uint32): uint32 {.inline.} =
  ((x + 1'u32) * 257'u32) shr 16

proc scaledColor(color: uint32, alpha: uint8): uint32 {.inline.} =
  let a = uint32(alpha)
  let r = div255Floor(((color shr 16) and 0xff'u32) * a)
  let g = div255Floor(((color shr 8) and 0xff'u32) * a)
  let b = div255Floor((color and 0xff'u32) * a)
  0xff000000'u32 or (r shl 16) or (g shl 8) or b

proc drawHighResGlyphAlpha(
    atlas: var MatrixGlyphAtlas, glyphIdx, cellX: int, font: HighResFont
) =
  if glyphIdx < 0 or glyphIdx >= font.len:
    return
  let glyph = font[glyphIdx]
  let scaleX = float(HighResGlyphWidth) / float(atlas.cellWidth)
  let scaleY = float(HighResGlyphHeight) / float(atlas.cellHeight)
  for row in 0 ..< atlas.cellHeight:
    let srcY = (float(row) + 0.5) * scaleY
    for col in 0 ..< atlas.cellWidth:
      let srcX = (float(col) + 0.5) * scaleX
      atlas.pixels[row * atlas.width + cellX + col] =
        sampleHighResGlyph(glyph, srcX, srcY)

proc buildMatrixGlyphAtlas*(renderer: MatrixRenderer): MatrixGlyphAtlas =
  result.glyphCount = MatrixGlyphs.len
  let scale = if renderer.isNil: 1.0 else: renderer.scale
  result.cellWidth = scaledDimension(GlyphWidth, scale)
  result.cellHeight = scaledDimension(GlyphHeight, scale)
  result.width = result.cellWidth * result.glyphCount
  result.height = result.cellHeight
  result.pixels = newSeq[uint8](result.width * result.height)
  for glyphIdx in 0 ..< result.glyphCount:
    result.drawHighResGlyphAlpha(
      glyphIdx, glyphIdx * result.cellWidth, KoineHighResFont
    )

proc renderMatrix*(
    rain: MatrixRain, data: ptr UncheckedArray[uint32], width, height: int, scale = 1
) =
  # Clear buffer to black
  # explicit_bzero or just loop. Since we are drawing characters, we can just clear.
  # For performance, maybe only clear what changed, but simple is better for now.
  for i in 0 ..< width * height:
    data[i] = 0xff000000'u32

  let cellScale = max(scale, 1)
  let cellWidth = GlyphWidth * cellScale
  let cellHeight = GlyphHeight * cellScale
  let trailColor = 0xff00aa00'u32
  let headColor = 0xff80ff80'u32

  for xIdx, column in rain.columns:
    let x = xIdx * cellWidth
    if x >= width:
      break
    if column.headRow < 0:
      continue

    let visibleTop = max(0, column.tailRow)
    let visibleBottom = min(rain.height - 1, column.headRow)

    for yIdx in visibleTop .. visibleBottom:
      let y = yIdx * cellHeight
      if y >= height:
        break
      let color = if yIdx == column.headRow: headColor else: trailColor
      drawGlyph(data, width, height, x, y, column.glyphs[yIdx], color, cellScale)

proc drawScaledGlyph(
    data: ptr UncheckedArray[uint32],
    width, height: int,
    x, y: int,
    glyphIdx: int,
    color: uint32,
    cellWidth, cellHeight: int,
    font: HighResFont,
) =
  if glyphIdx < 0 or glyphIdx >= font.len:
    return
  let glyph = font[glyphIdx]
  let scaleX = float(HighResGlyphWidth) / float(cellWidth)
  let scaleY = float(HighResGlyphHeight) / float(cellHeight)
  for row in 0 ..< cellHeight:
    let ty = y + row
    if ty < 0 or ty >= height:
      continue
    let srcY = (float(row) + 0.5) * scaleY
    for col in 0 ..< cellWidth:
      let tx = x + col
      if tx < 0 or tx >= width:
        continue
      let srcX = (float(col) + 0.5) * scaleX
      let alpha = sampleHighResGlyph(glyph, srcX, srcY)
      if alpha != 0:
        data[ty * width + tx] = scaledColor(color, alpha)

proc renderMatrixScaled(
    rain: MatrixRain,
    data: ptr UncheckedArray[uint32],
    width, height: int,
    scale: float,
    font: HighResFont,
) =
  for i in 0 ..< width * height:
    data[i] = 0xff000000'u32

  let cellScale = max(scale, 1.0)
  let cellWidth = scaledDimension(GlyphWidth, cellScale)
  let cellHeight = scaledDimension(GlyphHeight, cellScale)
  let trailColor = 0xff00aa00'u32
  let headColor = 0xff80ff80'u32

  for xIdx, column in rain.columns:
    let x = xIdx * cellWidth
    if x >= width:
      break
    if column.headRow < 0:
      continue

    let visibleTop = max(0, column.tailRow)
    let visibleBottom = min(rain.height - 1, column.headRow)

    for yIdx in visibleTop .. visibleBottom:
      let y = yIdx * cellHeight
      if y >= height:
        break
      let color = if yIdx == column.headRow: headColor else: trailColor
      drawScaledGlyph(
        data,
        width,
        height,
        x,
        y,
        column.glyphs[yIdx],
        color,
        cellWidth,
        cellHeight,
        font,
      )

proc renderMatrix*(
    rain: MatrixRain,
    renderer: MatrixRenderer,
    data: ptr UncheckedArray[uint32],
    width, height: int,
) =
  let scale = if renderer.isNil: 1.0 else: renderer.scale
  renderMatrixScaled(rain, data, width, height, scale, KoineHighResFont)

# Time-based rendering (see MatrixField). Each output has its own cell size:
# automatic scaling gives MatrixTargetColumns columns on that output, and a
# configured scale is a fixed cell (scale 2 is a 16-pixel cell).

proc matrixCellScale*(configuredScale: float, outputWidth: int): float =
  matrixEffectiveScale(configuredScale, outputWidth)

proc matrixCellSize*(configuredScale: float, outputWidth: int): int =
  scaledDimension(GlyphWidth, matrixCellScale(configuredScale, outputWidth))

proc matrixFieldFor*(configuredScale: float, width, height: int): MatrixField =
  let cell = matrixCellSize(configuredScale, width)
  initMatrixField(max(width, 0) div cell, max(height, 0) div cell)

proc channel(value: float): uint32 {.inline.} =
  uint32(clamp(int(value * 255.0 + 0.5), 0, 255))

proc renderMatrixField*(
    field: MatrixField,
    motion: MatrixMotion,
    seconds: float,
    atlas: MatrixGlyphAtlas,
    data: ptr UncheckedArray[uint32],
    width, height: int,
) =
  ## Draws `field` (already stepped to `seconds`) as opaque 0xAARRGGBB words,
  ## with the GPU final pass's colours: a dim green trail and a pale head.
  for i in 0 ..< width * height:
    data[i] = 0xff000000'u32
  let cellWidth = atlas.cellWidth
  let cellHeight = atlas.cellHeight
  if cellWidth <= 0 or cellHeight <= 0 or atlas.glyphCount <= 0:
    return
  for row in 0 ..< field.rows:
    for col in 0 ..< field.cols:
      let brightness = float(field.brightness[row * field.cols + col]) * 1.1 - 0.5
      if brightness <= 0.0:
        continue
      let (red, green, blue) =
        if rainCursor(motion, seconds, col, row, field.rows):
          let level = max(brightness, 0.55)
          (0.86 * level, level, 0.86 * level)
        else:
          (0.0, 0.82 * brightness, 0.04 * brightness)
      let glyph = rainSymbol(motion, seconds, col, row, atlas.glyphCount)
      let x0 = col * cellWidth
      let y0 = row * cellHeight
      for y in 0 ..< cellHeight:
        let ty = y0 + y
        if ty >= height:
          break
        for x in 0 ..< cellWidth:
          let tx = x0 + x
          if tx >= width:
            break
          let coverage = atlas.pixels[y * atlas.width + glyph * cellWidth + x]
          if coverage <= 2'u8:
            continue
          let a = float(coverage) / 255.0
          data[ty * width + tx] =
            0xff000000'u32 or (channel(red * a) shl 16) or (channel(green * a) shl 8) or
            channel(blue * a)
