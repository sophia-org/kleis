import std/os

import kleis/cli
import kleis/provider

when isMainModule:
  try:
    var opts = parseOptions(commandLineParams())
    if opts.showHelp:
      stdout.write(Usage)
      quit(0)
    if opts.showVersion:
      echo Version
      quit(0)
    if getEnv("SOPHIA_LOCK_9P_SOCKET").len == 0:
      raise newException(
        ValueError,
        "kleis is a Sophia lock provider: Sophia starts it from the profile's " &
          "session { lock-provider } (tools/kleis_render previews it)",
      )
    # Under Sophia there is no HOME: the config arrives in SOPHIA_LOCK_CONFIG.
    runProvider(opts)
  except ValueError as e:
    stderr.writeLine("kleis: " & e.msg)
    quit(1)
  except OSError as e:
    stderr.writeLine("kleis: " & e.msg)
    quit(1)
