"""Rules for creating macOS installer packages (.pkg) with pkgbuild and installing them."""

MacosPkgInfo = provider(
    doc = "Information about a macOS installer package (.pkg).",
    fields = {
        "identifier": "The package identifier.",
        "install_location": "The default installation target directory.",
        "pkg": "The .pkg installer File.",
        "signing_identity": "The signing identity Common Name, if signed.",
        "version": "The package version.",
    },
)

PkgInfo = MacosPkgInfo

def _pkgbuild_impl(ctx):
    if not ctx.target_platform_has_constraint(ctx.attr._macos_constraint[platform_common.ConstraintValueInfo]):
        fail("{} only supports macOS targets".format(ctx.label))

    if not ctx.attr.app and not ctx.attr.root:
        fail("{}: Either 'app' or 'root' must be specified".format(ctx.label))

    pkg_output = ctx.outputs.out if ctx.outputs.out else ctx.actions.declare_file(ctx.label.name + ".pkg")

    inputs = []
    app_path = ""
    root_path = ""

    if ctx.attr.app:
        app_files = ctx.attr.app[DefaultInfo].files.to_list()
        inputs.extend(app_files)
        for f in app_files:
            if f.path.endswith(".zip"):
                app_path = f.path
                break
            elif ".app" in f.path:
                app_path = f.path
                break
        if not app_path and app_files:
            app_path = app_files[0].path

    if ctx.attr.root:
        root_files = ctx.attr.root[DefaultInfo].files.to_list()
        inputs.extend(root_files)
        if root_files:
            root_path = root_files[0].path

    scripts_path = ""
    if ctx.attr.scripts:
        script_files = ctx.files.scripts
        inputs.extend(script_files)
        if script_files:
            scripts_path = script_files[0].dirname

    component_plist_path = ""
    if ctx.file.component_plist:
        inputs.append(ctx.file.component_plist)
        component_plist_path = ctx.file.component_plist.path

    cert_paths = []
    if ctx.files.certs:
        inputs.extend(ctx.files.certs)
        for c in ctx.files.certs:
            cert_paths.append(c.path)

    signing_identity = ctx.attr.signing_identity if ctx.attr.signing_identity else ctx.attr.sign
    identifier = ctx.attr.identifier if ctx.attr.identifier else ctx.attr.package_id

    args = ctx.actions.args()
    args.add(pkg_output.path)
    args.add(ctx.attr.install_location)
    args.add(identifier)
    args.add(ctx.attr.version)
    args.add(signing_identity)
    args.add("true" if ctx.attr.timestamp else "false")
    args.add(ctx.attr.keychain)
    args.add(scripts_path)
    args.add(component_plist_path)
    args.add(ctx.attr.ownership)
    args.add(ctx.attr.min_os_version)
    args.add(ctx.attr.compression)
    args.add("true" if ctx.attr.large_payload else "false")
    args.add(app_path)
    args.add(root_path)
    args.add_all(cert_paths)

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [pkg_output],
        arguments = [args],
        command = """
set -euo pipefail

output_pkg="$1"
install_location="$2"
identifier="$3"
version="$4"
signing_identity="$5"
timestamp="$6"
keychain="$7"
scripts_dir="$8"
component_plist="$9"
ownership="${10}"
min_os_version="${11}"
compression="${12}"
large_payload="${13}"
app_input="${14}"
root_input="${15}"
shift 15
certs=("$@")

# Strip outer quotes from signing_identity if present
signing_identity="${signing_identity#\\\"}"
signing_identity="${signing_identity%\\\"}"

staging_dir=""
cleanup() {
    if [ -n "$staging_dir" ] && [ -d "$staging_dir" ]; then
        rm -rf "$staging_dir"
    fi
}
trap cleanup EXIT

app_bundle=""
root_dir=""

if [ -n "$app_input" ]; then
    if [[ "$app_input" == *.zip ]]; then
        staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/pkgbuild_staging.XXXXXX")"
        /usr/bin/unzip -q "$app_input" -d "$staging_dir"
        app_bundle="$(find "$staging_dir" -maxdepth 3 -name "*.app" -type d | head -n 1)"
        if [ -z "$app_bundle" ]; then
            echo "Error: No .app bundle found inside $app_input" >&2
            exit 1
        fi
    elif [[ "$app_input" == *.app ]] || [[ "$app_input" == *".app/"* ]]; then
        cur="$app_input"
        while [ "$cur" != "/" ] && [ "$cur" != "." ]; do
            if [[ "$cur" == *.app ]]; then
                app_bundle="$cur"
                break
            fi
            cur="$(dirname "$cur")"
        done
        if [ -z "$app_bundle" ]; then
            app_bundle="$app_input"
        fi
    else
        app_bundle="$app_input"
    fi
elif [ -n "$root_input" ]; then
    if [ -d "$root_input" ]; then
        root_dir="$root_input"
    else
        root_dir="$(dirname "$root_input")"
    fi
fi

cmd=(/usr/bin/pkgbuild)

if [ -n "$app_bundle" ]; then
    cmd+=(--component "$app_bundle")
elif [ -n "$root_dir" ]; then
    cmd+=(--root "$root_dir")
else
    echo "Error: Neither app bundle nor root directory resolved" >&2
    exit 1
fi

if [ -n "$install_location" ]; then
    cmd+=(--install-location "$install_location")
fi

if [ -n "$identifier" ]; then
    cmd+=(--identifier "$identifier")
fi

if [ -n "$version" ]; then
    cmd+=(--version "$version")
fi

if [ -n "$signing_identity" ]; then
    cmd+=(--sign "$signing_identity")
    if [ "$timestamp" = "false" ]; then
        cmd+=(--timestamp=none)
    elif [ "$timestamp" = "true" ]; then
        cmd+=(--timestamp)
    fi
fi

if [ -n "$keychain" ]; then
    cmd+=(--keychain "$keychain")
fi

if [ -n "$scripts_dir" ] && [ -d "$scripts_dir" ]; then
    chmod -R +x "$scripts_dir" 2>/dev/null || true
    cmd+=(--scripts "$scripts_dir")
fi

if [ -n "$component_plist" ] && [ -f "$component_plist" ]; then
    cmd+=(--component-plist "$component_plist")
fi

if [ -n "$ownership" ]; then
    cmd+=(--ownership "$ownership")
fi

if [ -n "$min_os_version" ]; then
    cmd+=(--min-os-version "$min_os_version")
fi

if [ -n "$compression" ]; then
    cmd+=(--compression "$compression")
fi

if [ "$large_payload" = "true" ]; then
    cmd+=(--large-payload)
fi

for cert in "${certs[@]+"${certs[@]}"}"; do
    if [ -n "$cert" ]; then
        cmd+=(--cert "$cert")
    fi
done

mkdir -p "$(dirname "$output_pkg")"
cmd+=("$output_pkg")

"${cmd[@]}"
""",
        mnemonic = "PkgBuild",
        progress_message = "Building macOS installer package for {}".format(ctx.label),
    )

    runner = ctx.actions.declare_file(ctx.label.name + "_install.sh")
    pkg_rlocation = ctx.workspace_name + "/" + pkg_output.short_path

    runner_content = """#!/bin/bash
set -euo pipefail

PKG_FILE=""
if [ -n "${{RUNFILES_DIR:-}}" ] && [ -f "${{RUNFILES_DIR}}/{pkg_rlocation}" ]; then
    PKG_FILE="${{RUNFILES_DIR}}/{pkg_rlocation}"
elif [ -n "${{RUNFILES_MANIFEST_FILE:-}}" ]; then
    PKG_FILE="$(grep -m 1 "^{pkg_rlocation} " "${{RUNFILES_MANIFEST_FILE}}" 2>/dev/null | cut -d' ' -f2- || true)"
fi

if [ -z "$PKG_FILE" ] || [ ! -f "$PKG_FILE" ]; then
    if [ -f "${{0}}.runfiles/{pkg_rlocation}" ]; then
        PKG_FILE="${{0}}.runfiles/{pkg_rlocation}"
    elif [ -f "{pkg_short_path}" ]; then
        PKG_FILE="{pkg_short_path}"
    fi
fi

if [ -z "$PKG_FILE" ] || [ ! -f "$PKG_FILE" ]; then
    echo "Error: Could not locate installer package file ({pkg_short_path})" >&2
    exit 1
fi

TARGET="/"
echo "==> Installing ${{PKG_FILE}} to ${{TARGET}} via macOS installer..."
if [ "$(id -u)" -ne 0 ]; then
    echo "==> Elevating privileges with sudo..."
    exec sudo /usr/sbin/installer -pkg "${{PKG_FILE}}" -target "${{TARGET}}"
else
    exec /usr/sbin/installer -pkg "${{PKG_FILE}}" -target "${{TARGET}}"
fi
""".format(
        pkg_rlocation = pkg_rlocation,
        pkg_short_path = pkg_output.short_path,
    )

    ctx.actions.write(
        output = runner,
        content = runner_content,
        is_executable = True,
    )

    return [
        DefaultInfo(
            files = depset([pkg_output]),
            executable = runner,
            runfiles = ctx.runfiles(files = [pkg_output]),
        ),
        MacosPkgInfo(
            identifier = identifier,
            install_location = ctx.attr.install_location,
            pkg = pkg_output,
            signing_identity = signing_identity,
            version = ctx.attr.version,
        ),
    ]

pkgbuild = rule(
    implementation = _pkgbuild_impl,
    executable = True,
    doc = "Builds a macOS installer package (.pkg) via pkgbuild.",
    attrs = {
        "app": attr.label(
            doc = "Target providing a macOS application (.app or .zip).",
        ),
        "certs": attr.label_list(
            allow_files = True,
            doc = "Intermediate certificates to embed.",
        ),
        "component_plist": attr.label(
            allow_single_file = True,
            doc = "Component property list file.",
        ),
        "compression": attr.string(
            values = ["", "legacy", "latest"],
            doc = "Compression format.",
        ),
        "identifier": attr.string(
            doc = "Package identifier (e.g. me.rickmark.garage.pkg).",
        ),
        "install_location": attr.string(
            default = "/Applications",
            doc = "Default install location for the package (defaults to /Applications).",
        ),
        "keychain": attr.string(
            doc = "Path to keychain containing the signing identity.",
        ),
        "large_payload": attr.bool(
            default = False,
            doc = "Enable large payload support (>8GiB).",
        ),
        "min_os_version": attr.string(
            doc = "Minimum macOS version supported.",
        ),
        "out": attr.output(
            doc = "Output .pkg file name.",
        ),
        "ownership": attr.string(
            default = "recommended",
            values = ["", "recommended", "preserve", "preserve-other"],
            doc = "Ownership handling mode.",
        ),
        "package_id": attr.string(
            doc = "Alias for identifier.",
        ),
        "root": attr.label(
            doc = "Target providing a directory tree for destination root.",
        ),
        "scripts": attr.label(
            allow_files = True,
            doc = "Directory or files containing preinstall/postinstall scripts.",
        ),
        "sign": attr.string(
            doc = "Alias for signing_identity.",
        ),
        "signing_identity": attr.string(
            doc = "Signing identity Common Name for digital signature.",
        ),
        "timestamp": attr.bool(
            default = True,
            doc = "Whether to include a trusted timestamp.",
        ),
        "version": attr.string(
            doc = "Package version string.",
        ),
        "_macos_constraint": attr.label(
            default = Label("@platforms//os:macos"),
        ),
    },
)

macos_pkg = pkgbuild

def _pkg_install_impl(ctx):
    if not ctx.target_platform_has_constraint(ctx.attr._macos_constraint[platform_common.ConstraintValueInfo]):
        fail("{} only supports macOS targets".format(ctx.label))

    pkg_files = ctx.attr.pkg[DefaultInfo].files.to_list()
    if not pkg_files:
        fail("{}: 'pkg' target did not produce any files".format(ctx.label))
    pkg_file = pkg_files[0]

    runner = ctx.actions.declare_file(ctx.label.name + "_runner.sh")
    pkg_rlocation = ctx.workspace_name + "/" + pkg_file.short_path

    runner_content = """#!/bin/bash
set -euo pipefail

PKG_FILE=""
if [ -n "${{RUNFILES_DIR:-}}" ] && [ -f "${{RUNFILES_DIR}}/{pkg_rlocation}" ]; then
    PKG_FILE="${{RUNFILES_DIR}}/{pkg_rlocation}"
elif [ -n "${{RUNFILES_MANIFEST_FILE:-}}" ]; then
    PKG_FILE="$(grep -m 1 "^{pkg_rlocation} " "${{RUNFILES_MANIFEST_FILE}}" 2>/dev/null | cut -d' ' -f2- || true)"
fi

if [ -z "$PKG_FILE" ] || [ ! -f "$PKG_FILE" ]; then
    if [ -f "${{0}}.runfiles/{pkg_rlocation}" ]; then
        PKG_FILE="${{0}}.runfiles/{pkg_rlocation}"
    elif [ -f "{pkg_short_path}" ]; then
        PKG_FILE="{pkg_short_path}"
    fi
fi

if [ -z "$PKG_FILE" ] || [ ! -f "$PKG_FILE" ]; then
    echo "Error: Could not locate installer package file ({pkg_short_path})" >&2
    exit 1
fi

TARGET="{target}"
echo "==> Installing ${{PKG_FILE}} to ${{TARGET}} via macOS installer..."
if [ "{use_sudo}" = "true" ] && [ "$(id -u)" -ne 0 ]; then
    echo "==> Elevating privileges with sudo..."
    exec sudo /usr/sbin/installer -pkg "${{PKG_FILE}}" -target "${{TARGET}}"
else
    exec /usr/sbin/installer -pkg "${{PKG_FILE}}" -target "${{TARGET}}"
fi
""".format(
        pkg_rlocation = pkg_rlocation,
        pkg_short_path = pkg_file.short_path,
        target = ctx.attr.target,
        use_sudo = "true" if ctx.attr.use_sudo else "false",
    )

    ctx.actions.write(
        output = runner,
        content = runner_content,
        is_executable = True,
    )

    return [
        DefaultInfo(
            files = depset([pkg_file]),
            executable = runner,
            runfiles = ctx.runfiles(files = [pkg_file]),
        ),
    ]

pkg_install = rule(
    implementation = _pkg_install_impl,
    executable = True,
    doc = "Installs a macOS installer package (.pkg) to a target volume using installer.",
    attrs = {
        "pkg": attr.label(
            mandatory = True,
            doc = "The .pkg target to install.",
        ),
        "target": attr.string(
            default = "/",
            doc = "Target volume for installation (defaults to /).",
        ),
        "use_sudo": attr.bool(
            default = True,
            doc = "Whether to use sudo for installation if not running as root.",
        ),
        "_macos_constraint": attr.label(
            default = Label("@platforms//os:macos"),
        ),
    },
)
