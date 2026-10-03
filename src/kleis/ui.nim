## What kleis shows, driven by Sophia's lock events.
##
## On Sophia kleis never sees the secret: Session reports what it did (an
## Entry) and which registered chord was pressed. The rules follow lockme's
## key handling: a typed character advances the input palette, emptying the
## secret returns to the at-rest colour, a failed attempt shows the failure
## colour for a moment, and Alt-B toggles blank. Time is passed in, so the
## machine is pure and testable.

import ./cli

const
  FailHoldMs* = 750'i64
    ## How long the failure colour holds before an empty secret returns to rest.
  BlankChord* = 0'u16
    ## The first chord kleis registers (Alt-B): toggles Matrix and blank.

type
  LockEntry* = enum
    ## Sophia's Entry values, in wire order (spec: sophia-lock-files.md).
    leInsert = 1
    leDelete = 2
    leClear = 3
    leSubmit = 4
    leChecking = 5
    leFailed = 6
    leUnavailable = 7

  ColorKind* = enum
    ckInit
    ckInput
    ckFail

  ColorState* = object
    kind*: ColorKind
    inputIdx*: int

  ViewKind* = enum
    vkMatrix
    vkSolid

  View* = object
    kind*: ViewKind
    color*: uint32 ## 0xRRGGBB for vkSolid

  Ui* = object
    initColor*, failColor*: uint32
    inputColors*: seq[uint32]
    blankAtStart*: bool
    idleTimeoutMs*: int64
    color*: ColorState
    secretEmpty*: bool
    blank*, idleBlanked*: bool
    failReturnPending*: bool
    failReturnAt*: int64
    lastInputAt*: int64

proc initUi*(opts: Options, nowMs: int64): Ui =
  result = Ui(
    initColor: opts.initColor,
    failColor: opts.failColor,
    inputColors: opts.inputColors,
    blankAtStart: opts.blank,
    idleTimeoutMs: int64(opts.idleTimeoutSecs) * 1000,
  )
  result.color = ColorState(kind: ckInit)
  result.secretEmpty = true
  result.blank = opts.blank
  result.lastInputAt = nowMs

proc lockStarted*(ui: var Ui, nowMs: int64) =
  ## A new lock epoch: Session's secret starts empty.
  ui.color = ColorState(kind: ckInit)
  ui.secretEmpty = true
  ui.blank = ui.blankAtStart
  ui.idleBlanked = false
  ui.failReturnPending = false
  ui.lastInputAt = nowMs

proc setColor(ui: var Ui, color: ColorState) =
  if color.kind != ckFail:
    ui.failReturnPending = false
  ui.color = color

proc nextInput(ui: Ui): ColorState =
  ## Rotate through the input palette, wrapping after the last entry.
  let n = ui.inputColors.len
  if n <= 0:
    return ColorState(kind: ckInit)
  let next =
    if ui.color.kind == ckInput:
      (ui.color.inputIdx + 1) mod n
    else:
      0
  ColorState(kind: ckInput, inputIdx: next)

proc wake(ui: var Ui, nowMs: int64): bool =
  ## Any event resets the idle clock; one that ends idle blanking reports it.
  ui.lastInputAt = nowMs
  if ui.idleBlanked:
    ui.idleBlanked = false
    ui.blank = false
    return true
  false

proc entry*(ui: var Ui, kind: LockEntry, emptyAfter: bool, nowMs: int64) =
  ## Unlike lockme, a key that ends idle blanking is not swallowed: it has
  ## already reached Session's secret, so the screen must show it.
  discard ui.wake(nowMs)
  case kind
  of leInsert:
    ui.secretEmpty = emptyAfter
    ui.setColor(ui.nextInput())
  of leDelete:
    ui.secretEmpty = emptyAfter
    if emptyAfter:
      ui.setColor(ColorState(kind: ckInit))
  of leClear:
    ui.secretEmpty = true
    ui.setColor(ColorState(kind: ckInit))
  of leSubmit:
    ui.secretEmpty = true
  of leChecking:
    discard
  of leFailed, leUnavailable:
    ui.setColor(ColorState(kind: ckFail))
    ui.failReturnPending = true
    ui.failReturnAt = nowMs + FailHoldMs

proc chord*(ui: var Ui, id: uint16, nowMs: int64) =
  ## A chord never reaches the secret, so the one that wakes the screen is
  ## consumed by waking it, as in lockme.
  if ui.wake(nowMs):
    return
  if id == BlankChord:
    ui.blank = not ui.blank

proc tick*(ui: var Ui, nowMs: int64) =
  if ui.failReturnPending and nowMs >= ui.failReturnAt:
    ui.failReturnPending = false
    if ui.color.kind == ckFail and ui.secretEmpty:
      ui.setColor(ColorState(kind: ckInit))
  if ui.idleTimeoutMs > 0 and not ui.blank and nowMs - ui.lastInputAt >= ui.idleTimeoutMs:
    ui.blank = true
    ui.idleBlanked = true

proc nextDeadline*(ui: Ui): int64 =
  ## The earliest time tick changes anything, or -1.
  result = -1
  if ui.failReturnPending:
    result = ui.failReturnAt
  if ui.idleTimeoutMs > 0 and not ui.blank:
    let idle = ui.lastInputAt + ui.idleTimeoutMs
    if result < 0 or idle < result:
      result = idle

proc colorValue(ui: Ui, color: ColorState): uint32 =
  case color.kind
  of ckInit:
    ui.initColor
  of ckFail:
    ui.failColor
  of ckInput:
    ui.inputColors[color.inputIdx]

proc view*(ui: Ui): View =
  ## Blank only turns the Matrix off: as in lockme, the screen then shows the
  ## current state's colour, which is the at-rest colour while nothing is typed.
  if not ui.blank and ui.color.kind == ckInit and ui.secretEmpty:
    View(kind: vkMatrix)
  else:
    View(kind: vkSolid, color: ui.colorValue(ui.color))
