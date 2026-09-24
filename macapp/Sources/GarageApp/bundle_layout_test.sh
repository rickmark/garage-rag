#!/bin/bash
# Checks the launcher layout of the built Garage.app (its .zip is the one argument):
#
#   Contents/MacOS/garage, garage-mcp              executable /bin/sh forwarders (not Mach-O)
#   Contents/Helpers/garage.app                    bundle ID me.rickmark.garage-rag.garage-cli
#   Contents/Helpers/garage-mcp.app                bundle ID me.rickmark.garage-rag.mcp-server-cli
#
# with each helper's executable a Mach-O that reaches the app's Frameworks through its rpaths,
# marked LSUIElement, and `garage version` running through the forwarder: the forwarder resolves
# the helper, the helper resolves the app bundle, and the embedded interpreter starts from the
# app's PythonXPCService.framework. `version` needs no database, so no app is started and no
# Keychain is read.
set -euo pipefail

archive="$1"
work="$(mktemp -d "${TMPDIR:-/tmp}/bundle_layout_test.XXXXXX")"
trap 'chmod -R u+w "$work" 2>/dev/null || true; rm -rf "$work"' EXIT
# The archive is a .zip, or the bundle directory itself under tree-artifact outputs.
if [ -d "$archive" ]; then
    /usr/bin/ditto "$archive" "$work/$(basename "$archive")"
elif [ -f "$archive" ]; then
    /usr/bin/ditto -x -k "$archive" "$work"
else
    echo "no archive at $archive" >&2
    exit 1
fi
app="$work/Garage.app"
[ -d "$app" ] || { echo "no Garage.app in $archive" >&2; exit 1; }

failures=0
fail() {
    echo "[FAIL] $*"
    failures=$((failures + 1))
}
pass() {
    echo "[PASS] $*"
}

check_forwarder() {
    local name="$1" helper="$2"
    local link="$app/Contents/MacOS/$name"
    local script="$app/Contents/Resources/launchers/$name"
    if [ ! -L "$link" ]; then
        fail "$name: Contents/MacOS/$name is not a symlink"
        return
    fi
    local target
    target="$(readlink "$link")"
    [ "$target" = "../Resources/launchers/$name" ] \
        || fail "$name: Contents/MacOS/$name links to '$target', expected ../Resources/launchers/$name"
    if [ ! -f "$script" ] || [ -L "$script" ]; then
        fail "$name: Contents/Resources/launchers/$name is not a regular file"
        return
    fi
    [ -x "$script" ] || fail "$name: forwarder script is not executable"
    if file -b "$script" | grep -q "Mach-O"; then
        fail "$name: forwarder is a Mach-O, not a script"
    fi
    head -n 1 "$script" | grep -q '^#!/bin/sh' || fail "$name: forwarder does not start with #!/bin/sh"
    grep -q "Helpers/$helper/Contents/MacOS" "$script" || fail "$name: forwarder does not name Helpers/$helper"
    pass "$name: Contents/MacOS/$name -> Resources/launchers/$name, forwarding to Helpers/$helper"
}

check_helper() {
    local name="$1" bundle_id="$2"
    local helper="$app/Contents/Helpers/$name.app"
    local plist="$helper/Contents/Info.plist"
    local executable="$helper/Contents/MacOS/$name"
    [ -d "$helper" ] || { fail "$name: no Contents/Helpers/$name.app"; return; }
    [ -f "$plist" ] || { fail "$name: helper has no Info.plist"; return; }

    local actual_id
    actual_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null || true)"
    [ "$actual_id" = "$bundle_id" ] || fail "$name: CFBundleIdentifier is '$actual_id', expected '$bundle_id'"
    local ui_element
    ui_element="$(/usr/libexec/PlistBuddy -c "Print :LSUIElement" "$plist" 2>/dev/null || true)"
    [ "$ui_element" = "true" ] || fail "$name: LSUIElement is '$ui_element', expected true"
    local cf_executable
    cf_executable="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$plist" 2>/dev/null || true)"
    [ "$cf_executable" = "$name" ] || fail "$name: CFBundleExecutable is '$cf_executable', expected '$name'"

    [ -x "$executable" ] || { fail "$name: helper executable missing or not executable"; return; }
    file -b "$executable" | grep -q "Mach-O" || fail "$name: helper executable is not a Mach-O"
    otool -l "$executable" | grep -q "path @executable_path/../../../../Frameworks (offset" \
        || fail "$name: helper lacks the @executable_path/../../../../Frameworks rpath"
    otool -L "$executable" | grep -q "Python.framework" || fail "$name: helper does not link Python.framework"
    otool -L "$executable" | grep -q "PythonXPCService.framework" \
        || fail "$name: helper does not link PythonXPCService.framework"

    local signing_id
    signing_id="$(codesign -dv "$helper" 2>&1 | sed -n 's/^Identifier=//p')"
    [ "$signing_id" = "$bundle_id" ] || fail "$name: signing identifier is '$signing_id', expected '$bundle_id'"
    pass "$name: Contents/Helpers/$name.app is $bundle_id"
}

check_forwarder garage garage.app
check_forwarder garage-mcp garage-mcp.app
check_helper garage me.rickmark.garage-rag.garage-cli
check_helper garage-mcp me.rickmark.garage-rag.mcp-server-cli

# No stray bare launchers left in Contents/MacOS: the app's executable and the two forwarders only.
for entry in "$app/Contents/MacOS"/*; do
    case "$(basename "$entry")" in
        GarageApp|garage|garage-mcp) ;;
        *) fail "unexpected entry in Contents/MacOS: $(basename "$entry")" ;;
    esac
done

# Through the forwarder, end to end. GARAGE_NO_APP_LAUNCH guards against any path that would
# open the app; `version` takes none.
output="$(cd "$work" && GARAGE_NO_APP_LAUNCH=1 "$app/Contents/MacOS/garage" version 2>&1)" && status=0 || status=$?
if [ "$status" -ne 0 ]; then
    fail "garage version exited $status through the forwarder:"
    printf '%s\n' "$output" | sed 's/^/       /'
else
    pass "garage version through the forwarder: $(printf '%s' "$output" | head -n 1)"
fi

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "bundle layout OK"
