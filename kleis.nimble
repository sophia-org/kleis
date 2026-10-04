# Package
version = "0.1.0"
author = "Mason Austin Green"
description = "A lock provider for Sophia: renders the lock screen, holds no secret"
license = "MIT"
srcDir = "src"
bin = @["kleis"]

# Dependencies
requires "nim >= 2.2.0"
requires "nimkdl >= 2.1.0"

const buildCommand =
  "nim c -d:release --forceBuild:on --opt:size --mm:orc -d:useMalloc " &
  "--passC:-flto=auto --passC:-Wno-free-nonheap-object " &
  "--passL:-flto=auto --passL:-Wno-free-nonheap-object " &
  "--passL:-Wl,--gc-sections --passL:-Wl,-s " & "--out:kleis src/kleis.nim"

const configTemplate = "examples/config.kdl"
const nphVersion = "0.7.0"
const nphTargets =
  "kleis.nimble src/kleis.nim " &
  "src/kleis/cli.nim src/kleis/config.nim src/kleis/frame.nim " &
  "src/kleis/matrix.nim src/kleis/matrix_gpu.nim src/kleis/matrix_render.nim " &
  "src/kleis/matrix_worker.nim " &
  "src/kleis/presenter.nim src/kleis/provider.nim src/kleis/sophia_sdk.nim " &
  "src/kleis/ui.nim tools/kleis_render.nim " &
  "tests/test_cli.nim tests/test_config.nim tests/test_frame.nim " &
  "tests/test_matrix.nim tests/test_matrix_gpu.nim tests/test_matrix_time.nim " &
  "tests/test_matrix_worker.nim tests/test_presenter.nim tests/test_ui.nim"

import std/os

proc installConfigStep() =
  let dest = getHomeDir() / ".config" / "kleis" / "config.kdl"
  if fileExists(dest):
    echo "kleis: existing config kept: " & dest
    echo "kleis: diff your config against examples/config.kdl for any new options:"
    echo "kleis:   diff \"" & dest & "\" examples/config.kdl"
  else:
    exec "install -Dm644 " & configTemplate & " \"" & dest & "\""
    echo "kleis: default config installed to: " & dest

task build, "Build kleis":
  exec buildCommand

task installBin, "Install the kleis binary to ~/.local/bin (builds if needed)":
  exec buildCommand
  exec "install -Dm755 kleis ~/.local/bin/kleis"
  installConfigStep()

task test, "Run unit tests":
  exec "nim c -r --path:src tests/test_cli.nim"
  exec "nim c -r --path:src tests/test_config.nim"
  exec "nim c -r --path:src tests/test_matrix.nim"
  exec "nim c -r --path:src tests/test_ui.nim"
  exec "nim c -r --path:src tests/test_frame.nim"
  exec "nim c -r --path:src tests/test_presenter.nim"
  exec "nim c -r --path:src tests/test_matrix_time.nim"
  exec "nim c -r --path:src tests/test_matrix_worker.nim"
  # Mesa's software rasterizer; Nim does not notice a changed C file alone.
  exec "nim c -r --forceBuild:on -d:kleisGpuSoftwareTest --path:src tests/test_matrix_gpu.nim"

task render, "Build the headless renderer, tools/kleis_render":
  exec "nim c -d:release --path:src --out:tools/kleis_render tools/kleis_render.nim"

task fmt, "Format Nim source files with nph":
  exec "nph " & nphTargets

task fmtCheck, "Check Nim source formatting with nph":
  exec "nph --check " & nphTargets

task setupTools, "Install developer tools used by Nimble tasks":
  exec "sh -c 'cd /tmp && nimble --global --solver:legacy install -y nph@" & nphVersion &
    "'"

task sizecheck, "Build release and report final binary size":
  exec buildCommand
  exec "size kleis"
  exec "ls -lh kleis"

task regenFont,
  "Regenerate checked-in Matrix glyph alpha data from the vendored CNTR font":
  exec "python3 scripts/generate-cntr-font.py"
