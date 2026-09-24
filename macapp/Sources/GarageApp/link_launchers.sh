#!/bin/bash
# rules_apple `ipa_post_processor` for Garage.app: runs on the assembled bundle before it is
# signed, with one argument, a directory whose only entry is Garage.app. It creates the stable
# command-line entry points
#
#   Contents/MacOS/garage      -> ../Resources/launchers/garage
#   Contents/MacOS/garage-mcp  -> ../Resources/launchers/garage-mcp
#
# as symlinks to the forwarder scripts, which exec the launcher helper bundles in
# Contents/Helpers. A symlink rather than the script itself in Contents/MacOS: codesign treats
# every file there as nested code that must carry a signature of its own, which a script cannot,
# while a symlink is sealed as a symlink (a `symlink` entry in CodeResources) and `--deep --strict`
# verification accepts it. Bazel cannot ship a symlink as a source file, hence this step.
set -euo pipefail

root="$1"
app="$(find "$root" -mindepth 1 -maxdepth 1 -type d -name '*.app' | head -n 1)"
if [ -z "$app" ]; then
    echo "link_launchers: no .app in $root" >&2
    exit 1
fi

for name in garage garage-mcp; do
    forwarder="$app/Contents/Resources/launchers/$name"
    if [ ! -f "$forwarder" ]; then
        echo "link_launchers: missing forwarder $forwarder" >&2
        exit 1
    fi
    chmod 755 "$forwarder"
    link="$app/Contents/MacOS/$name"
    rm -f "$link"
    ln -s "../Resources/launchers/$name" "$link"
done
