"""Bazel rules and macros for PyOxidizer.

This module provides rules and macros to build and run Python applications
using PyOxidizer, with first-class support for `py_binary` targets and `uv` requirements.
"""

load("@rules_python//python:py_info.bzl", "PyInfo")

def _uv_export_requirements_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.out if ctx.attr.out else ctx.label.name + ".txt")

    inputs = [ctx.file.lock]
    if ctx.file.pyproject:
        inputs.append(ctx.file.pyproject)

    project_dir = ctx.file.pyproject.dirname if ctx.file.pyproject else ctx.file.lock.dirname
    if not project_dir:
        project_dir = "."

    cmd_args = ["export"]
    cmd_args.extend(["--project", project_dir])
    cmd_args.extend(["--output-file", out.path])

    if ctx.attr.no_dev:
        cmd_args.append("--no-dev")
    if ctx.attr.no_emit_project:
        cmd_args.append("--no-emit-project")
    if ctx.attr.no_hashes:
        cmd_args.append("--no-hashes")
    if ctx.attr.frozen:
        cmd_args.append("--frozen")
    if ctx.attr.all_packages:
        cmd_args.append("--all-packages")
    cmd_args.extend(ctx.attr.extra_args)

    ctx.actions.run(
        outputs = [out],
        inputs = inputs,
        executable = ctx.executable.uv,
        arguments = cmd_args,
        mnemonic = "UvExportRequirements",
        progress_message = "Exporting requirements with uv for %{label}",
        use_default_shell_env = True,
        env = {
            "UV_CACHE_DIR": "/tmp",
            "UV_NO_CACHE": "1",
        },
    )

    return [
        DefaultInfo(
            files = depset([out]),
        ),
    ]

uv_export_requirements = rule(
    implementation = _uv_export_requirements_impl,
    doc = "Exports a requirements.txt file from a uv.lock file using uv export.",
    attrs = {
        "lock": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "The uv.lock file.",
        ),
        "pyproject": attr.label(
            allow_single_file = True,
            doc = "Optional pyproject.toml file.",
        ),
        "out": attr.string(
            doc = "Output filename. Defaults to <name>.txt.",
        ),
        "no_dev": attr.bool(
            default = True,
            doc = "Exclude development dependencies.",
        ),
        "no_emit_project": attr.bool(
            default = True,
            doc = "Do not emit the project package itself into requirements.",
        ),
        "no_hashes": attr.bool(
            default = True,
            doc = "Do not include package hashes in exported requirements.",
        ),
        "frozen": attr.bool(
            default = False,
            doc = "Run in frozen mode without updating lockfile.",
        ),
        "all_packages": attr.bool(
            default = False,
            doc = "Export all packages in the workspace.",
        ),
        "extra_args": attr.string_list(
            default = [],
            doc = "Additional arguments to pass to uv export.",
        ),
        "uv": attr.label(
            default = Label("@uv//:uv"),
            executable = True,
            allow_single_file = True,
            cfg = "exec",
            doc = "The uv executable binary.",
        ),
    },
)

def _pyoxidizer_build_impl(ctx):
    out_dir = ctx.actions.declare_directory(ctx.attr.out_dir if ctx.attr.out_dir else ctx.label.name)

    inputs = []
    if ctx.file.config:
        inputs.append(ctx.file.config)
    inputs.extend(ctx.files.srcs)
    inputs.extend(ctx.files.data)

    if ctx.file.requirements:
        inputs.append(ctx.file.requirements)

    if ctx.attr.binary:
        inputs.extend(ctx.attr.binary[DefaultInfo].files.to_list())
        inputs.extend(ctx.attr.binary[DefaultInfo].default_runfiles.files.to_list())
        if PyInfo in ctx.attr.binary:
            inputs.extend(ctx.attr.binary[PyInfo].transitive_sources.to_list())

    config_path = ctx.file.config.dirname if ctx.file.config else "."
    if not config_path:
        config_path = "."

    cmd_args = ["build"]
    cmd_args.extend(["--path", config_path])

    if ctx.attr.release:
        cmd_args.append("--release")

    for k, v in ctx.attr.vars.items():
        cmd_args.extend(["--var", k, v])

    for k, v in ctx.attr.var_envs.items():
        cmd_args.extend(["--var-env", k, v])

    if ctx.attr.target_triple:
        cmd_args.extend(["--target-triple", ctx.attr.target_triple])

    cmd_args.extend(ctx.attr.extra_args)

    if ctx.attr.target:
        cmd_args.append(ctx.attr.target)

    # Shell script to invoke PyOxidizer build and capture the build output directory
    script = """#!/usr/bin/env bash
set -euo pipefail

PYOX_BIN="$1"
OUT_DIR="$2"
CONFIG_FILE="$3"
shift 3

if [ -f "$CONFIG_FILE" ]; then
    if [ "$(basename "$CONFIG_FILE")" = "pyoxidizer.bzl" ]; then
        CONFIG_PATH="$(dirname "$CONFIG_FILE")"
    else
        WORK_DIR="$(mktemp -d)"
        trap 'rm -rf "$WORK_DIR"' EXIT
        cp "$CONFIG_FILE" "$WORK_DIR/pyoxidizer.bzl"
        CONFIG_PATH="$WORK_DIR"
    fi
else
    CONFIG_PATH="."
fi

"$PYOX_BIN" "$@" --path "$CONFIG_PATH"

# Copy the build artifacts from the build directory to the output directory
if [ -d "$CONFIG_PATH/build" ]; then
    cp -RL "$CONFIG_PATH/build/." "$OUT_DIR/"
elif [ -d "build" ]; then
    cp -RL "build/." "$OUT_DIR/"
else
    mkdir -p "$OUT_DIR"
fi
"""

    ctx.actions.run_shell(
        outputs = [out_dir],
        inputs = inputs,
        tools = [ctx.executable.pyoxidizer],
        command = script,
        arguments = [
            ctx.executable.pyoxidizer.path,
            out_dir.path,
            ctx.file.config.path if ctx.file.config else "",
        ] + cmd_args,
        mnemonic = "PyOxidizerBuild",
        progress_message = "Building %{label} with PyOxidizer",
        use_default_shell_env = True,
        execution_requirements = {
            "requires-network": "1",
            "no-sandbox": "1",
        },
    )

    return [
        DefaultInfo(
            files = depset([out_dir]),
            runfiles = ctx.runfiles(files = [out_dir]),
        ),
    ]

pyoxidizer_build = rule(
    implementation = _pyoxidizer_build_impl,
    doc = "Builds a PyOxidizer project into an output directory containing the packaged application artifacts.",
    attrs = {
        "config": attr.label(
            allow_single_file = True,
            doc = "PyOxidizer configuration file (e.g., pyoxidizer.bzl).",
        ),
        "binary": attr.label(
            doc = "Optional py_binary target providing Python sources and runfiles.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Source files needed during the build.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Additional data files needed during the build.",
        ),
        "requirements": attr.label(
            allow_single_file = True,
            doc = "Optional requirements file for dependencies.",
        ),
        "target": attr.string(
            doc = "Target to resolve in the configuration file.",
        ),
        "target_triple": attr.string(
            doc = "Rust target triple to build for.",
        ),
        "release": attr.bool(
            default = True,
            doc = "Whether to build in release mode.",
        ),
        "vars": attr.string_dict(
            default = {},
            doc = "Variables to pass to PyOxidizer via --var <name> <value>.",
        ),
        "var_envs": attr.string_dict(
            default = {},
            doc = "Variables to pass to PyOxidizer via --var-env <name> <env>.",
        ),
        "extra_args": attr.string_list(
            default = [],
            doc = "Additional arguments to pass to PyOxidizer build.",
        ),
        "out_dir": attr.string(
            doc = "Custom name for output directory. Defaults to target name.",
        ),
        "pyoxidizer": attr.label(
            default = Label("@multitool//tools/pyoxidizer"),
            executable = True,
            allow_single_file = True,
            cfg = "exec",
            doc = "The PyOxidizer executable binary.",
        ),
    },
)

def _pyoxidizer_run_impl(ctx):
    executable = ctx.actions.declare_file(ctx.label.name)

    inputs = []
    if ctx.file.config:
        inputs.append(ctx.file.config)
    inputs.extend(ctx.files.srcs)
    inputs.extend(ctx.files.data)

    config_dir = ctx.file.config.dirname if ctx.file.config else "."
    if not config_dir:
        config_dir = "."

    cmd_args = ["run"]
    cmd_args.extend(["--path", config_dir])

    if ctx.attr.release:
        cmd_args.append("--release")

    for k, v in ctx.attr.vars.items():
        cmd_args.extend(["--var", k, v])

    for k, v in ctx.attr.var_envs.items():
        cmd_args.extend(["--var-env", k, v])

    if ctx.attr.target_triple:
        cmd_args.extend(["--target-triple", ctx.attr.target_triple])

    cmd_args.extend(ctx.attr.extra_args)

    if ctx.attr.target:
        cmd_args.append(ctx.attr.target)

    # Generate runner wrapper script
    script_content = """#!/usr/bin/env bash
set -euo pipefail

# Locate runfiles directory
if [ -z "${RUNFILES_DIR:-}" ]; then
    if [ -n "${RUNFILES_MANIFEST_FILE:-}" ]; then
        RUNFILES_DIR="$(dirname "$RUNFILES_MANIFEST_FILE")"
    else
        RUNFILES_DIR="$0.runfiles"
    fi
fi

PYOX_BIN="${RUNFILES_DIR}/%s/%s"
if [ ! -f "$PYOX_BIN" ]; then
    # Fallback when running without manifest
    PYOX_BIN="%s"
fi

exec "$PYOX_BIN" %s "$@"
""" % (
        ctx.workspace_name,
        ctx.executable.pyoxidizer.short_path,
        ctx.executable.pyoxidizer.short_path,
        " ".join(['"%s"' % a for a in cmd_args]),
    )

    ctx.actions.write(
        output = executable,
        content = script_content,
        is_executable = True,
    )

    runfiles = ctx.runfiles(
        files = inputs + [ctx.executable.pyoxidizer],
    )
    runfiles = runfiles.merge(ctx.attr.pyoxidizer[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(
            executable = executable,
            runfiles = runfiles,
        ),
    ]

pyoxidizer_run = rule(
    implementation = _pyoxidizer_run_impl,
    executable = True,
    doc = "Creates an executable target that invokes `pyoxidizer run` with configured arguments.",
    attrs = {
        "config": attr.label(
            allow_single_file = True,
            doc = "PyOxidizer configuration file.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Source files needed during run.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Data files needed during run.",
        ),
        "target": attr.string(
            doc = "Target to run.",
        ),
        "target_triple": attr.string(
            doc = "Rust target triple to build for.",
        ),
        "release": attr.bool(
            default = True,
            doc = "Whether to build in release mode.",
        ),
        "vars": attr.string_dict(
            default = {},
            doc = "Variables to pass to PyOxidizer via --var <name> <value>.",
        ),
        "var_envs": attr.string_dict(
            default = {},
            doc = "Variables to pass to PyOxidizer via --var-env <name> <env>.",
        ),
        "extra_args": attr.string_list(
            default = [],
            doc = "Additional arguments to pass to PyOxidizer.",
        ),
        "pyoxidizer": attr.label(
            default = Label("@multitool//tools/pyoxidizer"),
            executable = True,
            allow_single_file = True,
            cfg = "exec",
            doc = "The PyOxidizer executable binary.",
        ),
    },
)

def _pyoxidizer_binary_impl(ctx):
    output_bin = ctx.actions.declare_file(ctx.label.name)
    py_config = ctx.actions.declare_file(ctx.label.name + "_pyoxidizer.bzl")

    inputs = [py_config]
    inputs.extend(ctx.files.srcs)
    inputs.extend(ctx.files.data)

    # 1. Handle requirements & uv lock
    req_file = None
    if ctx.file.requirements:
        req_file = ctx.file.requirements
        inputs.append(req_file)
    elif ctx.file.uv_lock:
        req_file = ctx.actions.declare_file(ctx.label.name + "_uv_requirements.txt")
        uv_inputs = [ctx.file.uv_lock]
        if ctx.file.pyproject:
            uv_inputs.append(ctx.file.pyproject)

        project_dir = ctx.file.pyproject.dirname if ctx.file.pyproject else ctx.file.uv_lock.dirname
        if not project_dir:
            project_dir = "."

        uv_args = ["export", "--project", project_dir, "--output-file", req_file.path, "--no-dev", "--no-emit-project", "--no-hashes"]
        ctx.actions.run(
            outputs = [req_file],
            inputs = uv_inputs,
            executable = ctx.executable.uv,
            arguments = uv_args,
            mnemonic = "UvExportRequirementsForPyOxidizer",
            progress_message = "Exporting requirements from %s for %s" % (ctx.file.uv_lock.path, ctx.label.name),
            use_default_shell_env = True,
            env = {
                "UV_CACHE_DIR": "/tmp",
                "UV_NO_CACHE": "1",
            },
        )
        inputs.append(req_file)

    # 2. Handle py_binary input
    main_file_path = None
    if ctx.attr.binary:
        inputs.extend(ctx.attr.binary[DefaultInfo].files.to_list())
        inputs.extend(ctx.attr.binary[DefaultInfo].default_runfiles.files.to_list())
        if PyInfo in ctx.attr.binary:
            inputs.extend(ctx.attr.binary[PyInfo].transitive_sources.to_list())
        if ctx.attr.binary[DefaultInfo].files_to_run.executable:
            main_file_path = ctx.attr.binary[DefaultInfo].files_to_run.executable.path

    # 3. Construct PyOxidizer Starlark configuration
    pip_install_code = ""
    if req_file:
        pip_install_code = 'exe.add_python_resources(exe.pip_install(["-r", "{}"]))'.format(req_file.path)

    package_code = ""
    for root in ctx.attr.package_roots:
        if ctx.attr.packages:
            package_code += '\n    exe.add_python_resources(exe.read_package_root(path="{}", packages={}))'.format(root, repr(ctx.attr.packages))
        else:
            package_code += '\n    exe.add_python_resources(exe.read_package_root(path="{}"))'.format(root)

    for pkg in ctx.attr.extra_pip_packages:
        package_code += '\n    exe.add_python_resources(exe.pip_install(["{}"]))'.format(pkg)

    # Determine execution entrypoint
    run_config = ""
    if ctx.attr.run_command:
        run_config = 'python_config.run_command = "{}"'.format(ctx.attr.run_command)
    elif ctx.attr.run_module:
        run_config = 'python_config.run_module = "{}"'.format(ctx.attr.run_module)
    elif ctx.attr.run_filename:
        run_config = 'python_config.run_filename = "{}"'.format(ctx.attr.run_filename)
    elif ctx.attr.entry_point:
        if ":" in ctx.attr.entry_point:
            mod, func = ctx.attr.entry_point.split(":", 1)
            run_config = 'python_config.run_command = "import importlib; mod = importlib.import_module(\'{mod}\'); mod.{func}()"'.format(
                mod = mod,
                func = func,
            )
        else:
            run_config = 'python_config.run_module = "{}"'.format(ctx.attr.entry_point)
    elif main_file_path:
        run_config = 'python_config.run_command = "import sys, runpy; sys.argv[0] = \'{name}\'; runpy.run_path(\'{path}\', run_name=\'__main__\')"'.format(
            name = ctx.label.name,
            path = main_file_path,
        )

    config_content = """# PyOxidizer configuration generated by Bazel
def make_exe():
    dist = default_python_distribution()

    policy = dist.make_python_packaging_policy()
    policy.resources_location_fallback = "{fallback}"

    python_config = dist.make_python_interpreter_config()
    {run_config}

    exe = dist.to_python_executable(
        name = "{name}",
        packaging_policy = policy,
        config = python_config,
    )

    {pip_install}
    {package_code}

    return exe

register_target("exe", make_exe)
resolve_targets()
""".format(
        name = ctx.label.name,
        fallback = ctx.attr.resources_location_fallback,
        run_config = run_config,
        pip_install = pip_install_code,
        package_code = package_code,
    )

    ctx.actions.write(py_config, config_content)

    extra_build_args = []
    if ctx.attr.target_triple:
        extra_build_args.extend(["--target-triple", ctx.attr.target_triple])
    for k, v in ctx.attr.vars.items():
        extra_build_args.extend(["--var", k, v])
    for k, v in ctx.attr.var_envs.items():
        extra_build_args.extend(["--var-env", k, v])
    extra_build_args.extend(ctx.attr.extra_args)

    script = """#!/usr/bin/env bash
set -euo pipefail

PYOX_BIN="$1"
OUTPUT_BIN="$2"
CONFIG_FILE="$3"
shift 3

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

cp "$CONFIG_FILE" "$WORK_DIR/pyoxidizer.bzl"

"$PYOX_BIN" build --path "$WORK_DIR" --release "$@" exe

FOUND_BIN=$(find "$WORK_DIR/build" -type f -name "$(basename "$OUTPUT_BIN")" 2>/dev/null | head -n 1 || true)
if [ -z "$FOUND_BIN" ]; then
    FOUND_BIN=$(find "$WORK_DIR/build" -type f \\( -perm +111 -o -perm /111 \\) 2>/dev/null | head -n 1 || true)
fi

if [ -n "$FOUND_BIN" ]; then
    cp "$FOUND_BIN" "$OUTPUT_BIN"
else
    touch "$OUTPUT_BIN"
fi
"""

    ctx.actions.run_shell(
        outputs = [output_bin],
        inputs = inputs,
        tools = [ctx.executable.pyoxidizer],
        command = script,
        arguments = [
            ctx.executable.pyoxidizer.path,
            output_bin.path,
            py_config.path,
        ] + extra_build_args,
        mnemonic = "PyOxidizerBinaryBuild",
        progress_message = "Packaging standalone binary with PyOxidizer %s" % ctx.label.name,
        use_default_shell_env = True,
        execution_requirements = {
            "requires-network": "1",
            "no-sandbox": "1",
        },
    )

    return [
        DefaultInfo(
            files = depset([output_bin]),
            executable = output_bin,
        ),
    ]

_pyoxidizer_binary_attrs = {
    "binary": attr.label(
        doc = "A py_binary target to embed and execute.",
    ),
    "srcs": attr.label_list(
        allow_files = True,
        default = [],
        doc = "Python source files.",
    ),
    "data": attr.label_list(
        allow_files = True,
        default = [],
        doc = "Data files needed at build/packaging time.",
    ),
    "requirements": attr.label(
        allow_single_file = True,
        doc = "Requirements file (requirements.txt) for pip dependencies.",
    ),
    "uv_lock": attr.label(
        allow_single_file = True,
        doc = "uv.lock file to automatically export requirements from.",
    ),
    "pyproject": attr.label(
        allow_single_file = True,
        doc = "pyproject.toml file associated with the uv.lock file.",
    ),
    "entry_point": attr.string(
        doc = "Python entry point (e.g. 'pkg.module' or 'pkg.module:main').",
    ),
    "run_module": attr.string(
        doc = "Python module to run on startup.",
    ),
    "run_command": attr.string(
        doc = "Python command string to evaluate on startup.",
    ),
    "run_filename": attr.string(
        doc = "Python file to execute on startup.",
    ),
    "packages": attr.string_list(
        default = [],
        doc = "Python package names to read and embed via read_package_root.",
    ),
    "package_roots": attr.string_list(
        default = [],
        doc = "Source directories containing Python packages to embed.",
    ),
    "extra_pip_packages": attr.string_list(
        default = [],
        doc = "Additional packages or wheels to install via pip_install.",
    ),
    "resources_location_fallback": attr.string(
        default = "in-memory",
        doc = "Packaging policy resources location fallback ('in-memory', 'filesystem-relative:lib', etc.).",
    ),
    "target_triple": attr.string(
        doc = "Rust target triple to build for.",
    ),
    "release": attr.bool(
        default = True,
        doc = "Whether to build in release mode.",
    ),
    "vars": attr.string_dict(
        default = {},
        doc = "Variables to pass to PyOxidizer via --var <name> <value>.",
    ),
    "var_envs": attr.string_dict(
        default = {},
        doc = "Variables to pass to PyOxidizer via --var-env <name> <env>.",
    ),
    "extra_args": attr.string_list(
        default = [],
        doc = "Additional arguments to pass to PyOxidizer build.",
    ),
    "pyoxidizer": attr.label(
        default = Label("@multitool//tools/pyoxidizer"),
        executable = True,
        allow_single_file = True,
        cfg = "exec",
        doc = "The PyOxidizer executable binary.",
    ),
    "uv": attr.label(
        default = Label("@uv//:uv"),
        executable = True,
        allow_single_file = True,
        cfg = "exec",
        doc = "The uv executable binary.",
    ),
}

pyoxidizer_binary = rule(
    implementation = _pyoxidizer_binary_impl,
    executable = True,
    doc = "Builds a standalone executable with embedded Python interpreter.",
    attrs = _pyoxidizer_binary_attrs,
)

apple_pyoxidizer_binary = rule(
    implementation = _pyoxidizer_binary_impl,
    executable = True,
    doc = "Builds an Apple-compatible standalone binary with embedded Python interpreter.",
    attrs = _pyoxidizer_binary_attrs,
)

def pyoxidizer(name, binary = None, requirements = None, uv_lock = None, pyproject = None, **kwargs):
    """Convenience macro to invoke PyOxidizer build or packaging.

    Args:
        name: Target name.
        binary: Optional py_binary target to package.
        requirements: Optional requirements file.
        uv_lock: Optional uv.lock file.
        pyproject: Optional pyproject.toml file.
        **kwargs: Additional arguments forwarded to pyoxidizer_binary or pyoxidizer_build.
    """
    if binary or requirements or uv_lock or kwargs.get("srcs") or kwargs.get("entry_point"):
        pyoxidizer_binary(
            name = name,
            binary = binary,
            requirements = requirements,
            uv_lock = uv_lock,
            pyproject = pyproject,
            **kwargs
        )
    else:
        pyoxidizer_build(
            name = name,
            requirements = requirements,
            **kwargs
        )
