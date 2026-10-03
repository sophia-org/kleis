## Headless renderer for visual checks: renders what kleis would upload for
## one allocation after a scripted run of lock events, and writes it as a
## PPM. No Sophia connection; it replaces lockme's preview window.

import std/[os, strutils]

import ../src/kleis/cli
import ../src/kleis/config
import ../src/kleis/frame
import ../src/kleis/matrix
import ../src/kleis/matrix_render
import ../src/kleis/ui

const HarnessUsage =
  """usage: kleis_render --size WxH --out FILE.ppm [harness options] [kleis options]

  --size WxH        Allocation size in pixels.
  --out FILE        Write the final frame as a binary PPM.
  --frames N        Advance the Matrix N steps before rendering (default 0).
  --seed N          Matrix seed (default 1; 0 takes the clock).
  --events LIST     Comma-separated events, 10 ms apart: insert, delete,
                    delete-empty, clear, submit, checking, failed,
                    unavailable, chord-N.
  --at-ms N         Time of the final tick (default: 1 ms after the last event).

Any other option is a kleis option (colours, --blank, --config, ...).
"""

proc fnv1a(bytes: ptr UncheckedArray[byte], count: int): uint64 =
  result = 0xcbf29ce484222325'u64
  for i in 0 ..< count:
    result = (result xor uint64(bytes[i])) * 0x100000001b3'u64

proc main() =
  var
    width, height = 0
    output = ""
    frames = 0
    seed = 1'i64
    events: seq[string]
    atMs = -1'i64
    rest: seq[string]
  let args = commandLineParams()
  var i = 0
  proc value(): string =
    if i + 1 >= args.len:
      raise newException(ValueError, "missing value for " & args[i])
    inc i
    args[i]

  while i < args.len:
    case args[i]
    of "--size":
      let parts = value().split('x')
      if parts.len != 2:
        raise newException(ValueError, "--size takes WxH")
      width = parseInt(parts[0])
      height = parseInt(parts[1])
    of "--out":
      output = value()
    of "--frames":
      frames = parseInt(value())
    of "--seed":
      seed = parseBiggestInt(value())
    of "--events":
      events = value().split(',')
    of "--at-ms":
      atMs = parseBiggestInt(value())
    of "-h", "--help":
      stdout.write(HarnessUsage)
      quit(0)
    else:
      rest.add args[i]
    inc i
  if width <= 0 or height <= 0 or output.len == 0:
    raise newException(ValueError, "--size and --out are required")

  var opts = parseOptions(rest)
  opts.loadConfig()
  var ui = initUi(opts, 0)
  var now = 0'i64
  for event in events:
    now += 10
    case event
    of "insert":
      ui.entry(leInsert, false, now)
    of "delete":
      ui.entry(leDelete, false, now)
    of "delete-empty":
      ui.entry(leDelete, true, now)
    of "clear":
      ui.entry(leClear, true, now)
    of "submit":
      ui.entry(leSubmit, true, now)
    of "checking":
      ui.entry(leChecking, true, now)
    of "failed":
      ui.entry(leFailed, true, now)
    of "unavailable":
      ui.entry(leUnavailable, true, now)
    else:
      if not event.startsWith("chord-"):
        raise newException(ValueError, "unknown event '" & event & "'")
      ui.chord(uint16(parseInt(event[6 ..^ 1])), now)
  ui.tick(
    if atMs >= 0:
      atMs
    else:
      now + 1
  )

  let renderer = initMatrixRenderer(matrixEffectiveScale(opts.matrixCellScale, width))
  var image = initOutputFrame(width, height, renderer, seed)
  for _ in 0 ..< frames:
    image.rain.advance()
  let view = ui.view
  image.render(view, renderer)

  var ppm = newStringOfCap(width * height * 3 + 32)
  ppm.add "P6\n" & $width & " " & $height & "\n255\n"
  for pixel in image.pixels:
    ppm.add char((pixel shr 16) and 0xff)
    ppm.add char((pixel shr 8) and 0xff)
    ppm.add char(pixel and 0xff)
  writeFile(output, ppm)
  echo "kleis_render size=",
    width,
    "x",
    height,
    " view=",
    (if view.kind == vkMatrix: "matrix" else: "solid"),
    " frames=",
    frames,
    " fnv1a64=",
    toHex(fnv1a(image.bytes, image.byteCount), 16).toLowerAscii()

when isMainModule:
  try:
    main()
  except ValueError as e:
    stderr.writeLine("kleis_render: " & e.msg)
    quit(1)
