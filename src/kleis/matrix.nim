import std/[math, random, times]

const
  MatrixMinStreamLength* = 3
  MatrixFrameStepMs* = 160
  MatrixGlyphs*: seq[string] = @[
    "α", "β", "γ", "δ", "ε", "ζ", "η", "θ", "ι", "κ", "λ", "μ", "ν", "ξ",
    "ο", "π", "ρ", "σ", "ς", "τ", "υ", "φ", "χ", "ψ", "ω", "ϲ", "ϛ", "ϟ",
    "ϗ", "⳨", "\uE000", "\uE001", "͵", "\u0305",
  ]

type
  MatrixColumn* = object
    gapRemaining*: int
    length*: int
    updateEvery*: int
    phase*: int
    headRow*: int
    tailRow*: int
    glyphs*: seq[int] # Indices into MatrixGlyphs

  MatrixRain* = object
    width*: int
    height*: int
    tick*: uint64
    columns*: seq[MatrixColumn]
    rng*: Rand

  MatrixTicker* = object
    armed*: bool
    nextAtMs*: int64

proc matrixFrameTimeoutMs*(
    ticker: var MatrixTicker, visible: bool, nowMs: int64, frameMs: int
): int =
  if not visible:
    ticker.armed = false
    return -1
  if not ticker.armed:
    ticker.armed = true
    ticker.nextAtMs = nowMs
  let remaining = ticker.nextAtMs - nowMs
  if remaining <= 0:
    0
  elif remaining > int64(high(cint)):
    high(cint)
  else:
    int(remaining)

proc matrixFrameDue*(
    ticker: var MatrixTicker, visible: bool, nowMs: int64, frameMs: int
): bool =
  if not visible:
    ticker.armed = false
    return false
  if not ticker.armed:
    ticker.armed = true
    ticker.nextAtMs = nowMs
  if ticker.nextAtMs > nowMs:
    return false
  ticker.nextAtMs = nowMs + int64(max(frameMs, 1))
  true

proc resetColumn(rain: var MatrixRain, columnIdx: int, height: int) =
  if height <= 0:
    rain.columns[columnIdx] = MatrixColumn(
      gapRemaining: 0,
      length: 0,
      updateEvery: 1,
      phase: 0,
      headRow: -1,
      tailRow: 0,
      glyphs: @[],
    )
    return

  if rain.columns[columnIdx].glyphs.len != height:
    rain.columns[columnIdx].glyphs.setLen(height)

  let lengthMax = max(MatrixMinStreamLength, height - 3)
  let length = MatrixMinStreamLength + rain.rng.rand(lengthMax - MatrixMinStreamLength)
  rain.columns[columnIdx].gapRemaining = 1 + rain.rng.rand(height - 1)
  rain.columns[columnIdx].length = length
  rain.columns[columnIdx].updateEvery = 1 + rain.rng.rand(2)
  rain.columns[columnIdx].phase = (columnIdx * 3 + rain.rng.rand(6)) mod 3
  rain.columns[columnIdx].headRow = -1
  rain.columns[columnIdx].tailRow = 0

proc makeColumn*(rain: var MatrixRain, height: int, columnIdx: int): MatrixColumn =
  if height <= 0:
    return MatrixColumn(
      gapRemaining: 0,
      length: 0,
      updateEvery: 1,
      phase: 0,
      headRow: -1,
      tailRow: 0,
      glyphs: @[],
    )
  let lengthMax = max(MatrixMinStreamLength, height - 3)
  let length = MatrixMinStreamLength + rain.rng.rand(lengthMax - MatrixMinStreamLength)
  result = MatrixColumn(
    gapRemaining: 1 + rain.rng.rand(height - 1),
    length: length,
    updateEvery: 1 + rain.rng.rand(2),
    phase: (columnIdx * 3 + rain.rng.rand(6)) mod 3,
    headRow: -1,
    tailRow: 0,
    glyphs: newSeq[int](height),
  )

proc advanceColumn(rain: var MatrixRain, columnIdx: int) =
  if rain.height == 0:
    return
  let height = rain.height

  if rain.columns[columnIdx].gapRemaining > 0:
    rain.columns[columnIdx].gapRemaining -= 1
    return

  if rain.columns[columnIdx].headRow < 0:
    let gIdx = rain.rng.rand(MatrixGlyphs.len - 1)
    rain.columns[columnIdx].headRow = 0
    rain.columns[columnIdx].tailRow = 0
    rain.columns[columnIdx].glyphs[0] = gIdx
    return

  rain.columns[columnIdx].headRow += 1
  let headRow = rain.columns[columnIdx].headRow

  if headRow < height:
    let gIdx = rain.rng.rand(MatrixGlyphs.len - 1)
    rain.columns[columnIdx].glyphs[headRow] = gIdx

  if headRow - rain.columns[columnIdx].tailRow + 1 > rain.columns[columnIdx].length:
    rain.columns[columnIdx].tailRow += 1

  let head = min(headRow, height - 1)
  let tail = max(0, rain.columns[columnIdx].tailRow)
  for row in tail ..< head:
    if rain.rng.rand(7) == 0:
      rain.columns[columnIdx].glyphs[row] = rain.rng.rand(MatrixGlyphs.len - 1)

  if rain.columns[columnIdx].tailRow >= height:
    rain.resetColumn(columnIdx, height)

proc advance*(rain: var MatrixRain) =
  rain.tick = rain.tick + 1
  for i in 0 ..< rain.columns.len:
    if i mod 2 == 1:
      continue
    let updateEvery = rain.columns[i].updateEvery
    let phase = rain.columns[i].phase
    if (int(rain.tick) + phase) mod updateEvery != 0:
      continue
    rain.advanceColumn(i)

proc initMatrixRain*(width, height: int, seed: int64): MatrixRain =
  ## A fixed seed gives the same rain every run, for the headless harness.
  result = MatrixRain(width: width, height: height, tick: 0, rng: initRand(seed))
  result.columns = newSeq[MatrixColumn](width)
  for i in 0 ..< width:
    result.columns[i].glyphs = newSeq[int](height)
    result.resetColumn(i, height)

  let warmupSteps = max(1, height + MatrixMinStreamLength + 2)
  for _ in 0 ..< warmupSteps:
    result.advance()

proc initMatrixRain*(width, height: int): MatrixRain =
  initMatrixRain(
    width, height, now().toTime().toUnix() xor (width.int64 shl 32 or height.int64)
  )

# Time-based rain. It mirrors the GPU shaders (matrix_gpu_shim.c), so the CPU
# fallback honors the same fall, cycle, trail and decay settings. Every value
# is a function of monotonic elapsed time: a late frame shows the rain where
# it is now, never a catch-up of the frames it missed.

const MatrixReferenceFrameSeconds* = 0.040
  ## Cycle speed and brightness decay are per frame at this rate, the default
  ## frame time; frames at any other rate scale them by elapsed time.

type
  MatrixMotion* = object
    fallSpeed*, cycleSpeed*, raindropLength*, brightnessDecay*: float

  MatrixField* = object
    ## One output's rain: smoothed brightness per cell, rows from the top.
    cols*, rows*: int
    brightness*: seq[float32]
    seconds*: float
    stepped*: bool

proc fract(x: float): float {.inline.} =
  x - floor(x)

proc randomFloat(x, y: float): float =
  ## The shaders' hash: fract(sin(mod(dot(p, k), PI)) * 43758.5453123).
  fract(sin(floorMod(x * 12.9898 + y * 78.233, PI)) * 43758.5453123)

proc wobble(x: float): float =
  x + 0.3 * sin(sqrt(2.0) * x) + 0.2 * sin(sqrt(5.0) * x)

proc rainBrightness*(motion: MatrixMotion, seconds: float, col, row, rows: int): float =
  ## Unsmoothed brightness of one cell at `seconds`, in [0, 1].
  let fallSpeed = max(motion.fallSpeed, 0.001)
  let raindropLength = max(motion.raindropLength, 0.05)
  let columnTimeOffset = randomFloat(float(col), 0.0) * 1000.0
  let columnSpeedOffset = randomFloat(float(col) + 0.1, 0.0) * 0.5 + 0.5
  let columnTime = columnTimeOffset + seconds * fallSpeed * columnSpeedOffset
  let glyphY = float(max(rows, 1)) - float(row) - 1.0
  1.0 - fract(wobble((glyphY * 0.01 + columnTime) / raindropLength))

proc rainCursor*(motion: MatrixMotion, seconds: float, col, row, rows: int): bool =
  ## The bright head of a drop: brighter than the cell below it.
  rainBrightness(motion, seconds, col, row, rows) >
    rainBrightness(motion, seconds, col, row + 1, rows)

proc rainSymbol*(motion: MatrixMotion, seconds: float, col, row, glyphCount: int): int =
  ## The glyph a cell shows. Each cell changes glyph at the cycle speed from
  ## its own starting phase.
  let count = max(glyphCount, 1)
  let age =
    randomFloat(float(col) + 0.5, float(row) + 0.5) +
    max(motion.cycleSpeed, 0.001) * seconds / MatrixReferenceFrameSeconds
  let epoch = floor(age)
  let symbol = int(
    floor(
      float(count) * randomFloat(float(col) + epoch * 0.618, float(row) + epoch * 0.414)
    )
  )
  clamp(symbol, 0, count - 1)

proc decayBlend*(decay, elapsedSeconds: float): float =
  ## How far a cell moves toward its new brightness after `elapsedSeconds`:
  ## `decay` per reference frame, compounded over the time that passed.
  let keep = 1.0 - clamp(decay, 0.0, 1.0)
  1.0 - pow(keep, max(elapsedSeconds, 0.0) / MatrixReferenceFrameSeconds)

proc initMatrixField*(cols, rows: int): MatrixField =
  MatrixField(
    cols: max(cols, 0),
    rows: max(rows, 0),
    brightness: newSeq[float32](max(cols, 0) * max(rows, 0)),
  )

proc step*(field: var MatrixField, motion: MatrixMotion, seconds: float) =
  ## Brings every cell to `seconds`. The first step takes the raw brightness.
  let blend =
    if field.stepped:
      decayBlend(motion.brightnessDecay, seconds - field.seconds)
    else:
      1.0
  for row in 0 ..< field.rows:
    for col in 0 ..< field.cols:
      let i = row * field.cols + col
      let target = rainBrightness(motion, seconds, col, row, field.rows)
      let previous = float(field.brightness[i])
      field.brightness[i] = float32(previous + (target - previous) * blend)
  field.seconds = seconds
  field.stepped = true
