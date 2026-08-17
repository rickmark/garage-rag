#!/usr/bin/env bash
# Assembles GarageApp.app: release-builds the Swift app, vendors Postgres and
# the frozen Python side if they aren't already built, and packages the whole
# thing into a self-contained bundle in macapp/dist/.
set -euo pipefail

MACAPP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$MACAPP_DIR/dist"
APP="$DIST_DIR/GarageApp.app"

cd "$MACAPP_DIR"

if [ ! -x "Resources/postgres/bin/postgres" ]; then
    ./Scripts/vendor-postgres.sh
fi
if [ ! -x "Resources/python-dist/garage/garage" ]; then
    ./Scripts/build-python.sh
fi

echo "==> swift build -c release"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/GarageApp"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH" "$APP/Contents/MacOS/GarageApp"
cp -R "Resources/postgres" "$APP/Contents/Resources/postgres"
cp -R "Resources/python-dist" "$APP/Contents/Resources/python-dist"
cp "Scripts/Info.plist" "$APP/Contents/Info.plist"

echo "==> ad-hoc signing"
codesign --force --deep -s - "$APP"

echo "==> done: $APP ($(du -sh "$APP" | cut -f1))"
echo "    open it with: open '$APP'"
