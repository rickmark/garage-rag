"""Transitioned xcarchive rules and macros.

The archive is assembled here rather than with rules_apple's `xcarchive`, which
unpacks the app with Python's zipfile: that writes symlinks out as plain files,
so a versioned framework (Python.framework's Versions/Current, Python and
Resources links) lost its signature in the archive while the same framework
in the .app was signed. `ditto` keeps symlinks, and the action verifies the
archived app's signature so a broken one fails the build, not the upload.
"""

load("@rules_apple//apple:providers.bzl", "AppleBundleInfo")

_ASSEMBLE = """set -euo pipefail
bundle="$1"
out="$2"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ -d "$bundle" ]; then
    ditto "$bundle" "$work/$(basename "$bundle")"
else
    ditto -x -k "$bundle" "$work"
fi
app="$(find "$work" -maxdepth 2 -type d -name '*.app' | head -n 1)"
if [ -z "$app" ]; then
    echo "xcarchive: no .app inside $bundle" >&2
    exit 1
fi

name="$(basename "$app")"
mkdir -p "$out/Products/Applications" "$out/dSYMs"
ditto "$app" "$out/Products/Applications/$name"
archived="$out/Products/Applications/$name"

if ! codesign --verify --deep --strict --verbose=2 "$archived"; then
    echo "xcarchive: $name is not validly signed inside the archive" >&2
    exit 1
fi

plist="$archived/Contents/Info.plist"
read_key() { plutil -extract "$1" raw -o - "$plist" 2>/dev/null || true; }
identity="$(codesign -dvv "$archived" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)"
info="$out/Info.plist"
plutil -create xml1 "$info"
plutil -insert ArchiveVersion -integer 2 "$info"
plutil -insert CreationDate -date "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$info"
plutil -insert Name -string "${name%.app}" "$info"
plutil -insert SchemeName -string "${name%.app}" "$info"
plutil -insert ApplicationProperties -dictionary "$info"
plutil -insert ApplicationProperties.ApplicationPath -string "Applications/$name" "$info"
plutil -insert ApplicationProperties.CFBundleIdentifier -string "$(read_key CFBundleIdentifier)" "$info"
plutil -insert ApplicationProperties.CFBundleShortVersionString -string "$(read_key CFBundleShortVersionString)" "$info"
plutil -insert ApplicationProperties.CFBundleVersion -string "$(read_key CFBundleVersion)" "$info"
plutil -insert ApplicationProperties.SigningIdentity -string "$identity" "$info"
"""

def _signed_xcarchive_impl(ctx):
    info = ctx.attr.bundle[AppleBundleInfo]
    out = ctx.actions.declare_directory(ctx.label.name + "/" + info.bundle_name + ".xcarchive")
    ctx.actions.run_shell(
        inputs = [info.archive],
        outputs = [out],
        arguments = [info.archive.path, out.path],
        command = _ASSEMBLE,
        mnemonic = "XcarchiveAssemble",
        progress_message = "Assembling %s.xcarchive" % info.bundle_name,
        # ditto, codesign and PlistBuddy are macOS tools.
        execution_requirements = {"no-remote": "1", "requires-darwin": "1"},
    )
    return [DefaultInfo(files = depset([out]))]

_raw_xcarchive = rule(
    implementation = _signed_xcarchive_impl,
    attrs = {
        "bundle": attr.label(
            mandatory = True,
            providers = [AppleBundleInfo],
            doc = "The signed macos_application to archive.",
        ),
    },
    doc = "An .xcarchive of a signed app, assembled with ditto so framework symlinks and signatures survive.",
)

def _appstore_transition_impl(settings, attr):
    return {
        "//command_line_option:platforms": ["//bazel:universal_store"],
        "//command_line_option:macos_cpus": ["arm64"],
    }

_appstore_transition = transition(
    implementation = _appstore_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:platforms",
        "//command_line_option:macos_cpus",
    ],
)

def _transition_archive_impl(ctx):
    target = ctx.attr.archive[0]
    providers = [target[DefaultInfo]]
    if OutputGroupInfo in target:
        providers.append(target[OutputGroupInfo])
    return providers

appstore_xcarchive_transition = rule(
    implementation = _transition_archive_impl,
    attrs = {
        "archive": attr.label(
            cfg = _appstore_transition,
            mandatory = True,
            doc = "The raw xcarchive target to build with appstore config.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Builds an xcarchive target with the --config=appstore transition.",
)

def appstore_xcarchive(name, bundle, **kwargs):
    """Creates an xcarchive target configured for App Store distribution via transition."""
    raw_name = "_" + name.replace(".", "_") + "_raw"
    _raw_xcarchive(
        name = raw_name,
        bundle = bundle,
        tags = ["manual"],
    )

    # Like the *_macos_application macros: the archive signs with the App Store
    # identity, which only a release machine has, so `//...` must not build it.
    tags = kwargs.pop("tags", [])
    if "manual" not in tags:
        tags = tags + ["manual"]
    appstore_xcarchive_transition(
        name = name,
        archive = ":" + raw_name,
        tags = tags,
        **kwargs
    )

def xcarchive(name, bundle, **kwargs):
    """Creates an xcarchive target (only supported for App Store configuration)."""
    appstore_xcarchive(name = name, bundle = bundle, **kwargs)
