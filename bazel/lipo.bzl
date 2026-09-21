"""Rules for extracting single-architecture (thinned) macOS applications via lipo and codesigning."""

def _macos_lipo_app_impl(ctx):
    if not ctx.target_platform_has_constraint(ctx.attr._macos_constraint[platform_common.ConstraintValueInfo]):
        fail("{} only supports macOS targets".format(ctx.label))

    app_target = ctx.attr.app
    app_files = app_target[DefaultInfo].files.to_list()
    if not app_files:
        fail("{}: 'app' target did not produce any files".format(ctx.label))

    app_input = None
    for f in app_files:
        if f.path.endswith(".zip") or ".app" in f.path:
            app_input = f
            break
    if not app_input:
        app_input = app_files[0]

    out_zip = ctx.outputs.out if ctx.outputs.out else ctx.actions.declare_file(ctx.label.name + ".zip")

    signing_identity = ctx.attr.signing_identity
    arch = ctx.attr.arch
    options = ",".join(ctx.attr.options)

    args = ctx.actions.args()
    args.add(app_input.path)
    args.add(out_zip.path)
    args.add(arch)
    args.add(signing_identity)
    args.add(options)

    ctx.actions.run_shell(
        inputs = [app_input],
        outputs = [out_zip],
        arguments = [args],
        command = """
set -euo pipefail

app_input="$1"
out_zip="$2"
target_arch="$3"
signing_identity="$4"
options="$5"

# Strip outer quotes from signing_identity if present
signing_identity="${signing_identity#\\\"}"
signing_identity="${signing_identity%\\\"}"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/macos_lipo_staging.XXXXXX")"
cleanup() {
    if [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ]; then
        rm -rf "$tmp_dir"
    fi
}
trap cleanup EXIT

staging_app_dir="$tmp_dir/app"
mkdir -p "$staging_app_dir"

if [[ "$app_input" == *.zip ]]; then
    /usr/bin/unzip -q "$app_input" -d "$staging_app_dir"
    app_bundle="$(find "$staging_app_dir" -maxdepth 3 -name "*.app" -type d | head -n 1)"
    if [ -z "$app_bundle" ]; then
        echo "Error: No .app bundle found inside $app_input" >&2
        exit 1
    fi
elif [[ "$app_input" == *.app ]] || [[ "$app_input" == *".app/"* ]]; then
    cur="$app_input"
    while [ "$cur" != "/" ] && [ "$cur" != "." ]; do
        if [[ "$cur" == *.app ]]; then
            app_bundle_src="$cur"
            break
        fi
        cur="$(dirname "$cur")"
    done
    app_bundle="$staging_app_dir/$(basename "$app_bundle_src")"
    /bin/cp -R "$app_bundle_src" "$app_bundle"
else
    echo "Error: Unknown app input type: $app_input" >&2
    exit 1
fi

/usr/bin/python3 - "$app_bundle" "$target_arch" "$signing_identity" "$options" << 'PYEOF'
import os
import shutil
import subprocess
import sys
import tempfile

app_bundle = sys.argv[1]
target_arch = sys.argv[2]
signing_identity = sys.argv[3]
options = sys.argv[4]

# 0. Clean unneeded directories from the staged app bundle before signing
for site_python_test in [
    os.path.join(app_bundle, "Contents/Resources/site-python/test"),
]:
    if os.path.exists(site_python_test):
        shutil.rmtree(site_python_test, ignore_errors=True)

frameworks_dir = os.path.join(app_bundle, "Contents/Frameworks")
if os.path.exists(frameworks_dir):
    for fw in os.listdir(frameworks_dir):
        if fw == "Python.framework" or fw.endswith(".framework"):
            versions_dir = os.path.join(frameworks_dir, fw, "Versions")
            if os.path.isdir(versions_dir):
                for ver in os.listdir(versions_dir):
                    lib_dir = os.path.join(versions_dir, ver, "lib")
                    if os.path.isdir(lib_dir) and not os.path.islink(lib_dir):
                        shutil.rmtree(lib_dir, ignore_errors=True)
                    elif os.path.islink(lib_dir):
                        try:
                            os.unlink(lib_dir)
                        except OSError:
                            pass
            fw_lib_dir = os.path.join(frameworks_dir, fw, "lib")
            if os.path.isdir(fw_lib_dir) and not os.path.islink(fw_lib_dir):
                shutil.rmtree(fw_lib_dir, ignore_errors=True)
            elif os.path.islink(fw_lib_dir):
                try:
                    os.unlink(fw_lib_dir)
                except OSError:
                    pass

MACHO_MAGICS = {
    b"\\xfe\\xed\\xfa\\xce", b"\\xce\\xfa\\xed\\xfe",
    b"\\xfe\\xed\\xfa\\xcf", b"\\xcf\\xfa\\xed\\xfe",
    b"\\xca\\xfe\\xba\\xbe", b"\\xbe\\xba\\xfe\\xca",
}

macho_files = []
for root, dirs, files in os.walk(app_bundle):
    for f in files:
        p = os.path.join(root, f)
        if os.path.islink(p):
            continue
        try:
            with open(p, "rb") as fp:
                hdr = fp.read(4)
                if hdr in MACHO_MAGICS:
                    macho_files.append(p)
        except Exception:
            pass

ent_dir = tempfile.mkdtemp()
entitlements = {}

# 1. Extract entitlements for all Mach-O binaries before thinning
for i, p in enumerate(macho_files):
    res = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", ":-", p], capture_output=True)
    if res.returncode == 0 and res.stdout.strip().startswith(b"<?xml"):
        ent_file = os.path.join(ent_dir, f"ent_{i}.plist")
        with open(ent_file, "wb") as f:
            f.write(res.stdout)
        entitlements[p] = ent_file

# 2. Thin all Mach-O binaries using lipo
for p in macho_files:
    info = subprocess.run(["/usr/bin/lipo", "-archs", p], capture_output=True, text=True).stdout.strip().split()
    if len(info) > 1 and target_arch in info:
        thin_p = p + ".thin"
        subprocess.run(["/usr/bin/lipo", "-thin", target_arch, p, "-output", thin_p], check=True)
        shutil.move(thin_p, p)

# 3. Codesign individual Mach-O binaries (deepest first)
opts_arg = [f"--options={options}"] if options else []
for p in sorted(macho_files, key=lambda x: len(x.split("/")), reverse=True):
    cmd = ["/usr/bin/codesign", "-f", "-s", signing_identity] + opts_arg
    if p in entitlements:
        cmd.extend(["--entitlements", entitlements[p]])
    cmd.append(p)
    subprocess.run(cmd, check=True, capture_output=True)

# 4. Codesign nested bundles (frameworks, plugins, XPC services) deepest first
nested_bundles = []
for root, dirs, files in os.walk(app_bundle):
    for d in dirs:
        if d.endswith(".framework") or d.endswith(".xpc") or d.endswith(".bundle") or d.endswith(".plugin"):
            p = os.path.join(root, d)
            if not os.path.islink(p):
                nested_bundles.append(p)

nested_bundles_sorted = sorted(nested_bundles, key=lambda x: len(x.split("/")), reverse=True)
for b in nested_bundles_sorted:
    cmd = ["/usr/bin/codesign", "-f", "-s", signing_identity] + opts_arg + [b]
    subprocess.run(cmd, check=True, capture_output=True)

# 5. Codesign top-level app bundle
main_exec = os.path.join(app_bundle, "Contents/MacOS", os.path.splitext(os.path.basename(app_bundle))[0])
if not os.path.exists(main_exec):
    # Try finding any executable in Contents/MacOS
    macos_dir = os.path.join(app_bundle, "Contents/MacOS")
    if os.path.exists(macos_dir):
        execs = [os.path.join(macos_dir, f) for f in os.listdir(macos_dir) if os.path.isfile(os.path.join(macos_dir, f))]
        if execs:
            main_exec = execs[0]

app_ent = entitlements.get(main_exec)
cmd = ["/usr/bin/codesign", "-f", "-s", signing_identity] + opts_arg
if app_ent:
    cmd.extend(["--entitlements", app_ent])
cmd.append(app_bundle)
subprocess.run(cmd, check=True, capture_output=True)

# 6. Verify signature
verify = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app_bundle], capture_output=True, text=True)
if verify.returncode != 0:
    print(f"Codesign verification failed for {app_bundle}: {verify.stderr}", file=sys.stderr)
    sys.exit(verify.returncode)

shutil.rmtree(ent_dir)
PYEOF

mkdir -p "$(dirname "$out_zip")"
app_name="$(basename "$app_bundle")"
(
    cd "$(dirname "$app_bundle")"
    /usr/bin/ditto -c -k --keepParent "$app_name" "$tmp_dir/output.zip"
)
/bin/mv "$tmp_dir/output.zip" "$out_zip"
""",
        mnemonic = "MacosLipoApp",
        progress_message = "Extracting and signing {} architecture for {}".format(arch, ctx.label),
    )

    return [
        DefaultInfo(
            files = depset([out_zip]),
        ),
    ]

macos_lipo_app = rule(
    implementation = _macos_lipo_app_impl,
    doc = "Extracts a single-architecture macOS application bundle from a universal binary app and re-signs it.",
    attrs = {
        "app": attr.label(
            mandatory = True,
            doc = "The application target (.zip or .app) providing universal binary.",
        ),
        "arch": attr.string(
            mandatory = True,
            values = ["arm64", "x86_64"],
            doc = "Target architecture to thin to (arm64 or x86_64).",
        ),
        "options": attr.string_list(
            default = ["runtime"],
            doc = "Codesign options flags (e.g. runtime).",
        ),
        "out": attr.output(
            doc = "Output .zip archive containing the thinned and signed .app bundle.",
        ),
        "signing_identity": attr.string(
            default = "Developer ID Application: Richard Penwell (DWVXMLB45Y)",
            doc = "Codesigning identity Common Name for Developer ID signing.",
        ),
        "_macos_constraint": attr.label(
            default = Label("@platforms//os:macos"),
        ),
    },
)

lipo_app = macos_lipo_app
thin_app = macos_lipo_app
