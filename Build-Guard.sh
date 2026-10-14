#!/bin/sh
# Copyright (C) 2026 wuldas
# SPDX-License-Identifier: GPL-3.0-only
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ "$(uname -m)" = x86_64 ] || { echo 'Build on x86_64 GNU/Linux.' >&2; exit 1; }
CC=${CC:-cc}
OUT="$ROOT/out/build"
mkdir -p "$OUT"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -fno-pie -c "$ROOT/wsa-vfork-guard.c" -o "$OUT/wsa-vfork-guard.o"
"$CC" -static -fno-pie -no-pie -o "$OUT/wsa-vfork-guard" "$OUT/wsa-vfork-guard.o"
"$OUT/wsa-vfork-guard" --version
sha256sum "$OUT/wsa-vfork-guard" "$OUT/wsa-vfork-guard.o"
