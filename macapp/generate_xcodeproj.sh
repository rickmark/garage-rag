#!/bin/bash
# Runs the rules_xcodeproj installer, then adds the Xcode build settings it has no
# attribute for to the generated project's project-level build settings.
#
# SKIP_EMBEDDED_FRAMEWORKS_VALIDATION: rules_apple's macos_framework produces a
# shallow bundle (PythonXPCService.framework has Info.plist at its root), which is
# what `aspect build //:macapp` ships. Xcode's Validate step on the app rejects that
# layout ("expected Versions/Current/Resources/Info.plist since the platform does not
# use shallow bundles"), so without this the Garage scheme cannot build in Xcode.
#
# DONT_RUN_SWIFT_STDLIB_TOOL: Xcode's CopySwiftLibs step scans every file under
# Contents/Frameworks for Swift runtime dependencies, and warns once per empty file
# in PythonXPCService.framework/site-python ("Failed to parse executable"). Bazel has
# already built the bundle, and the Swift runtime ships with macOS 14, so the step has
# nothing to copy.
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <rules_xcodeproj installer> [installer args...]" >&2
  exit 1
fi

installer="$1"
shift
"$installer" "$@"

pbxproj="$BUILD_WORKSPACE_DIRECTORY/macapp/Garage.xcodeproj/project.pbxproj"
# The installer leaves the project read-only.
chmod u+w "$pbxproj"

for setting in \
  "SKIP_EMBEDDED_FRAMEWORKS_VALIDATION = YES" \
  "DONT_RUN_SWIFT_STDLIB_TOOL = YES"; do
  name="${setting%% *}"
  grep -q "^[[:space:]]*$name = " "$pbxproj" && continue
  # The project-level configuration is the only build settings block that opens with
  # ALWAYS_SEARCH_USER_PATHS; every target inherits from it.
  /usr/bin/sed -i '' \
    "s/^\([[:space:]]*\)ALWAYS_SEARCH_USER_PATHS = NO;\$/&\\
\1$setting;/" \
    "$pbxproj"
  grep -q "^[[:space:]]*$name = " "$pbxproj" || {
    echo "error: could not add $name to $pbxproj" >&2
    exit 1
  }
done
