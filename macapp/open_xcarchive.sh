#!/bin/bash
# Copies a Bazel-built .xcarchive (read-only, under bazel-out) into Xcode's own
# Archives directory as a writable copy, then opens it so Xcode Organizer picks
# it up for distribution/upload.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <path-to-xcarchive>" >&2
  exit 1
fi

src="$1"
name="$(basename "$src")"
dest_dir="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)"
dest="$dest_dir/$name"

mkdir -p "$dest_dir"
rm -rf "$dest"
# ditto (not cp -R) preserves symlinks and extended attributes, both of which
# matter for a codesigned app bundle.
ditto "$src" "$dest"
chmod -R u+w "$dest"

open "$dest"
