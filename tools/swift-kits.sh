#!/usr/bin/env bash
# Builds the shared Swift packages the launcher imports, each at a pinned tag and commit, as a static
# library and module per architecture. tools/macos-app.sh and the launcher's CI check call it.
#
#   tools/swift-kits.sh <out> <arch>...    → <out>/<arch>/lib<Kit>.a and <Kit>.swiftmodule
#
# The launcher then builds with `-I <out>/<arch> -L <out>/<arch>` and `-l<Kit>` for each kit
# (`tools/swift-kits.sh --libs` prints those -l flags).
set -euo pipefail

# name, tag, commit: a moved tag is refused, as Sparkle's tarball is checked against its SHA-256.
KITS=(
    "DownloadKit 0.1.0 01e6ef537c2580674c8cbdfdd567c74e5a9b582b"
)
MIN_MACOS="14.0"

if [ "${1:-}" = "--libs" ]; then
    for kit in "${KITS[@]}"; do set -- $kit; printf -- '-l%s ' "$1"; done
    echo
    exit 0
fi

out="$1"; shift
[ $# -gt 0 ] || { echo "usage: tools/swift-kits.sh <out> <arch>..." >&2; exit 1; }

for kit in "${KITS[@]}"; do
    read -r name tag commit <<< "$kit"
    src="$out/src/$name-$tag"
    if [ ! -d "$src/Sources/$name" ]; then
        rm -rf "$src"
        git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" "https://github.com/matguitarist/$name" "$src"
    fi
    got="$(git -C "$src" rev-parse HEAD)"
    [ "$got" = "$commit" ] || { echo "$name $tag is commit $got, expected $commit" >&2; exit 1; }
    for arch in "$@"; do
        lib="$out/$arch"
        mkdir -p "$lib"
        # Built from this checkout already.
        [ "$lib/lib$name.a" -nt "$src/.git/HEAD" ] && [ -f "$lib/$name.swiftmodule" ] && continue
        echo "building ${name} ${tag} for ${arch}…"
        xcrun swiftc -swift-version 6 -O -wmo -parse-as-library \
            -target "$arch-apple-macos$MIN_MACOS" \
            -module-name "$name" -emit-module -emit-module-path "$lib/$name.swiftmodule" \
            -emit-library -static -o "$lib/lib$name.a" \
            "$src/Sources/$name"/*.swift
    done
done
