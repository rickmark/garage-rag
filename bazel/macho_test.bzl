"""Bazel test rules for verifying Mach-O binary architectures."""

def _macho_arch_test_impl(ctx):
    if not ctx.target_platform_has_constraint(ctx.attr._macos_constraint[platform_common.ConstraintValueInfo]):
        fail("{} only supports macOS targets".format(ctx.label))

    inputs = []
    if ctx.attr.src:
        inputs.extend(ctx.attr.src[DefaultInfo].files.to_list())
    elif ctx.attr.app:
        inputs.extend(ctx.attr.app[DefaultInfo].files.to_list())
    elif ctx.attr.bundle:
        inputs.extend(ctx.attr.bundle[DefaultInfo].files.to_list())
    elif ctx.attr.binary:
        inputs.extend(ctx.attr.binary[DefaultInfo].files.to_list())
    elif ctx.attr.target:
        inputs.extend(ctx.attr.target[DefaultInfo].files.to_list())
    elif ctx.attr.dep:
        inputs.extend(ctx.attr.dep[DefaultInfo].files.to_list())
    elif ctx.attr.srcs:
        for s in ctx.attr.srcs:
            inputs.extend(s[DefaultInfo].files.to_list())

    if not inputs:
        fail("{}: 'src', 'app', 'bundle', 'binary', 'target', 'dep', or 'srcs' must be specified".format(ctx.label))

    test_script = ctx.actions.declare_file(ctx.label.name + "_test.sh")

    archs = ctx.attr.archs if ctx.attr.archs else ["arm64", "x86_64"]
    exclude_patterns = ctx.attr.exclude_patterns

    archs_str = "\n".join(['    "{}"'.format(a) for a in archs])
    excludes_str = "\n".join(['    "{}"'.format(e) for e in exclude_patterns])
    inputs_str = "\n".join(['    "{}"'.format(f.short_path) for f in inputs])

    script_content = """#!/bin/bash
set -euo pipefail

expected_archs=(
{archs}
)

exclude_patterns=(
{excludes}
)

input_short_paths=(
{inputs}
)

resolve_rlocation() {{
    local sp="$1"
    local path=""
    if [ -n "${{RUNFILES_DIR:-}}" ] && [ -e "${{RUNFILES_DIR}}/_main/${{sp}}" ]; then
        path="${{RUNFILES_DIR}}/_main/${{sp}}"
    elif [ -n "${{RUNFILES_DIR:-}}" ] && [ -e "${{RUNFILES_DIR}}/${{sp}}" ]; then
        path="${{RUNFILES_DIR}}/${{sp}}"
    elif [ -n "${{RUNFILES_MANIFEST_FILE:-}}" ]; then
        path="$(grep -m 1 "^_main/${{sp}} " "${{RUNFILES_MANIFEST_FILE}}" 2>/dev/null | cut -d' ' -f2- || true)"
        if [ -z "$path" ] || [ ! -e "$path" ]; then
            path="$(grep -m 1 "^${{sp}} " "${{RUNFILES_MANIFEST_FILE}}" 2>/dev/null | cut -d' ' -f2- || true)"
        fi
    fi

    if [ -z "$path" ] || [ ! -e "$path" ]; then
        if [ -e "${{0}}.runfiles/_main/${{sp}}" ]; then
            path="${{0}}.runfiles/_main/${{sp}}"
        elif [ -e "${{0}}.runfiles/${{sp}}" ]; then
            path="${{0}}.runfiles/${{sp}}"
        elif [ -e "${{sp}}" ]; then
            path="${{sp}}"
        fi
    fi
    echo "$path"
}}

TMP_DIR="$(mktemp -d "${{TMPDIR:-/tmp}}/macho_arch_test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

resolved_inputs=()
for sp in "${{input_short_paths[@]}}"; do
    res="$(resolve_rlocation "$sp")"
    if [ -z "$res" ] || [ ! -e "$res" ]; then
        echo "Error: Could not locate input file: $sp in runfiles" >&2
        exit 1
    fi
    resolved_inputs+=("$res")
done

STAGE_DIR="$TMP_DIR/stage"
mkdir -p "$STAGE_DIR"

for item in "${{resolved_inputs[@]}}"; do
    if [ -d "$item" ]; then
        cp -R "$item" "$STAGE_DIR/"
    elif [[ "$item" == *.zip ]]; then
        /usr/bin/unzip -q -o "$item" -d "$STAGE_DIR"
    else
        cp "$item" "$STAGE_DIR/"
    fi
done

should_exclude() {{
    local file_path="$1"
    for pat in "${{exclude_patterns[@]+"${{exclude_patterns[@]}}"}}"; do
        if [ -n "$pat" ] && [[ "$file_path" == *"$pat"* ]]; then
            return 0
        fi
    done
    return 1
}}

echo "============================================================"
echo "Mach-O Architecture Verification Test"
echo "Expected architectures: ${{expected_archs[*]}}"
echo "============================================================"

get_macho_archs() {{
    local target_file="$1"
    local a_out
    a_out="$(/usr/bin/lipo -archs "$target_file" 2>/dev/null || true)"
    if [ -n "$a_out" ]; then
        echo "$a_out"
        return
    fi
    local ar_tmp
    ar_tmp="$(mktemp -d "${{TMPDIR:-/tmp}}/ar_check.XXXXXX")"
    (
        cd "$ar_tmp"
        /usr/bin/ar x "$target_file" 2>/dev/null || true
    )
    local found_archs=""
    for m in "$ar_tmp"/*; do
        if [ -f "$m" ]; then
            m_archs="$(/usr/bin/lipo -archs "$m" 2>/dev/null || true)"
            if [ -n "$m_archs" ]; then
                found_archs="$m_archs"
                break
            fi
        fi
    done
    rm -rf "$ar_tmp"
    echo "$found_archs"
}}

total_macho=0
failed_count=0

while IFS= read -r f; do
    [ -f "$f" ] || continue
    [ ! -L "$f" ] || continue

    case "$f" in
        *.dSYM/*|*.dSYM) continue ;;
    esac

    if should_exclude "$f"; then
        continue
    fi

    file_type="$(file -b "$f" 2>/dev/null || true)"
    case "$file_type" in
        *"Mach-O"*|*"ar archive"*)
            total_macho=$((total_macho + 1))
            rel_name="${{f#$STAGE_DIR/}}"
            archs="$(get_macho_archs "$f")"
            missing=()
            for req in "${{expected_archs[@]}}"; do
                found=0
                for a in $archs; do
                    if [ "$a" = "$req" ]; then
                        found=1
                        break
                    fi
                done
                if [ "$found" -eq 0 ]; then
                    missing+=("$req")
                fi
            done

            if [ "${{#missing[@]}}" -gt 0 ]; then
                echo "[FAIL] $rel_name"
                echo "       Found architectures: $archs"
                echo "       Missing required:    ${{missing[*]}}"
                failed_count=$((failed_count + 1))
            else
                echo "[PASS] $rel_name ($archs)"
            fi
            ;;
    esac
done < <(find "$STAGE_DIR" -type f)

echo "============================================================"
echo "Checked $total_macho Mach-O binaries: $((total_macho - failed_count)) passed, $failed_count failed"
echo "============================================================"

if [ "$total_macho" -eq 0 ]; then
    echo "Error: No Mach-O binaries were found in target inputs" >&2
    exit 1
fi

if [ "$failed_count" -gt 0 ]; then
    exit 1
fi

exit 0
""".format(
        archs = archs_str,
        excludes = excludes_str,
        inputs = inputs_str,
    )

    ctx.actions.write(
        output = test_script,
        content = script_content,
        is_executable = True,
    )

    runfiles = ctx.runfiles(files = inputs)
    if ctx.attr.src:
        runfiles = runfiles.merge(ctx.attr.src[DefaultInfo].default_runfiles)
    elif ctx.attr.app:
        runfiles = runfiles.merge(ctx.attr.app[DefaultInfo].default_runfiles)
    elif ctx.attr.dep:
        runfiles = runfiles.merge(ctx.attr.dep[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(
            executable = test_script,
            runfiles = runfiles,
        ),
    ]

macho_arch_test = rule(
    implementation = _macho_arch_test_impl,
    test = True,
    attrs = {
        "app": attr.label(
            doc = "Application target to test (alias for src).",
        ),
        "archs": attr.string_list(
            default = ["arm64", "x86_64"],
            doc = "List of target architectures required in each Mach-O binary. Defaults to ['arm64', 'x86_64'].",
        ),
        "binary": attr.label(
            doc = "Binary target to test (alias for src).",
        ),
        "bundle": attr.label(
            doc = "Bundle target to test (alias for src).",
        ),
        "dep": attr.label(
            doc = "Dependency target to test (alias for src).",
        ),
        "exclude_patterns": attr.string_list(
            default = [],
            doc = "Substrings or glob patterns to exclude from architecture checking.",
        ),
        "src": attr.label(
            doc = "Target or file containing Mach-O binaries to test.",
        ),
        "srcs": attr.label_list(
            doc = "Targets or files containing Mach-O binaries to test.",
        ),
        "target": attr.label(
            doc = "Target to test (alias for src).",
        ),
        "_macos_constraint": attr.label(
            default = Label("@platforms//os:macos"),
        ),
    },
    doc = "Verifies that all Mach-O binaries in the target contain the specified architectures.",
)

mach_o_arch_test = macho_arch_test
universal_binary_test = macho_arch_test
multi_arch_test = macho_arch_test
macho_test = macho_arch_test
