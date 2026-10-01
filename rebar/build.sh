#!/usr/bin/env bash
# Build the zeetah rebar runner against the engine tree at $ZEETAH_SRC
# (path to zeetah's src/root.zig). -OReleaseFast MUST precede the -M args:
# in Zig's multi-module CLI the optimize mode applies only to modules defined
# after it (placed last, everything silently builds in Debug).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
ZEETAH_SRC="${ZEETAH_SRC:-$HOME/Develop/Zig/regex/zeetah/src/root.zig}"
[ -f "$ZEETAH_SRC" ] || { echo "ZEETAH_SRC not found: $ZEETAH_SRC" >&2; exit 1; }
REV="$(git -C "$(dirname "$ZEETAH_SRC")" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git -C "$(dirname "$ZEETAH_SRC")" status --porcelain -- . 2>/dev/null)" ]; then REV="$REV-dirty"; fi
mkdir -p zig-out
printf 'pub const rev = "%s";\n' "$REV" > zig-out/build_info.zig
zig build-exe -OReleaseFast \
    --dep zeetah --dep build_info -Mroot=main.zig \
    -Mzeetah="$ZEETAH_SRC" -Mbuild_info=zig-out/build_info.zig \
    -lc --name main --cache-dir .zig-cache -femit-bin=zig-out/main
