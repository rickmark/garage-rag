"""Rules for codesigning binaries and directories of binaries on macOS."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

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

    signing_identity = ctx.attr.sign if ctx.attr.sign else ctx.attr.signing_identity
    if not signing_identity or signing_identity == "-":
        if hasattr(ctx.attr, "_signing_certificate_name") and ctx.attr._signing_certificate_name:
            cert_from_setting = ctx.attr._signing_certificate_name[BuildSettingInfo].value
            if cert_from_setting:
                signing_identity = cert_from_setting
    if not signing_identity:
        signing_identity = "-"

    extra_inputs = []
    default_entitlements_path = ""
    if ctx.file.entitlements:
        extra_inputs.append(ctx.file.entitlements)
        default_entitlements_path = ctx.file.entitlements.path

    entitlements_by_filename = {}
    for filename, entitlement in ctx.attr.entitlements_by_filename.items():
        entitlement_file = entitlement.files.to_list()[0]
        extra_inputs.append(entitlement_file)
        entitlements_by_filename[filename] = entitlement_file.path

    if ctx.attr.timestamp:
        codesign_args.append("--timestamp")

    dylibs_only = ctx.attr.dylibs_only or ctx.attr.dylib_only or ctx.attr.only_dylibs

    args = ctx.actions.args()
    args.add(output.path)
    args.add("dir" if is_dir else "file")
    args.add(signing_identity)
    args.add("1" if dylibs_only else "0")
    args.add(default_entitlements_path)
    args.add(str(len(entitlements_by_filename)))
    for filename, entitlement_path in entitlements_by_filename.items():
        args.add(filename)
        args.add(entitlement_path)
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
dylibs_only="$4"
default_entitlements="$5"
num_entitlements_by_filename="$6"
shift 6

entitlement_filenames=()
entitlement_paths=()
while [ "$num_entitlements_by_filename" -gt 0 ]; do
    entitlement_filenames+=("$1")
    entitlement_paths+=("$2")
    shift 2
    num_entitlements_by_filename=$((num_entitlements_by_filename - 1))
done

num_opts="$1"
shift 1

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

codesign_file() {
    local file="$1"
    local filename
    local entitlements
    local sign_opts

    filename="$(basename "$file")"
    entitlements="$default_entitlements"

    for i in "${!entitlement_filenames[@]}"; do
        if [ "$filename" = "${entitlement_filenames[$i]}" ]; then
            entitlements="${entitlement_paths[$i]}"
            break
        fi
    done

    sign_opts=("${opts[@]}")
    if [ -n "$entitlements" ]; then
        sign_opts+=("--entitlements" "$entitlements")
    fi

    /usr/bin/codesign -f -s "$signing_identity" "${sign_opts[@]}" "$file"
}

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
        if [ "$dylibs_only" = "1" ]; then
            filename="$(basename "$file")"
            case "$filename" in
                *.dylib|*.dylib.*) ;;
                *) continue ;;
            esac
        fi
        if file -b "$file" | grep -q "ar archive"; then
            continue
        fi
        if file -b "$file" | grep -q "Mach-O"; then
            codesign_file "$file"
        fi
    done
else
    mkdir -p "$(dirname "$output")"
    cp -pL "${inputs[0]}" "$output"
    chmod u+w "$output" 2>/dev/null || true
    should_sign=1
    if [ "$dylibs_only" = "1" ]; then
        filename="$(basename "$output")"
        case "$filename" in
            *.dylib|*.dylib.*) ;;
            *) should_sign=0 ;;
        esac
    fi
    if [ "$should_sign" = "1" ] && file -b "$output" | grep -q "Mach-O"; then
        codesign_file "$output"
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
        "dylib_only": attr.bool(
            default = False,
            doc = "Alias for dylibs_only.",
        ),
        "dylibs_only": attr.bool(
            default = False,
            doc = "Whether to only sign dynamic libraries (.dylib files).",
        ),
        "entitlements": attr.label(
            allow_single_file = True,
            doc = "Default entitlements plist file to embed.",
        ),
        "entitlements_by_filename": attr.string_keyed_label_dict(
            allow_files = True,
            doc = "Entitlements plist files to use for specific output basenames.",
        ),
        "only_dylibs": attr.bool(
            default = False,
            doc = "Alias for dylibs_only.",
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
            default = "",
            doc = "Signing identity or certificate. Defaults to the active signing certificate build setting, or '-' for ad-hoc signing.",
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
        "_signing_certificate_name": attr.label(
            default = Label("@rules_apple//apple/build_settings:signing_certificate_name"),
        ),
    },
    doc = "Codesigns Mach-O binaries and directories of binaries with specified options.",
)
