# Package
version = "0.1.0"
author = "Mason Austin Green"
description = "A small ext-session-lock-v1 Wayland screen locker"
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
  "src/kleis/auth.nim src/kleis/cli.nim src/kleis/config.nim " &
  "src/kleis/matrix.nim src/kleis/matrix_gpu.nim src/kleis/matrix_render.nim " &
  "src/kleis/password.nim src/kleis/preview.nim src/kleis/wayland.nim " &
  "tests/test_cli.nim tests/test_config.nim tests/test_matrix.nim tests/test_password.nim"

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

task installPam,
  "Install the default PAM file (minimal: pam_faildelay + pam_unix; no faillock/homed/keyring/fingerprint/smartcard)":
  exec "sudo install -m0644 pam.d/kleis /etc/pam.d/kleis"

task installPamFull,
  "Install the full PAM file (auth include system-auth; enables homed, keyring, fingerprint, smartcard via system-auth)":
  exec "sudo install -m0644 pam.d/kleis.full /etc/pam.d/kleis"

task deploy,
  "Build release, install binary, drop default config (if absent), and install minimal PAM config":
  exec buildCommand
  exec "install -Dm755 kleis ~/.local/bin/kleis"
  installConfigStep()
  exec "sudo install -m0644 pam.d/kleis /etc/pam.d/kleis"

task test, "Run unit tests":
  exec "nim c -r --path:src tests/test_password.nim"
  exec "nim c -r --path:src tests/test_cli.nim"
  exec "nim c -r --path:src tests/test_config.nim"
  exec "nim c -r --path:src tests/test_matrix.nim"

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

task regenProtocols, "Regenerate checked-in Wayland protocol stubs from vendored XML":
  exec "scripts/regenerate-protocols.sh"

task regenFont,
  "Regenerate checked-in Matrix glyph alpha data from the vendored CNTR font":
  exec "python3 scripts/generate-cntr-font.py"
