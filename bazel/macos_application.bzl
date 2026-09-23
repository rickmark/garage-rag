"""Transitioned macos_application rules and macros."""

load("@rules_apple//apple:macos.bzl", _raw_macos_application = "macos_application")
load(
    "@rules_apple//apple:providers.bzl",
    "AppleBundleInfo",
    "AppleExtraOutputsInfo",
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

def _developer_id_transition_impl(settings, attr):
    return {
        "//command_line_option:platforms": ["//bazel:universal_developer_id"],
        "//command_line_option:macos_cpus": ["arm64"],
    }

_developer_id_transition = transition(
    implementation = _developer_id_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:platforms",
        "//command_line_option:macos_cpus",
    ],
)

# For other rules that stage the Developer ID app (lipo.bzl's macos_lipo_app).
developer_id_transition = _developer_id_transition

def _transition_app_impl(ctx):
    target = ctx.attr.app[0]
    orig_executable = target[DefaultInfo].files_to_run.executable

    executable = ctx.actions.declare_file(ctx.label.name)
    if orig_executable:
        rlocation = ctx.workspace_name + "/" + orig_executable.short_path
        runner_content = """#!/bin/bash
set -euo pipefail
EXEC_FILE=""
if [ -n "${{RUNFILES_DIR:-}}" ] && [ -x "${{RUNFILES_DIR}}/{rlocation}" ]; then
    EXEC_FILE="${{RUNFILES_DIR}}/{rlocation}"
elif [ -n "${{RUNFILES_MANIFEST_FILE:-}}" ]; then
    EXEC_FILE="$(grep -m 1 "^{rlocation} " "${{RUNFILES_MANIFEST_FILE}}" 2>/dev/null | cut -d' ' -f2- || true)"
fi

if [ -z "$EXEC_FILE" ] || [ ! -x "$EXEC_FILE" ]; then
    if [ -x "${{0}}.runfiles/{rlocation}" ]; then
        EXEC_FILE="${{0}}.runfiles/{rlocation}"
    elif [ -x "{short_path}" ]; then
        EXEC_FILE="{short_path}"
    fi
fi

if [ -z "$EXEC_FILE" ] || [ ! -x "$EXEC_FILE" ]; then
    echo "Error: Could not locate application executable ({short_path})" >&2
    exit 1
fi

exec "$EXEC_FILE" "$@"
""".format(
            rlocation = rlocation,
            short_path = orig_executable.short_path,
        )
        ctx.actions.write(
            output = executable,
            content = runner_content,
            is_executable = True,
        )
        runfiles = ctx.runfiles(files = [orig_executable]).merge(target[DefaultInfo].default_runfiles)
    else:
        ctx.actions.write(
            output = executable,
            content = "#!/bin/bash\nexit 0\n",
            is_executable = True,
        )
        runfiles = target[DefaultInfo].default_runfiles

    providers = [
        DefaultInfo(
            files = target[DefaultInfo].files,
            executable = executable,
            runfiles = runfiles,
        ),
    ]
    if OutputGroupInfo in target:
        providers.append(target[OutputGroupInfo])
    if AppleBundleInfo in target:
        providers.append(target[AppleBundleInfo])
    if AppleExtraOutputsInfo in target:
        providers.append(target[AppleExtraOutputsInfo])
    return providers

appstore_macos_application_transition = rule(
    implementation = _transition_app_impl,
    executable = True,
    attrs = {
        "app": attr.label(
            cfg = _appstore_transition,
            mandatory = True,
            doc = "The raw macos_application target to build with appstore config.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Builds a macos_application target with the --config=appstore transition.",
)

developer_id_macos_application_transition = rule(
    implementation = _transition_app_impl,
    executable = True,
    attrs = {
        "app": attr.label(
            cfg = _developer_id_transition,
            mandatory = True,
            doc = "The raw macos_application target to build with developer_id config.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Builds a macos_application target with the --config=developer_id transition.",
)

def appstore_macos_application(name, app = None, application = None, bundle = None, **kwargs):
    """Creates a macOS application target configured for App Store distribution via transition."""
    target_app = app or application or bundle

    # Manual whether or not the app is passed in: these sign with a distribution
    # identity, so `//...` (and CI, which has none) must not build them.
    tags = kwargs.pop("tags", [])
    if "manual" not in tags:
        tags = tags + ["manual"]
    if not target_app:
        raw_name = "_" + name.replace(".", "_") + "_raw"
        _raw_macos_application(
            name = raw_name,
            tags = tags,
            **kwargs
        )
        target_app = ":" + raw_name
        kwargs = {}

    appstore_macos_application_transition(
        name = name,
        app = target_app,
        tags = tags,
        **kwargs
    )

def developer_id_macos_application(name, app = None, application = None, bundle = None, **kwargs):
    """Creates a macOS application target configured for Developer ID distribution via transition."""
    target_app = app or application or bundle

    # Manual whether or not the app is passed in: these sign with a distribution
    # identity, so `//...` (and CI, which has none) must not build them.
    tags = kwargs.pop("tags", [])
    if "manual" not in tags:
        tags = tags + ["manual"]
    if not target_app:
        raw_name = "_" + name.replace(".", "_") + "_raw"
        _raw_macos_application(
            name = raw_name,
            tags = tags,
            **kwargs
        )
        target_app = ":" + raw_name
        kwargs = {}

    developer_id_macos_application_transition(
        name = name,
        app = target_app,
        tags = tags,
        **kwargs
    )
