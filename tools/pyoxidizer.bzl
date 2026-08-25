load("@rules_rs//rs:extensions.bzl", "crate")

def _apple_pyoxidizer_binary_impl(ctx):
    output_bin = ctx.actions.declare_file(ctx.label.name)
    py_config = ctx.actions.declare_file(ctx.label.name + "_pyoxidizer.bcl")

    # 1. Generate the PyOxidizer configuration file dynamically
    config_content = """
def make_exe():
    config = PythonExecutableConfig()
    config.name = "{name}"
    config.display_name = "{name}"

    # Force embedding bytecode inside the binary for optimal Apple distribution
    packaging_policy = PythonPackagingPolicy()
    packaging_policy.set_resources_location_fallback("in-memory")

    manifest = dist.to_python_executable(
        name="{name}",
        packaging_policy=packaging_policy,
        config=config,
    )

    # Add your source files or pip dependencies
    manifest.add_python_resources(dist.pip_install(["-r", "{pip_reqs}"]))

    return manifest

register_target("exe", make_exe)
resolve_targets()
""".format(
        name = ctx.label.name,
        pip_reqs = ctx.file.requirements.path,
    )

    ctx.actions.write(py_config, config_content)

    # 2. Invoke the pyoxidizer build tool to build the Apple executable
    ctx.actions.run(
        outputs = [output_bin],
        inputs = [ctx.file.requirements] + ctx.files.srcs + [py_config],
        executable = "pyoxidizer",
        arguments = ["build", "--config", py_config.path, "--target", "exe"],
        mnemonic = "PyOxidizerBuild",
        progress_message = "Embedding Python interpreter into native Apple binary %s" % ctx.label.name,
    )

    return [DefaultInfo(files = depset([output_bin]))]

apple_pyoxidizer_binary = rule(
    implementation = _apple_pyoxidizer_binary_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".py"], mandatory = True),
        "requirements": attr.label(allow_single_file = True, mandatory = True),
    },
)
