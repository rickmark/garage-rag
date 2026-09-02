"""Rules for codesigning binaries and directories of binaries on macOS."""

def _codesign_impl(ctx):
    if not ctx.target_platform_has_constraint(ctx.attr._macos_constraint[platform_common.ConstraintValueInfo]):
        fail("{} only supports macOS targets".format(ctx.label))

    inputs = []
    if ctx.attr.src:
        inputs.extend(ctx.attr.src[DefaultInfo].files.to_list())
    elif ctx.attr.dep:
        inputs.extend(ctx.attr.dep[DefaultInfo].files.to_list())
    elif ctx.attr.srcs:
        for s in ctx.attr.srcs:
            inputs.extend(s[DefaultInfo].files.to_list())

    if not inputs:
        fail("{}: 'src', 'dep', or 'srcs' must be specified and non-empty".format(ctx.label))

    is_dir = False
    if len(inputs) == 1:
        input_file = inputs[0]
        is_dir = input_file.is_directory
    else:
        is_dir = True

    out_name = ctx.attr.out if ctx.attr.out else ctx.label.name
    if is_dir:
        output = ctx.actions.declare_directory(out_name)
    else:
        output = ctx.actions.declare_file(out_name)

    codesign_args = []
    if ctx.attr.codesignopts:
        codesign_args.extend(ctx.attr.codesignopts)
    if ctx.attr.options:
        for opt in ctx.attr.options:
            if opt.startswith("-"):
                codesign_args.append(opt)
            else:
                codesign_args.append("--options=" + opt)
    if not codesign_args:
        codesign_args.append("--options=runtime")

    signing_identity = ctx.attr.sign if ctx.attr.sign else (ctx.attr.signing_identity if ctx.attr.signing_identity else "-")

    extra_inputs = []
    if ctx.file.entitlements:
        extra_inputs.append(ctx.file.entitlements)
        codesign_args.extend(["--entitlements", ctx.file.entitlements.path])

    if ctx.attr.timestamp:
        codesign_args.append("--timestamp")

    args = ctx.actions.args()
    args.add(output.path)
    args.add("dir" if is_dir else "file")
    args.add(signing_identity)
    args.add(str(len(codesign_args)))
    args.add_all(codesign_args)
    args.add(str(len(inputs)))
    for f in inputs:
        args.add(f.path)

    ctx.actions.run_shell(
        inputs = inputs + extra_inputs,
        outputs = [output],
        arguments = [args],
        command = """
set -euo pipefail

output="$1"
kind="$2"
signing_identity="$3"
num_opts="$4"
shift 4

opts=()
while [ "$num_opts" -gt 0 ]; do
    opts+=("$1")
    shift
    num_opts=$((num_opts - 1))
done

num_inputs="$1"
shift 1

inputs=("$@")

signing_identity="${signing_identity#\\\"}"
signing_identity="${signing_identity%\\\"}"

if [ "$kind" = "dir" ]; then
    mkdir -p "$output"
    for input_path in "${inputs[@]}"; do
        if [ -d "$input_path" ]; then
            cp -pRL "$input_path/." "$output/"
        else
            mkdir -p "$output/$(dirname "$input_path")"
            cp -pL "$input_path" "$output/$input_path"
        fi
    done
    chmod -R u+w "$output" 2>/dev/null || true

    find "$output" -type f | while IFS= read -r file; do
        case "$file" in
            *.a) continue ;;
        esac
        if file -b "$file" | grep -q "ar archive"; then
            continue
        fi
        if file -b "$file" | grep -q "Mach-O"; then
            /usr/bin/codesign -f -s "$signing_identity" "${opts[@]}" "$file"
        fi
    done
else
    mkdir -p "$(dirname "$output")"
    cp -pL "${inputs[0]}" "$output"
    chmod u+w "$output" 2>/dev/null || true
    if file -b "$output" | grep -q "Mach-O"; then
        /usr/bin/codesign -f -s "$signing_identity" "${opts[@]}" "$output"
    fi
fi
""",
        mnemonic = "Codesign",
        progress_message = "Codesigning {}".format(ctx.label),
    )

    default_info_kwargs = {
        "files": depset([output]),
        "runfiles": ctx.runfiles(files = [output]),
    }
    if not is_dir:
        default_info_kwargs["executable"] = output

    return [DefaultInfo(**default_info_kwargs)]

codesign = rule(
    implementation = _codesign_impl,
    attrs = {
        "codesignopts": attr.string_list(
            doc = "Extra options passed directly to codesign.",
        ),
        "dep": attr.label(
            doc = "Dependency to codesign (alias for src).",
        ),
        "entitlements": attr.label(
            allow_single_file = True,
            doc = "Entitlements plist file to embed.",
        ),
        "options": attr.string_list(
            default = ["runtime"],
            doc = "Codesign options (e.g. ['runtime']). Defaults to ['runtime'].",
        ),
        "out": attr.string(
            doc = "Output file or directory name. Defaults to target name.",
        ),
        "sign": attr.string(
            doc = "Signing identity (alias for signing_identity).",
        ),
        "signing_identity": attr.string(
            default = "-",
            doc = "Signing identity or certificate. Defaults to '-' for ad-hoc signing.",
        ),
        "src": attr.label(
            doc = "Source target or file to codesign.",
        ),
        "srcs": attr.label_list(
            doc = "Source targets or files to codesign.",
        ),
        "timestamp": attr.bool(
            default = False,
            doc = "Whether to request a timestamp authority signature.",
        ),
        "_macos_constraint": attr.label(
            default = Label("@platforms//os:macos"),
        ),
    },
    doc = "Codesigns Mach-O binaries and directories of binaries with specified options.",
)
