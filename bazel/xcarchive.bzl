"""Transitioned xcarchive rules and macros."""

load("@rules_apple//apple:xcarchive.bzl", _raw_xcarchive = "xcarchive")

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
    appstore_xcarchive_transition(
        name = name,
        archive = ":" + raw_name,
        **kwargs
    )

def xcarchive(name, bundle, **kwargs):
    """Creates an xcarchive target (only supported for App Store configuration)."""
    appstore_xcarchive(name = name, bundle = bundle, **kwargs)
