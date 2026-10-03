import std/unittest

import ../src/kleis/cli
import ../src/kleis/ui

proc fresh(idleSecs = 0, blank = false): Ui =
  var opts = defaultOptions()
  opts.idleTimeoutSecs = idleSecs
  opts.blank = blank
  initUi(opts, 0)

suite "ui":
  test "rest shows the Matrix":
    let ui = fresh()
    check ui.view.kind == vkMatrix

  test "each typed character advances the input palette and wraps":
    var ui = fresh()
    let palette = defaultOptions().inputColors
    for i in 0 ..< palette.len + 1:
      ui.entry(leInsert, false, 10)
      check ui.view == View(kind: vkSolid, color: palette[i mod palette.len])

  test "deleting returns to rest only when the secret empties":
    var ui = fresh()
    ui.entry(leInsert, false, 1)
    ui.entry(leInsert, false, 2)
    let before = ui.view
    ui.entry(leDelete, false, 3)
    check ui.view == before
    ui.entry(leDelete, true, 4)
    check ui.view.kind == vkMatrix

  test "clear returns to rest":
    var ui = fresh()
    ui.entry(leInsert, false, 1)
    ui.entry(leClear, true, 2)
    check ui.view.kind == vkMatrix

  test "submit keeps the colour until the verdict":
    var ui = fresh()
    ui.entry(leInsert, false, 1)
    let typed = ui.view
    ui.entry(leSubmit, true, 2)
    ui.entry(leChecking, true, 3)
    check ui.view == typed

  test "a failure holds its colour, then an empty secret returns to rest":
    var ui = fresh()
    let failColor = defaultOptions().failColor
    ui.entry(leInsert, false, 1)
    ui.entry(leSubmit, true, 2)
    ui.entry(leFailed, true, 100)
    check ui.view == View(kind: vkSolid, color: failColor)
    check ui.nextDeadline == 100 + FailHoldMs
    ui.tick(100 + FailHoldMs - 1)
    check ui.view.kind == vkSolid
    ui.tick(100 + FailHoldMs)
    check ui.view.kind == vkMatrix

  test "typing during the failure hold keeps the typed colour":
    var ui = fresh()
    ui.entry(leFailed, true, 100)
    ui.entry(leInsert, false, 200)
    ui.tick(100 + FailHoldMs)
    check ui.view.kind == vkSolid
    check ui.view.color == defaultOptions().inputColors[0]

  test "an undecided attempt shows the failure colour too":
    var ui = fresh()
    ui.entry(leUnavailable, true, 5)
    check ui.view == View(kind: vkSolid, color: defaultOptions().failColor)

  test "the blank chord turns the Matrix off and on":
    var ui = fresh()
    ui.chord(BlankChord, 1)
    check ui.view == View(kind: vkSolid, color: defaultOptions().initColor)
    ui.chord(BlankChord, 2)
    check ui.view.kind == vkMatrix
    ui.chord(1, 3) # not the blank chord
    check ui.view.kind == vkMatrix

  test "blank still shows typed colours":
    var ui = fresh(blank = true)
    check ui.view.kind == vkSolid
    ui.entry(leInsert, false, 1)
    check ui.view.color == defaultOptions().inputColors[0]

  test "idle blanks, and a typed character wakes and still counts":
    var ui = fresh(idleSecs = 2)
    check ui.nextDeadline == 2000
    ui.tick(1999)
    check not ui.blank
    ui.tick(2000)
    check ui.blank and ui.idleBlanked
    ui.entry(leInsert, false, 2500)
    check not ui.blank
    check ui.view.color == defaultOptions().inputColors[0]

  test "a chord that wakes from idle is consumed":
    var ui = fresh(idleSecs = 1)
    ui.tick(1000)
    ui.chord(BlankChord, 1500)
    check not ui.blank
    check ui.view.kind == vkMatrix

  test "a new lock starts at rest":
    var ui = fresh()
    ui.entry(leInsert, false, 1)
    ui.entry(leFailed, true, 2)
    ui.chord(BlankChord, 3)
    ui.lockStarted(10)
    check ui.view.kind == vkMatrix
    check not ui.failReturnPending
    check ui.nextDeadline == -1
