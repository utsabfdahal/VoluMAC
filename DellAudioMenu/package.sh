#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
BUILD="$ROOT/build"
PACKAGING="$ROOT/Packaging"
DIST="$ROOT/dist"
PKGROOT="$BUILD/pkgroot"
SCRIPTS="$BUILD/pkgscripts"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")
PACKAGE="$DIST/VoluMAC-$VERSION.pkg"

"$ROOT/build.sh" >/dev/null

rm -rf "$PKGROOT" "$SCRIPTS"
mkdir -p "$PKGROOT/Applications" "$PKGROOT/Library/LaunchAgents" "$SCRIPTS" "$DIST"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr --noqtn \
    "$BUILD/VoluMAC.app" \
    "$PKGROOT/Applications/VoluMAC.app"
install -m 0644 \
    "$PACKAGING/io.github.utsabfdahal.volumac.plist" \
    "$PKGROOT/Library/LaunchAgents/io.github.utsabfdahal.volumac.plist"
install -m 0755 "$PACKAGING/scripts/preinstall" "$SCRIPTS/preinstall"
install -m 0755 "$PACKAGING/scripts/postinstall" "$SCRIPTS/postinstall"
xattr -cr "$PKGROOT" "$SCRIPTS"
find "$PKGROOT" "$SCRIPTS" -name '._*' -delete

rm -f "$PACKAGE" "$PACKAGE.sha256"
pkgbuild \
    --root "$PKGROOT" \
    --scripts "$SCRIPTS" \
    --component-plist "$PACKAGING/components.plist" \
    --identifier io.github.utsabfdahal.volumac.installer \
    --version "$VERSION" \
    --install-location / \
    --ownership recommended \
    "$PACKAGE"

(
    cd "$DIST"
    shasum -a 256 "${PACKAGE:t}" > "${PACKAGE:t}.sha256"
)

echo "$PACKAGE"
echo "$PACKAGE.sha256"
