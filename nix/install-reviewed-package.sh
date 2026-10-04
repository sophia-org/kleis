#!/usr/bin/env bash
# Installs one Nimble package exactly as the reviewed dependency manifest
# records it: every listed file, taken from the pinned upstream source (or
# src/ beneath it) and matched by sha256 and size. nimblemeta.json is the one
# file Nimble writes at install time; it comes from the vendored copy, checked
# the same way. Any missing, extra or different file fails the build.
#
# usage: install-reviewed-package.sh MANIFEST NAME SOURCE NIMBLEMETA OUT
set -euo pipefail
manifest=$1 name=$2 src=$3 meta=$4 out=$5

mkdir -p "$out"
rows=$(grep "^file package=$name " "$manifest")
expected=$(printf '%s\n' "$rows" | wc -l)
while read -r _ _ path mode size sha; do
	path=${path#path=} mode=${mode#mode=} size=${size#size=} sha=${sha#sha256=}
	if [ "$path" = nimblemeta.json ]; then
		from=$meta
	elif [ -f "$src/$path" ]; then
		from=$src/$path
	elif [ -f "$src/src/$path" ]; then
		from=$src/src/$path
	else
		echo "$name: $path is not in the pinned source" >&2
		exit 1
	fi
	got=$(sha256sum "$from" | cut -d' ' -f1)
	if [ "$got" != "$sha" ] || [ "$(stat -c %s "$from")" != "$size" ]; then
		echo "$name: $path differs from the reviewed manifest ($got)" >&2
		exit 1
	fi
	install -D -m "$mode" "$from" "$out/$path"
done <<<"$rows"
installed=$(find "$out" -type f | wc -l)
if [ "$installed" != "$expected" ]; then
	echo "$name: installed $installed files, the manifest lists $expected" >&2
	exit 1
fi
echo "$name: $installed files match the reviewed manifest"
