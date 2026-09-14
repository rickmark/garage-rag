"""Rules for interacting with Apple's notary service using xcrun notarytool."""

MacosNotaryInfo = provider(
    doc = "Information about a macOS notarization target.",
    fields = {
        "keychain_profile": "The keychain profile name, if configured.",
        "target_file": "The file to be notarized.",
    },
)

NotaryInfo = MacosNotaryInfo

def _notarytool_impl(ctx):
    if not ctx.target_platform_has_constraint(ctx.attr._macos_constraint[platform_common.ConstraintValueInfo]):
        fail("{} only supports macOS targets".format(ctx.label))

    raw_targets = []
    if ctx.attr.app:
        raw_targets.append(ctx.attr.app)
    if ctx.attr.bundle:
        raw_targets.append(ctx.attr.bundle)
    if ctx.attr.pkg:
        raw_targets.append(ctx.attr.pkg)
    if ctx.attr.src:
        raw_targets.append(ctx.attr.src)
    if ctx.attr.srcs:
        raw_targets.extend(ctx.attr.srcs)
    if ctx.attr.apps:
        raw_targets.extend(ctx.attr.apps)
    if ctx.attr.pkgs:
        raw_targets.extend(ctx.attr.pkgs)

    if not raw_targets:
        fail("{}: 'app', 'bundle', 'pkg', 'src', 'srcs', 'apps', or 'pkgs' must be specified".format(ctx.label))

    target_files = []
    for t in raw_targets:
        t_files = t[DefaultInfo].files.to_list()
        for f in t_files:
            if f.path.endswith(".zip") or f.path.endswith(".pkg") or f.path.endswith(".dmg") or ".app" in f.path:
                if f not in target_files:
                    target_files.append(f)
        if not t_files:
            fail("{}: target '{}' did not produce any files".format(ctx.label, t.label))
        elif not any([f in target_files for f in t_files]):
            target_files.append(t_files[0])

    runner = ctx.actions.declare_file(ctx.label.name)
    extra_inputs = list(target_files)

    target_rlocations = [ctx.workspace_name + "/" + f.short_path for f in target_files]
    target_short_paths = [f.short_path for f in target_files]

    key_rlocation = ""
    key_short_path = ""
    if ctx.file.key:
        extra_inputs.append(ctx.file.key)
        key_rlocation = ctx.workspace_name + "/" + ctx.file.key.short_path
        key_short_path = ctx.file.key.short_path

    rlocations_str = " ".join(['"{}"'.format(loc) for loc in target_rlocations])
    short_paths_str = " ".join(['"{}"'.format(sp) for sp in target_short_paths])

    runner_content = """#!/bin/bash
set -euo pipefail

TARGET_RLOCATIONS=({rlocations_str})
TARGET_SHORT_PATHS=({short_paths_str})

RESOLVED_FILES=()
for i in "${{!TARGET_RLOCATIONS[@]}}"; do
    rloc="${{TARGET_RLOCATIONS[$i]}}"
    spath="${{TARGET_SHORT_PATHS[$i]}}"
    tfile=""
    if [ -n "${{RUNFILES_DIR:-}}" ] && [ -e "${{RUNFILES_DIR}}/$rloc" ]; then
        tfile="${{RUNFILES_DIR}}/$rloc"
    elif [ -n "${{RUNFILES_MANIFEST_FILE:-}}" ]; then
        tfile="$(grep -m 1 "^$rloc " "${{RUNFILES_MANIFEST_FILE}}" 2>/dev/null | cut -d' ' -f2- || true)"
    fi

    if [ -z "$tfile" ] || [ ! -e "$tfile" ]; then
        if [ -e "${{0}}.runfiles/$rloc" ]; then
            tfile="${{0}}.runfiles/$rloc"
        elif [ -e "${{0}}.runfiles/_main/$spath" ]; then
            tfile="${{0}}.runfiles/_main/$spath"
        elif [ -e "$spath" ]; then
            tfile="$spath"
        fi
    fi

    if [ -z "$tfile" ] || [ ! -e "$tfile" ]; then
        echo "Error: Could not locate target file ($spath)" >&2
        exit 1
    fi
    RESOLVED_FILES+=("$tfile")
done

KEY_FILE=""
if [ -n "{key_rlocation}" ]; then
    if [ -n "${{RUNFILES_DIR:-}}" ] && [ -f "${{RUNFILES_DIR}}/{key_rlocation}" ]; then
        KEY_FILE="${{RUNFILES_DIR}}/{key_rlocation}"
    elif [ -n "${{RUNFILES_MANIFEST_FILE:-}}" ]; then
        KEY_FILE="$(grep -m 1 "^{key_rlocation} " "${{RUNFILES_MANIFEST_FILE}}" 2>/dev/null | cut -d' ' -f2- || true)"
    fi

    if [ -z "$KEY_FILE" ] || [ ! -f "$KEY_FILE" ]; then
        if [ -f "${{0}}.runfiles/{key_rlocation}" ]; then
            KEY_FILE="${{0}}.runfiles/{key_rlocation}"
        elif [ -f "${{0}}.runfiles/_main/{key_short_path}" ]; then
            KEY_FILE="${{0}}.runfiles/_main/{key_short_path}"
        elif [ -f "{key_short_path}" ]; then
            KEY_FILE="{key_short_path}"
        fi
    fi
fi

default_args=()
if [ -n "{keychain_profile}" ]; then
    default_args+=(--keychain-profile "{keychain_profile}")
fi
if [ -n "{keychain}" ]; then
    default_args+=(--keychain "{keychain}")
fi
if [ -n "$KEY_FILE" ]; then
    default_args+=(--key "$KEY_FILE")
fi
if [ -n "{key_id}" ]; then
    default_args+=(--key-id "{key_id}")
fi
if [ -n "{issuer}" ]; then
    default_args+=(--issuer "{issuer}")
fi
if [ -n "{apple_id}" ]; then
    default_args+=(--apple-id "{apple_id}")
fi
if [ -n "{team_id}" ]; then
    default_args+=(--team-id "{team_id}")
fi
if [ -n "{password}" ]; then
    default_args+=(--password "{password}")
fi
if [ "{wait}" = "true" ]; then
    default_args+=(--wait)
fi
if [ -n "{notary_timeout}" ]; then
    default_args+=(--timeout "{notary_timeout}")
fi
if [ -n "{output_format}" ]; then
    default_args+=(--output-format "{output_format}")
fi

subcommand="submit"
extra_args=()

if [ $# -gt 0 ]; then
    case "$1" in
        submit)
            subcommand="submit"
            shift
            extra_args=("$@")
            ;;
        history|info|log|wait|store-credentials)
            subcommand="$1"
            shift
            extra_args=("$@")
            ;;
        *)
            subcommand="submit"
            extra_args=("$@")
            ;;
    esac
fi

for TARGET_FILE in "${{RESOLVED_FILES[@]}}"; do
    FILE_TO_SUBMIT="$TARGET_FILE"
    TMP_DIR=""
    if [ -d "$TARGET_FILE" ]; then
        TMP_DIR="$(mktemp -d)"
        TMP_ZIP="$TMP_DIR/$(basename "$TARGET_FILE").zip"
        echo "==> Packaging directory into temporary zip for notarization: $TMP_ZIP"
        /usr/bin/ditto -c -k --keepParent "$TARGET_FILE" "$TMP_ZIP"
        FILE_TO_SUBMIT="$TMP_ZIP"
    fi

    if [ "$subcommand" = "submit" ]; then
        echo "==> Running xcrun notarytool submit on $FILE_TO_SUBMIT..."
        cmd=(xcrun notarytool submit "$FILE_TO_SUBMIT")
        if [ ${{#default_args[@]}} -gt 0 ]; then
            cmd+=("${{default_args[@]}}")
        fi
        if [ ${{#extra_args[@]}} -gt 0 ]; then
            cmd+=("${{extra_args[@]}}")
        fi
        "${{cmd[@]}}"
    else
        echo "==> Running xcrun notarytool $subcommand..."
        cmd=(xcrun notarytool "$subcommand")
        if [ ${{#extra_args[@]}} -gt 0 ]; then
            cmd+=("${{extra_args[@]}}")
        fi
        "${{cmd[@]}}"
    fi

    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
done
""".format(
        apple_id = ctx.attr.apple_id,
        issuer = ctx.attr.issuer,
        key_id = ctx.attr.key_id,
        key_rlocation = key_rlocation,
        key_short_path = key_short_path,
        keychain = ctx.attr.keychain,
        keychain_profile = ctx.attr.keychain_profile,
        notary_timeout = ctx.attr.notary_timeout,
        output_format = ctx.attr.output_format,
        password = ctx.attr.password,
        rlocations_str = rlocations_str,
        short_paths_str = short_paths_str,
        team_id = ctx.attr.team_id,
        wait = "true" if ctx.attr.wait else "false",
    )

    ctx.actions.write(
        output = runner,
        content = runner_content,
        is_executable = True,
    )

    return [
        DefaultInfo(
            files = depset(target_files),
            executable = runner,
            runfiles = ctx.runfiles(files = extra_inputs),
        ),
        MacosNotaryInfo(
            keychain_profile = ctx.attr.keychain_profile,
            target_file = target_files[0] if target_files else None,
        ),
    ]

notarytool = rule(
    implementation = _notarytool_impl,
    executable = True,
    doc = "Submits an application, package, or archive to Apple's notary service via xcrun notarytool.",
    attrs = {
        "app": attr.label(
            doc = "Target providing a macOS application (.app or .zip), package (.pkg), or archive (.dmg).",
        ),
        "apps": attr.label_list(
            doc = "List of targets providing macOS applications (.app or .zip).",
        ),
        "apple_id": attr.string(
            doc = "Developer Apple ID username.",
        ),
        "bundle": attr.label(
            doc = "Alias for app.",
        ),
        "issuer": attr.string(
            doc = "App Store Connect API Issuer ID (UUID format).",
        ),
        "key": attr.label(
            allow_single_file = True,
            doc = "App Store Connect API private key file (.p8).",
        ),
        "key_id": attr.string(
            doc = "App Store Connect API Key ID.",
        ),
        "keychain": attr.string(
            doc = "Path to custom keychain containing notary credentials.",
        ),
        "keychain_profile": attr.string(
            doc = "Name of the keychain credentials profile stored via notarytool store-credentials.",
        ),
        "notary_timeout": attr.string(
            doc = "Optional time limit for wait (e.g. 60m, 1h).",
        ),
        "output_format": attr.string(
            values = ["", "normal", "json", "plist"],
            doc = "Desired output format.",
        ),
        "password": attr.string(
            doc = "App-specific password for your Apple ID.",
        ),
        "pkg": attr.label(
            doc = "Alias for app.",
        ),
        "pkgs": attr.label_list(
            doc = "List of targets providing macOS installer packages (.pkg).",
        ),
        "src": attr.label(
            doc = "Alias for app.",
        ),
        "srcs": attr.label_list(
            doc = "Alias for app.",
        ),
        "team_id": attr.string(
            doc = "Developer Team ID.",
        ),
        "wait": attr.bool(
            default = True,
            doc = "Whether to wait for notarization to complete before exiting.",
        ),
        "_macos_constraint": attr.label(
            default = Label("@platforms//os:macos"),
        ),
    },
)

macos_notarytool = notarytool
notarize = notarytool
