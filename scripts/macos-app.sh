#!/usr/bin/env bash
# Build "Hearthside.app": the game (a player build, `ship` profile) and the Swift launcher
# that downloads the game data, edits settings and updates itself with Sparkle. See macos/README.md.
#
#   scripts/macos-app.sh             build and sign → target/macos/Hearthside.app
#   scripts/macos-app.sh --release   also notarize, staple, and write the zip, dmg and appcast.xml
#
# Environment (all optional):
#   SIGN_IDENTITY   codesign identity; default the keychain's first "Developer ID Application",
#                   else ad-hoc ("-"), which runs only on this Mac and turns updates off
#   ARCHS           "arm64", "x86_64" or "arm64 x86_64" (universal); default this Mac's
#   VERSION         CFBundleShortVersionString; default the crate's version
#   BUILD           CFBundleVersion, which Sparkle compares; default from VERSION (1.2.3 → 1002003)
#   REPO            owner/name hosting the releases; default GITHUB_REPOSITORY, else origin's
#   NOTARY_PROFILE  `xcrun notarytool store-credentials` profile (default AzerothSurvivors), or, for CI,
#   NOTARY_APPLE_ID, NOTARY_PASSWORD, NOTARY_TEAM_ID   an Apple ID and app-specific password, or
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER           an App Store Connect API key (.p8 path)
#   SPARKLE_KEY_FILE  Sparkle private key file (CI); default the keychain's `azeroth-survivors` key
#   PREBUILT_GAME   1: use target/<triple>/ship/warcraft-survivors as it is (CI builds each arch
#                   on its own runner, in parallel)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
command -v cargo >/dev/null || . "$HOME/.cargo/env"

RELEASE=0
[ "${1:-}" = "--release" ] && RELEASE=1

NAME="Hearthside"
EXE="Hearthside"
BUNDLE_ID="io.github.matguitarist.hearthside"
MIN_MACOS="14.0"
SPARKLE_VERSION="2.10.0"
SPARKLE_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"

OUT="$ROOT/target/macos"
APP="$OUT/$NAME.app"
ARCHS="${ARCHS:-$(uname -m)}"
VERSION="${VERSION:-$(sed -n 's/^version *= *"\(.*\)"/\1/p' Cargo.toml | head -1)}"
# Sparkle orders releases by CFBundleVersion, so it comes from the version (0.2.1 → 2001), never
# from history: a squash merge or a rebase can't make it go backwards.
if [ -z "${BUILD:-}" ]; then
    IFS=. read -r v_major v_minor v_patch <<< "$VERSION"
    BUILD=$(( ${v_major:-0} * 1000000 + ${v_minor:-0} * 1000 + ${v_patch%%[!0-9]*} ))
fi
if [ -z "${REPO:-}" ]; then
    REPO="${GITHUB_REPOSITORY:-$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')}"
fi
FEED="https://github.com/$REPO/releases/latest/download/appcast.xml"
PUBLIC_KEY="$(tr -d '[:space:]' < macos/sparkle-public-key.txt)"

if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
    SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
if [ "$SIGN_IDENTITY" = "-" ]; then
    [ "$RELEASE" = 1 ] && { echo "a release needs a Developer ID Application certificate"; exit 1; }
    echo "warning: no Developer ID certificate; signing ad-hoc, updates off"
    FEED="" PUBLIC_KEY=""
fi

triple() { case "$1" in arm64) echo aarch64-apple-darwin ;; x86_64) echo x86_64-apple-darwin ;; *) echo "unknown arch $1" >&2; exit 1 ;; esac; }

# --- Sparkle --------------------------------------------------------------------------------
SPARKLE="$OUT/sparkle-$SPARKLE_VERSION"
if [ ! -d "$SPARKLE/Sparkle.framework" ]; then
    mkdir -p "$SPARKLE"
    tarball="$OUT/Sparkle-$SPARKLE_VERSION.tar.xz"
    curl -fsSL -o "$tarball" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
    echo "$SPARKLE_SHA256  $tarball" | shasum -a 256 -c - >/dev/null || { echo "Sparkle download failed its checksum"; exit 1; }
    tar -xf "$tarball" -C "$SPARKLE"
fi

# --- The game: the player build (no dev instruments, no source-tree paths) -------------------
games=()
for arch in $ARCHS; do
    t="$(triple "$arch")"
    if [ "${PREBUILT_GAME:-0}" = 1 ]; then
        [ -x "target/$t/ship/warcraft-survivors" ] || { echo "PREBUILT_GAME: no target/$t/ship/warcraft-survivors"; exit 1; }
    else
        rustup target add "$t" >/dev/null 2>&1 || true
        echo "building the game for $arch (fat LTO: expect ~15 minutes from cold)…"
        cargo build --profile ship -p warcraft-survivors --no-default-features --target "$t"
    fi
    games+=("target/$t/ship/warcraft-survivors")
done

# --- The launcher ---------------------------------------------------------------------------
launchers=()
mkdir -p "$OUT/build"
for arch in $ARCHS; do
    echo "building the launcher for ${arch}…"
    xcrun swiftc -swift-version 5 -O -parse-as-library \
        -target "$arch-apple-macos$MIN_MACOS" \
        -module-name "$EXE" \
        -F "$SPARKLE" -framework Sparkle \
        -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
        macos/Launcher/*.swift -o "$OUT/build/$EXE-$arch"
    launchers+=("$OUT/build/$EXE-$arch")
done

# --- Assemble ---------------------------------------------------------------------------------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
lipo -create "${launchers[@]}" -output "$APP/Contents/MacOS/$EXE"
lipo -create "${games[@]}" -output "$APP/Contents/MacOS/warcraft-survivors"
# Not sandboxed, so Sparkle's XPC services are not needed (Sparkle's docs allow removing them).
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
       "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
cp scripts/data-manifest.tsv "$APP/Contents/Resources/"
# Classic on this Mac: the compose file and server configs `LocalServer.swift` installs.
ditto macos/Server "$APP/Contents/Resources/Server"
# Python's byte-code caches, should a script have been run from the repo.
find "$APP/Contents/Resources/Server" -name __pycache__ -prune -exec rm -rf {} +
# Classic's shipped addons, installed into the game's AddOns folder by `Addons.swift`.
ditto addons "$APP/Contents/Resources/AddOns"

# Survivors' key art, a 1920×1080 HEIC of a run with its HUD hidden (Alt-Z); the icon from the
# README's screenshot.
cp macos/survivors.heic "$APP/Contents/Resources/"
shot=docs/screenshots/combat.jpg
tmp="$(mktemp -d)"
# Classic's and Pandaria's, Blizzard's key art, kept out of the repository: from `macos/art/`
# when this Mac has them (classic.heic, pandaria.heic), else those modes show Survivors'.
for art in macos/art/*.heic; do [ ! -f "$art" ] || cp "$art" "$APP/Contents/Resources/"; done
w=$(sips -g pixelWidth "$shot" | awk '/pixelWidth/ {print $2}')
h=$(sips -g pixelHeight "$shot" | awk '/pixelHeight/ {print $2}')
side=$(( w < h ? w : h ))
sips -s format png -c "$side" "$side" "$shot" --out "$tmp/square.png" >/dev/null
mkdir "$tmp/AppIcon.iconset"
for s in 16 32 128 256 512; do
    sips -z $s $s "$tmp/square.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$tmp/square.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$tmp/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$tmp"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>$NAME</string>
    <key>CFBundleDisplayName</key>          <string>$NAME</string>
    <key>CFBundleIdentifier</key>           <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>           <string>$EXE</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>$VERSION</string>
    <key>CFBundleVersion</key>              <string>$BUILD</string>
    <key>LSMinimumSystemVersion</key>       <string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key>    <string>public.app-category.role-playing-games</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>NSHumanReadableCopyright</key>     <string>Not affiliated with Blizzard Entertainment. Game data is downloaded from archive.org.</string>
    <key>SUFeedURL</key>                    <string>$FEED</string>
    <key>SUPublicEDKey</key>                <string>$PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key>      <true/>
</dict>
</plist>
EOF

# --- Sign, inside out ---------------------------------------------------------------------------
sign() {
    if [ "$SIGN_IDENTITY" = "-" ]; then
        codesign --force --sign - "$@"
    else
        codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$@"
    fi
}
FW="$APP/Contents/Frameworks/Sparkle.framework"
sign "$FW/Versions/B/Autoupdate"
sign "$FW/Versions/B/Updater.app"
sign "$FW"
sign "$APP/Contents/MacOS/warcraft-survivors"
sign "$APP"
codesign --verify --strict --deep "$APP"
echo "built $APP ($VERSION, build $BUILD, $ARCHS, signed: $SIGN_IDENTITY)"

[ "$RELEASE" = 1 ] || exit 0

# --- Notarize, staple, package --------------------------------------------------------------------
notarize() {
    if [ -n "${NOTARY_KEY:-}" ]; then
        xcrun notarytool submit "$1" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
    elif [ -n "${NOTARY_APPLE_ID:-}" ]; then
        xcrun notarytool submit "$1" --apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID" --wait
    else
        xcrun notarytool submit "$1" --keychain-profile "${NOTARY_PROFILE:-AzerothSurvivors}" --wait
    fi
}

DIST="$OUT/dist"
rm -rf "$DIST" && mkdir -p "$DIST"
ZIP="$DIST/Hearthside-$VERSION.zip"
DMG="$DIST/Hearthside-$VERSION.dmg"

echo "notarizing the app…"
ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
notarize "$DIST/notarize.zip"
rm "$DIST/notarize.zip"
xcrun stapler staple "$APP"
# The zip Sparkle installs from: the stapled app.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "making the disk image…"
stage="$(mktemp -d)"
ditto "$APP" "$stage/$NAME.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "$NAME" -srcfolder "$stage" -fs APFS -format ULMO -ov "$DMG" >/dev/null
rm -rf "$stage"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

echo "signing the update…"
if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
    sig="$("$SPARKLE/bin/sign_update" --ed-key-file "$SPARKLE_KEY_FILE" "$ZIP")"
else
    sig="$("$SPARKLE/bin/sign_update" --account azeroth-survivors "$ZIP")"
fi
# What's new, shown in Sparkle's update dialog: macos/release-notes/<version>.md (a dry-run tag's
# suffix dropped), rendered by GitHub's own Markdown renderer. The workflow also uses it as the
# GitHub release text.
NOTES_MD="$ROOT/macos/release-notes/${VERSION%%-*}.md"
description=""
if [ -f "$NOTES_MD" ]; then
    cp "$NOTES_MD" "$OUT/release-notes.md"
    html="$(gh api markdown -f mode=gfm -f text="$(cat "$NOTES_MD")" 2>/dev/null)" \
        || html="<pre>$(sed 's/&/\&amp;/g; s/</\&lt;/g' "$NOTES_MD")</pre>"
    description="<description><![CDATA[<style>
        :root { color-scheme: light dark; }
        body { font: -apple-system-body; font-family: -apple-system, sans-serif; margin: 0 4px; }
        ul { padding-left: 1.3em; } li { margin: 0.25em 0; }
      </style>${html//]]>/]]]]><![CDATA[>}]]></description>"
else
    echo "warning: no $NOTES_MD, so the update dialog will show no release notes"
    rm -f "$OUT/release-notes.md"
fi
cat > "$DIST/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$NAME</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>$NAME $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_MACOS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      $description
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/$(basename "$ZIP")" type="application/octet-stream" $sig />
    </item>
  </channel>
</rss>
EOF
echo "release files in $DIST:"
ls -1 "$DIST"
