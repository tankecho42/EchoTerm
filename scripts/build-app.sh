#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-debug}"
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
# Sign outside Documents: File Provider can re-create FinderInfo during signing.
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/EchoTerm-build.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
staging_app="$staging_dir/EchoTerm.app"
# File Provider reattaches FinderInfo even after a successful in-place signature.
# Keep the runnable bundle outside synced Documents; dist contains a link and a zip.
build_root="${ECHOTERM_BUILD_ROOT:-$HOME/Library/Application Support/EchoTerm/Builds}"
app_path="$build_root/EchoTerm.app"
mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Resources" "$PWD/dist" "$build_root"
cp "$binary_dir/EchoTerm" "$staging_app/Contents/MacOS/EchoTerm"
cp scripts/Info.plist "$staging_app/Contents/Info.plist"
ditto --norsrc --noextattr "$binary_dir/EchoTerm_EchoTerm.bundle" "$staging_app/Contents/Resources/EchoTerm_EchoTerm.bundle"
if [[ -f assets/EchoTerm.icns ]]; then cp assets/EchoTerm.icns "$staging_app/Contents/Resources/EchoTerm.icns"; fi
cp .build/checkouts/SwiftTerm/LICENSE "$staging_app/Contents/Resources/SwiftTerm-LICENSE.txt"
chmod u+w "$staging_app/Contents/Resources/SwiftTerm-LICENSE.txt"
xattr -cr "$staging_app"
codesign --force --deep --sign - "$staging_app"
# Replace the bundle instead of overwriting the executable inode of a running app.
previous_app="$build_root/.EchoTerm.previous.$RANDOM.app"
if [[ -d "$app_path" ]]; then mv "$app_path" "$previous_app"; fi
if ditto --norsrc --noextattr "$staging_app" "$app_path" && codesign --verify --deep --strict "$app_path"; then
    if [[ -d "$previous_app" ]]; then rm -rf "$previous_app"; fi
else
    rm -rf "$app_path"
    if [[ -d "$previous_app" ]]; then mv "$previous_app" "$app_path"; fi
    print -u2 'Packaging failed; previous bundle restored.'
    exit 1
fi
if [[ -L "$PWD/dist/EchoTerm.app" ]]; then
    rm "$PWD/dist/EchoTerm.app"
elif [[ -d "$PWD/dist/EchoTerm.app" ]]; then
    rm -rf "$PWD/dist/EchoTerm.app"
fi
ln -s "$app_path" "$PWD/dist/EchoTerm.app"
ditto -c -k --norsrc --noextattr --keepParent "$app_path" "$PWD/dist/.EchoTerm.zip.partial"
mv -f "$PWD/dist/.EchoTerm.zip.partial" "$PWD/dist/EchoTerm.zip"
print "Built: $app_path"
print "Distribution: $PWD/dist/EchoTerm.app and EchoTerm.zip"
