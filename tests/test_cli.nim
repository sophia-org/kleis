import std/[options, unittest]

import kleis/cli

suite "cli":
  test "default colors":
    let opts = parseOptions(@[])
    check opts.initColor == 0x000000'u32
    check opts.failColor == 0x8B0000'u32
    check opts.inputColors == @[0x4B0082'u32, 0x003366'u32, 0x006400'u32]

  test "Wayland-locker options are gone":
    # Sophia starts the provider, owns the secret and decides the unlock.
    for removed in [
      "--dev-mode", "--dev-window", "--check-protocols", "--fork-on-lock",
      "--allow-empty-password", "--ignore-empty-password",
    ]:
      expect ValueError:
        discard parseOptions(@[removed])
    expect ValueError:
      discard parseOptions(@["--ready-fd", "9"])

  test "parse init/fail colors":
    let opts = parseOptions(@["--init-color", "0x112233", "--fail-color", "0x445566"])
    check opts.initColor == 0x112233'u32
    check opts.failColor == 0x445566'u32
    check cfInitColor in opts.setFlags
    check cfFailColor in opts.setFlags

  test "single --input-color replaces palette":
    let opts = parseOptions(@["--input-color", "0x445566"])
    check opts.inputColors == @[0x445566'u32]
    check cfInputColors in opts.setFlags

  test "repeated --input-color appends after replacing default":
    let opts = parseOptions(
      @[
        "--input-color", "0x111111", "--input-color", "0x222222", "--input-color",
        "0x333333",
      ]
    )
    check opts.inputColors == @[0x111111'u32, 0x222222'u32, 0x333333'u32]

  test "reject bad color":
    expect ValueError:
      discard parseOptions(@["--fail-color", "112233"])

  test "reject hash color (CLI requires 0x prefix)":
    expect ValueError:
      discard parseOptions(@["--init-color", "#112233"])

  test "--config sets configPath":
    let opts = parseOptions(@["--config", "/tmp/kleis.kdl"])
    check opts.configPath == some("/tmp/kleis.kdl")
    check cfConfigPath in opts.setFlags

  test "--no-config sets noConfig":
    let opts = parseOptions(@["--no-config"])
    check opts.noConfig
    check cfNoConfig in opts.setFlags

  test "matrix is default display mode":
    let opts = parseOptions(@[])
    check not opts.blank

  test "--blank starts blank":
    let opts = parseOptions(@["--blank"])
    check opts.blank
    check cfBlank in opts.setFlags

  test "--matrix is rejected":
    expect ValueError:
      discard parseOptions(@["--matrix"])

  test "matrix frame timing default":
    let opts = parseOptions(@[])
    check opts.matrixFps == MatrixFpsDefault
    check opts.matrixCellScale == MatrixCellScaleDefault
    check opts.matrixFallSpeed == MatrixFallSpeedDefault
    check opts.matrixCycleSpeed == MatrixCycleSpeedDefault
    check opts.matrixRaindropLength == MatrixRaindropLengthDefault
    check opts.matrixBrightnessDecay == MatrixBrightnessDecayDefault

  test "setFlags empty when no overrides":
    let opts = parseOptions(@[])
    check opts.setFlags == {}

  test "--no-gpu enables CPU-only renderer":
    let opts = parseOptions(@["--no-gpu"])
    check opts.noGpu
    check cfNoGpu in opts.setFlags

  test "noGpu defaults to false":
    let opts = parseOptions(@[])
    check not opts.noGpu

  test "--idle-timeout sets seconds":
    let opts = parseOptions(@["--idle-timeout", "30"])
    check opts.idleTimeoutSecs == 30
    check cfIdleTimeout in opts.setFlags

  test "--idle-timeout zero disables":
    let opts = parseOptions(@["--idle-timeout", "0"])
    check opts.idleTimeoutSecs == 0
    check cfIdleTimeout in opts.setFlags

  test "--idle-timeout rejects negative":
    expect ValueError:
      discard parseOptions(@["--idle-timeout", "-1"])

  test "idleTimeoutSecs defaults to zero":
    let opts = parseOptions(@[])
    check opts.idleTimeoutSecs == 0
