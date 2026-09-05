"""Rule for generating Apple bundle version info with auto-incrementing build number."""

load(
    "@rules_apple//apple:providers.bzl",
    "apple_provider",
)

def _macapp_version_impl(ctx):
    out_file = ctx.actions.declare_file(ctx.label.name + ".bundle_version.json")

    ctx.actions.run_shell(
        inputs = [ctx.info_file, ctx.version_file],
        outputs = [out_file],
        command = """\
/usr/bin/python3 -c '
import json, os, sys

info_file = sys.argv[1]
version_file = sys.argv[2]
out_file = sys.argv[3]
short_version = sys.argv[4]
fallback_build = sys.argv[5]

build_number = None

def read_kv(path):
    kv = {}
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                parts = line.strip().split(" ", 1)
                if len(parts) == 2:
                    kv[parts[0]] = parts[1]
    return kv

info_kv = read_kv(info_file)
version_kv = read_kv(version_file)

for key in ["STABLE_BUILD_NUMBER", "STABLE_GIT_COMMIT_COUNT", "BUILD_EMBED_LABEL"]:
    if key in info_kv and info_kv[key]:
        build_number = info_kv[key]
        break

if not build_number:
    for key in ["BUILD_EMBED_LABEL", "STABLE_BUILD_NUMBER", "STABLE_GIT_COMMIT_COUNT"]:
        if key in version_kv and version_kv[key]:
            build_number = version_kv[key]
            break

if not build_number:
    build_number = fallback_build

version_data = {
    "build_version": str(build_number),
    "short_version_string": str(short_version),
}

with open(out_file, "w", encoding="utf-8") as f:
    json.dump(version_data, f, indent=2)
' "$1" "$2" "$3" "$4" "$5"
""",
        arguments = [
            ctx.info_file.path,
            ctx.version_file.path,
            out_file.path,
            ctx.attr.short_version_string,
            ctx.attr.fallback_build_version,
        ],
        mnemonic = "MacAppBundleVersion",
    )

    return [
        apple_provider.make_apple_bundle_version_info(
            version_file = out_file,
        ),
        DefaultInfo(files = depset([out_file])),
    ]

macapp_version = rule(
    implementation = _macapp_version_impl,
    attrs = {
        "short_version_string": attr.string(
            mandatory = True,
            doc = "The CFBundleShortVersionString (e.g. '0.7.2')",
        ),
        "fallback_build_version": attr.string(
            default = "1",
            doc = "Fallback build number if workspace status is not available",
        ),
    },
    doc = "Generates AppleBundleVersionInfo with auto-incrementing build number from workspace status.",
)
