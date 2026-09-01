"""Create a zip file containing a full Python application.

Follows [PEP-441 (PEX)](https://peps.python.org/pep-0441/)

## Ensuring a compatible interpreter is used

The resulting zip file does *not* contain a Python interpreter.
Users are expected to execute the PEX with a compatible interpreter on the runtime system.

Use the `python_interpreter_constraints` to provide an error if a wrong interpreter tries to execute the PEX, for example:

```starlark
py_pex_binary(
    python_interpreter_constraints = [
        "CPython=={major}.{minor}.{patch}",
    ]
)
```
"""

load("@aspect_rules_py//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("@aspect_rules_py//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")
load("@aspect_rules_py//py:defs.bzl", _py_pex_binary = "py_pex_binary")
load("@bazel_lib//lib:paths.bzl", "to_rlocation_path")
load("@rules_python//python:defs.bzl", "PyInfo")

py_pex_binary = _py_pex_binary

def _runfiles_path(file, workspace):
    if file.short_path.startswith("../"):
        return file.short_path[3:]
    else:
        return workspace + "/" + file.short_path

exclude_paths = [
    # following two lines will match paths we want to exclude in non-bzlmod setup
    "toolchain",
    "aspect_rules_py/py/tools/",
    # these will match in bzlmod setup
    "rules_python~~python~",
    "aspect_rules_py~/py/tools/",
    # these will match in bzlmod setup with --incompatible_use_plus_in_repo_names flag flipped.
    "rules_python++python+",
    "aspect_rules_py+/py/tools/",
    ".venv/",
]

def _map_srcs(f, workspace):
    dest_path = _runfiles_path(f, workspace)

    for exclude in exclude_paths:
        if dest_path.find(exclude) != -1:
            return []

    site_packages_i = f.path.find("site-packages")

    if site_packages_i != -1:
        if f.path.find("dist-info", site_packages_i) != -1 and f.path.count("/", site_packages_i) == 2:
            return ["--distinfo={}".format(f.dirname)]
        return ["--dep={}".format(f.path[:site_packages_i + len("site-packages")])]

    return ["--source={}={}".format(f.path, dest_path)]

def _py_python_scie_impl(ctx):
    py_toolchain = _py_semantics.resolve_toolchain(ctx)

    binary = ctx.attr.binary
    binary_default = binary[DefaultInfo]

    output = ctx.actions.declare_file(ctx.attr.name)

    # Check if target is already a PEX file or a py_binary
    is_pex = False
    files_list = binary_default.files.to_list()
    if PyInfo not in binary:
        is_pex = True
    elif len(files_list) == 1 and files_list[0].extension == "pex":
        is_pex = True

    py_version = py_toolchain.interpreter_version_info
    default_py_version = "{}.{}".format(py_version.major, py_version.minor)
    scie_python_version = ctx.attr.scie_python_version if ctx.attr.scie_python_version != "" else default_py_version

    if is_pex:
        pex_file = binary_default.files_to_run.executable if binary_default.files_to_run and binary_default.files_to_run.executable else files_list[0]
    else:
        pex_file = ctx.actions.declare_file(ctx.attr.name + ".intermediate.pex")
        runfiles = binary_default.data_runfiles
        entrypoint_files = [f for f in files_list if f != binary_default.files_to_run.executable]
        if len(entrypoint_files) != 1:
            fail("py_scie_binary {}: expected exactly one entrypoint file in `binary` DefaultInfo.files, got {}".format(ctx.label, entrypoint_files))
        entrypoint = entrypoint_files[0]

        pex_args = ctx.actions.args()
        pex_args.use_param_file(param_file_arg = "@%s")
        pex_args.set_param_file_format("multiline")

        workspace_name = str(ctx.workspace_name)
        pex_args.add_all(
            ctx.attr.inject_env.items(),
            map_each = lambda e: "--inject-env={}={}".format(e[0], e[1]),
            allow_closure = True,
        )
        pex_args.add_all(
            binary[PyInfo].imports,
            format_each = "--sys-path=%s",
        )
        pex_args.add_all(
            runfiles.files,
            map_each = lambda f: _map_srcs(f, workspace_name),
            uniquify = True,
            allow_closure = True,
        )
        pex_args.add(to_rlocation_path(ctx, entrypoint), format = "--entrypoint=%s")
        pex_args.add(ctx.attr.python_shebang, format = "--python-shebang=%s")

        if ctx.attr.inherit_path != "":
            pex_args.add(ctx.attr.inherit_path, format = "--inherit-path=%s")

        pex_args.add_all(
            [
                constraint.format(major = py_version.major, minor = py_version.minor, patch = py_version.micro)
                for constraint in ctx.attr.python_interpreter_constraints
            ],
            format_each = "--python-version-constraint=%s",
        )
        pex_args.add(pex_file, format = "--output-file=%s")

        ctx.actions.run(
            executable = ctx.executable._pex_tool,
            toolchain = None,
            inputs = runfiles.files,
            arguments = [pex_args],
            outputs = [pex_file],
            mnemonic = "PyPex",
            progress_message = "Building intermediate PEX binary %{label}",
        )

    scie_args = ctx.actions.args()
    scie_args.use_param_file(param_file_arg = "@%s")
    scie_args.set_param_file_format("multiline")
    scie_args.add(output, format = "--output=%s")
    scie_args.add(pex_file, format = "--pex-file=%s")

    if ctx.attr.scie != "":
        scie_args.add(ctx.attr.scie, format = "--scie=%s")

    scie_args.add(scie_python_version, format = "--scie-python-version=%s")

    if ctx.attr.scie_pbs_release != "":
        scie_args.add(ctx.attr.scie_pbs_release, format = "--scie-pbs-release=%s")

    scie_args.add_all(ctx.attr.scie_platform, format_each = "--scie-platform=%s")

    scie_args.add_all(
        ctx.attr.inject_env.items(),
        map_each = lambda e: "--inject-env={}={}".format(e[0], e[1]),
        allow_closure = True,
    )

    scie_args.add_all(
        ctx.attr.scie_env.items(),
        map_each = lambda e: "--scie-env={}={}".format(e[0], e[1]),
        allow_closure = True,
    )

    ctx.actions.run(
        executable = ctx.executable._scie_tool,
        toolchain = None,
        inputs = [pex_file],
        arguments = [scie_args],
        outputs = [output],
        mnemonic = "PyScie",
        progress_message = "Building SCIE binary %{label}",
        use_default_shell_env = True,
        execution_requirements = {
            "requires-network": "1",
            "no-sandbox": "1",
        },
    )

    return [
        DefaultInfo(files = depset([output]), executable = output),
    ]

_attrs = dict({
    "binary": attr.label(executable = True, cfg = "target", mandatory = True, doc = "A py_binary target"),
    "inject_env": attr.string_dict(
        doc = "Environment variables to set when running the pex binary.",
        default = {},
    ),
    "scie": attr.string(
        doc = """\
Create one or more native executable scies from your PEX that include a portable CPython
interpreter along with your PEX making for a truly hermetic PEX that can run on machines with
no Python installed at all. If your PEX has multiple targets, whether `--platform`s,
`--complete-platform`s or local interpreters in any combination, then one PEX scie will be
made for each platform, selecting the latest compatible portable CPython or PyPy interpreter
as appropriate. Note that only Python>=3.8 is supported. If you'd like to explicitly control
the target platforms or the exact portable CPython selected, see `--scie-platform`, `--scie-
pbs-release` and `--scie-python-version`. Specifying `--scie lazy` will fetch the portable
CPython interpreter just in time on first boot of the PEX scie on a given machine if needed.
The URL(s) to fetch the portable CPython interpreter from can be customized by exporting the
PEX_BOOTSTRAP_URLS environment variable pointing to a json file with the format: `{"ptex":
{<file name 1>: <url>, ...}}` where the file names should match those found via `SCIE=inspect
<the PEX scie> | jq .ptex` with appropriate replacement URLs. Specifying `--scie eager` will
embed the portable CPython interpreter in your PEX scie making for a larger file, but
requiring no internet access to boot. If you have customization needs not addressed by the Pex
`--scie*` options, consider using `science` to build your scies (which is what Pex uses behind
the scenes); see: https://science.scie.app. (default: None)
        """,
        values = ["eager", "lazy", "none"],
        default = "none",
    ),
    "scie_only": attr.string(
        doc = "Whether to output only the PEX scie(s) and not the original PEX file.",
        values = ["", "true", "false", "scie-only", "no-scie-only", "pex_and_scie", "pex-and-scie"],
        default = "",
    ),
    "scie_platform": attr.string_list(
        doc = "The platform(s) to build scie(s) for.",
        default = [],
    ),
    "scie_pbs_release": attr.string(
        doc = "The Python Build Standalone release to use.",
        default = "",
    ),
    "scie_python_version": attr.string(
        doc = "The Python version to use for the portable CPython interpreter.",
        default = "",
    ),
    "scie_pypy_release": attr.string(
        doc = "The PyPy release to use.",
        default = "",
    ),
    "scie_pbs_free_threaded": attr.bool(
        doc = "Whether to use a free-threaded Python Build Standalone release.",
        default = False,
    ),
    "scie_pbs_debug": attr.bool(
        doc = "Whether to use a debug Python Build Standalone release.",
        default = False,
    ),
    "scie_pbs_stripped": attr.bool(
        doc = "Whether to use a stripped Python Build Standalone release.",
        default = False,
    ),
    "scie_name_style": attr.string(
        doc = "Naming style for the generated scie.",
        default = "",
    ),
    "scie_hash_alg": attr.string_list(
        doc = "Hash algorithms to generate checksum files for.",
        default = [],
    ),
    "scie_science_binary": attr.string(
        doc = "The science binary path or URL.",
        default = "",
    ),
    "scie_assets_base_url": attr.string(
        doc = "Base URL to fetch scie assets from.",
        default = "",
    ),
    "scie_base": attr.string(
        doc = "The SCIE_BASE directory.",
        default = "",
    ),
    "scie_load_dotenv": attr.bool(
        doc = "Whether the scie should load .env.",
        default = False,
    ),
    "scie_busybox": attr.string_list(
        doc = "Busybox applets for scie.",
        default = [],
    ),
    "scie_exe": attr.string_list(
        doc = "Additional named executables for scie.",
        default = [],
    ),
    "scie_args": attr.string_list(
        doc = "Default arguments for scie executable.",
        default = [],
    ),
    "scie_env": attr.string_dict(
        doc = "Environment variables for scie.",
        default = {},
    ),
    "scie_pex_entrypoint_env_passthrough": attr.string_list(
        doc = "Environment variable names to pass through to PEX entrypoint.",
        default = [],
    ),
    "scie_bind_resource_path": attr.string_list(
        doc = "Resource paths to bind in scie.",
        default = [],
    ),
    "scie_desktop_file": attr.string(
        doc = "Desktop file for scie desktop integration.",
        default = "",
    ),
    "scie_icon": attr.string(
        doc = "Icon file for scie desktop integration.",
        default = "",
    ),
    "scie_prompt_desktop_install": attr.bool(
        doc = "Prompt to install desktop file on startup.",
        default = False,
    ),
    "scie_windowed": attr.bool(
        doc = "Run without terminal window on GUI systems.",
        default = False,
    ),
    "platforms": attr.string_list(
        doc = "Target platform(s) for the PEX.",
        default = [],
    ),
    "complete_platforms": attr.string_list(
        doc = "Complete platform JSON files or strings.",
        default = [],
    ),
    "layout": attr.string(
        doc = "Layout of the generated PEX.",
        values = ["", "zipapp", "packed", "loose"],
        default = "",
    ),
    "strip_pex_env": attr.string(
        doc = "Whether to strip PEX_* env vars before exec.",
        values = ["", "true", "false"],
        default = "",
    ),
    "sh_boot": attr.bool(
        doc = "Generate a Bourne shell (sh) boot script instead of a Python script.",
        default = False,
    ),
    "validate_entry_point": attr.bool(
        doc = "Validate the entry point is importable.",
        default = False,
    ),
    "include_tools": attr.bool(
        doc = "Whether to include PEX tools.",
        default = False,
    ),
    "compress": attr.string(
        doc = "Whether to compress files in the PEX.",
        values = ["", "true", "false"],
        default = "",
    ),
    "zip_safe": attr.string(
        doc = "Whether the PEX is zip-safe.",
        values = ["", "true", "false", "not-zip-safe"],
        default = "",
    ),
    "inject_args": attr.string_list(
        doc = "Arguments to inject into argv.",
        default = [],
    ),
    "inject_python_args": attr.string_list(
        doc = "Python interpreter arguments to inject.",
        default = [],
    ),
    "bind_resource_path": attr.string_list(
        doc = "Paths to bind into PEX_EXTRA_SYS_PATH or resource mapping.",
        default = [],
    ),
    "ignore_errors": attr.bool(
        doc = "Ignore errors when resolving.",
        default = False,
    ),
    "emit_warnings": attr.string(
        doc = "Whether to emit warnings.",
        values = ["", "true", "false"],
        default = "",
    ),
    "pex_root": attr.string(
        doc = "Specify the PEX root directory during build.",
        default = "",
    ),
    "runtime_pex_root": attr.string(
        doc = "Specify the runtime PEX root directory.",
        default = "",
    ),
    "pex_path": attr.string_list(
        doc = "Other PEX files to merge into sys.path.",
        default = [],
    ),
    "build_properties": attr.string_dict(
        doc = "Build properties to inject into PEX-INFO.",
        default = {},
    ),
    "venv": attr.string(
        doc = "Convert the PEX into a venv.",
        values = ["", "true", "false", "prepend", "append"],
        default = "",
    ),
    "venv_copies": attr.bool(
        doc = "Create venv with copies instead of symlinks.",
        default = False,
    ),
    "venv_site_packages_copies": attr.bool(
        doc = "Create venv site-packages with copies.",
        default = False,
    ),
    "venv_system_site_packages": attr.bool(
        doc = "Give the venv access to the system site-packages dir.",
        default = False,
    ),
    "pexrc_platform": attr.string(
        doc = "Platform for pexrc launcher.",
        default = "",
    ),
    "compression_method": attr.string(
        doc = "Compression method to use.",
        values = ["", "deflated", "zstd"],
        default = "",
    ),
    "compression_level": attr.int(
        doc = "Compression level (0-9 for deflated, 1-22 for zstd).",
        default = -1,
    ),
    "resolve_local_platforms": attr.bool(
        doc = "Resolve local platforms.",
        default = False,
    ),
    "inherit_path": attr.string(
        doc = """\
Whether to inherit the `sys.path` (aka PYTHONPATH) of the environment that the binary runs in.

Use `false` to not inherit `sys.path`; use `fallback` to inherit `sys.path` after packaged
dependencies; and use `prefer` to inherit `sys.path` before packaged dependencies.
""",
        values = ["false", "fallback", "prefer"],
    ),
    "python_shebang": attr.string(default = "#!/usr/bin/env python3"),
    "python_interpreter_constraints": attr.string_list(
        default = ["CPython=={major}.{minor}.*"],
        doc = """\
Python interpreter versions this PEX binary is compatible with. A list of semver strings.
The placeholder strings `{major}`, `{minor}`, `{patch}` can be used for gathering version
information from the hermetic python toolchain.
""",
    ),
    "interpreter_constraints": attr.string_list(
        default = [],
        doc = """\
Python interpreter constraints to pass directly to pex.
The placeholder strings `{major}`, `{minor}`, `{patch}` can be used for gathering version
information from the hermetic python toolchain.
""",
    ),
    "_scie_tool": attr.label(executable = True, cfg = "exec", default = "//tools/pex:scie_tool"),
    "_pex_tool": attr.label(executable = True, cfg = "exec", default = "@aspect_rules_py//py/tools/pex:pex"),
    "_pex": attr.label(executable = True, cfg = "exec", default = "//tools/pex:pex"),
})

py_scie_binary = rule(
    doc = "Build a pex executable from a py_binary",
    implementation = _py_python_scie_impl,
    attrs = _attrs,
    toolchains = [
        "@rules_python//python:toolchain_type",
    ],
    executable = True,
)
