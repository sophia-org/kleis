import std/[options, parseutils, strutils]

const Version* = "0.1.0"
const MatrixFrameMsDefault* = 40
const MatrixCellScaleAuto* = 0.0
const MatrixCellScaleDefault* = MatrixCellScaleAuto
const MatrixFallSpeedDefault* = 0.3
const MatrixCycleSpeedDefault* = 0.03
const MatrixRaindropLengthDefault* = 0.75
const MatrixBrightnessDecayDefault* = 1.0

type
  LogLevel* = enum
    llError
    llWarning
    llInfo
    llDebug

  CliFlag* = enum
    ## Which option fields were explicitly set on the CLI. Used to merge
    ## defaults <- config-file <- CLI without re-parsing.
    cfInitColor
    cfInputColors
    cfFailColor
    cfLogLevel
    cfConfigPath
    cfNoConfig
    cfBlank
    cfNoGpu
    cfIdleTimeout

  Options* = object
    initColor*: uint32
    inputColors*: seq[uint32]
    failColor*: uint32
    logLevel*: LogLevel
    showHelp*: bool
    showVersion*: bool
    configPath*: Option[string]
    noConfig*: bool
    blank*: bool
    noGpu*: bool
    idleTimeoutSecs*: int
    matrixFrameMs*: int
    matrixCellScale*: float
    matrixFallSpeed*: float
    matrixCycleSpeed*: float
    matrixRaindropLength*: float
    matrixBrightnessDecay*: float
    setFlags*: set[CliFlag]

const Usage* = """usage: kleis [options]

  -h, --help                       Print this help message and exit.
  --version                        Print the version number and exit.
  --log-level <level>              Set log level: error, warning, info, debug.

  --blank                          Start with a blank screen instead of Matrix.
  --no-gpu                         Render on the CPU without initializing EGL.
  --idle-timeout <seconds>         Blank the screen after this many seconds of
                                   inactivity. 0 disables (default: 0).

  --config <path>                  Load configuration from <path>.
  --no-config                      Do not load any configuration file.

  --init-color 0xRRGGBB            Set the at-rest color.
  --input-color 0xRRGGBB           Add an input-state color. Repeatable; the
                                   first occurrence replaces the default
                                   palette, subsequent occurrences append.
                                   kleis cycles through these on each
                                   character typed.
  --fail-color 0xRRGGBB            Set the auth failure color.
"""

proc defaultOptions*(): Options =
  ## Built-in defaults. See README for the documented palette.
  Options(
    initColor: 0x000000'u32, # pure black
    inputColors: @[0x4B0082'u32, 0x003366'u32, 0x006400'u32],
      # Father (Tyrian indigo/violet), Son (royal blue), Spirit (life green)
    failColor: 0x8B0000'u32, # deep crimson
    logLevel: llError,
    matrixFrameMs: MatrixFrameMsDefault,
    matrixCellScale: MatrixCellScaleDefault,
    matrixFallSpeed: MatrixFallSpeedDefault,
    matrixCycleSpeed: MatrixCycleSpeedDefault,
    matrixRaindropLength: MatrixRaindropLengthDefault,
    matrixBrightnessDecay: MatrixBrightnessDecayDefault,
  )

proc parseColor*(raw: string): uint32 =
  ## Parses a `0xRRGGBB` color literal as used on the CLI.
  if raw.len != 8 or raw[0 .. 1] != "0x":
    raise newException(ValueError, "invalid color '" & raw & "', expected 0xRRGGBB")
  var value: int
  if parseHex(raw[2 ..^ 1], value) != 6:
    raise newException(ValueError, "invalid color '" & raw & "', expected 0xRRGGBB")
  result = uint32(value)

proc parseLogLevel*(raw: string): LogLevel =
  case raw
  of "error":
    llError
  of "warning":
    llWarning
  of "info":
    llInfo
  of "debug":
    llDebug
  else:
    raise newException(ValueError, "invalid log level '" & raw & "'")

proc needValue(args: seq[string], i: int, opt: string): string =
  if i + 1 >= args.len:
    raise newException(ValueError, "missing value for " & opt)
  args[i + 1]

proc parseOptions*(args: seq[string]): Options =
  result = defaultOptions()
  var inputColorSeen = false
  var i = 0
  while i < args.len:
    let arg = args[i]
    case arg
    of "-h", "--help":
      result.showHelp = true
    of "--version":
      result.showVersion = true
    of "--blank":
      result.blank = true
      result.setFlags.incl cfBlank
    of "--no-gpu":
      result.noGpu = true
      result.setFlags.incl cfNoGpu
    of "--idle-timeout":
      let raw = needValue(args, i, arg)
      let secs = parseInt(raw)
      if secs < 0:
        raise newException(ValueError, "invalid --idle-timeout value '" & raw & "'")
      result.idleTimeoutSecs = secs
      result.setFlags.incl cfIdleTimeout
      inc i
    of "--no-config":
      result.noConfig = true
      result.setFlags.incl cfNoConfig
    of "--config":
      result.configPath = some(needValue(args, i, arg))
      result.setFlags.incl cfConfigPath
      inc i
    of "--log-level":
      result.logLevel = parseLogLevel(needValue(args, i, arg))
      result.setFlags.incl cfLogLevel
      inc i
    of "--init-color":
      result.initColor = parseColor(needValue(args, i, arg))
      result.setFlags.incl cfInitColor
      inc i
    of "--input-color":
      let color = parseColor(needValue(args, i, arg))
      if not inputColorSeen:
        result.inputColors = @[color]
        inputColorSeen = true
      else:
        result.inputColors.add color
      result.setFlags.incl cfInputColors
      inc i
    of "--fail-color":
      result.failColor = parseColor(needValue(args, i, arg))
      result.setFlags.incl cfFailColor
      inc i
    else:
      raise newException(ValueError, "unknown option '" & arg & "'")
    inc i
