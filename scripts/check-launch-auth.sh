#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT HUP INT TERM
sdk=$root/vendor/sophia-desktop-sdk/source/src
cc -std=c11 -Wall -Wextra -Werror -I"$sdk" \
  "$root/tests/lock_auth.c" "$root/src/kleis/lock_auth.c" \
  "$sdk"/nine_p/*.c "$sdk"/launch_auth/*.c -o "$build/lock-auth"
"$build/lock-auth"
