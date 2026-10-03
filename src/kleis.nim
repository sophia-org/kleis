import std/os

import kleis/cli
import kleis/config

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
    # The provider connection over Sophia's lock files is phase 3 of
    # docs/sophia-port-plan.md; it waits for the published C SDK lock client.
    raise
      newException(ValueError, "the Sophia lock provider connection is not built yet")
  except ValueError as e:
    stderr.writeLine("kleis: " & e.msg)
    quit(1)
  except OSError as e:
    stderr.writeLine("kleis: " & e.msg)
    quit(1)
