import std/os

import kleis/cli
import kleis/config
import kleis/preview
import kleis/wayland

when isMainModule:
  try:
    var opts = parseOptions(commandLineParams())
    if opts.showHelp:
      stdout.write(Usage)
      quit(0)
    if opts.showVersion:
      echo Version
      quit(0)
    opts.loadConfig()
    if opts.devWindow:
      if not opts.devMode:
        raise newException(ValueError, "--dev-window requires --dev-mode")
      runDevWindow(opts)
    elif opts.checkProtocols:
      checkProtocols(opts)
    else:
      runLock(opts)
  except ValueError as e:
    stderr.writeLine("kleis: " & e.msg)
    quit(1)
  except OSError as e:
    stderr.writeLine("kleis: " & e.msg)
    quit(1)
