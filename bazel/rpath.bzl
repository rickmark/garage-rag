# Matches whole path components rather than searching for a "lib/" substring: the
# substring form silently mangles any package whose own name ends in "lib", e.g.
# ext/libzlib/lib/libz.1.dylib, where the first "lib/" hit is the tail of "libzlib/"
# and the file lands at lib/lib/libz.1.dylib. Nothing then matches it by basename when
# rewriting dependencies below, so consumers keep an unresolvable @rpath/libz.1.dylib.
def _relative_path(file):
    components = file.short_path.split("/")
    for index, component in enumerate(components):
        if component in ["bin", "include", "lib", "share"]:
            return "/".join(components[index:])
    return None

def _install_name(ctx):
    if not ctx.target_platform_has_constraint(ctx.attr._macos_constraint[platform_common.ConstraintValueInfo]):
        fail("{} only supports macOS targets".format(ctx.label))

    files = []
    destinations = []
    for dep in ctx.attr.deps:
        for file in dep[DefaultInfo].files.to_list():
            destination = _relative_path(file)
            if destination:
                files.append(file)
                destinations.append(destination)
    if not files:
        fail("{} does not produce runtime files in bin, include, lib, or share".format(ctx.label))

    output = ctx.actions.declare_directory(ctx.label.name)
    arguments = ctx.actions.args()
    arguments.add(output.path)
    for file, destination in zip(files, destinations):
        arguments.add(file.path)
        arguments.add(destination)

    ctx.actions.run_shell(
        inputs = files,
        outputs = [output],
        arguments = [arguments],
        command = """
set -euo pipefail

output="$1"
shift
mkdir -p "$output"

while [ "$#" -gt 0 ]; do
    source="$1"
    destination="$2"
    shift 2
    mkdir -p "$output/$(dirname "$destination")"
    cp -pRL "$source" "$output/$destination"
done

find "$output/lib" -type f 2>/dev/null | while IFS= read -r library; do
    case "$library" in
        *.a|*.dSYM/*) continue ;;
    esac
    if file -b "$library" | grep -q "ar archive"; then
        continue
    fi
    if file -b "$library" | grep -q "Mach-O"; then
        /usr/bin/install_name_tool -id "@rpath/$(basename "$library")" "$library"
    fi
done

find "$output" -type f | while IFS= read -r binary; do
    case "$binary" in
        *.a|*.dSYM/*) continue ;;
    esac
    if file -b "$binary" | grep -q "ar archive"; then
        continue
    fi
    if ! file -b "$binary" | grep -q "Mach-O"; then
        continue
    fi

    case "$binary" in
        "$output/bin/"*) prefix="@executable_path/../lib" ;;
        *) prefix="@loader_path" ;;
    esac

    otool -L "$binary" | tail -n +2 | while IFS= read -r dependency; do
        dependency="${dependency#"${dependency%%[![:space:]]*}"}"
        dependency="${dependency%% *}"
        name="$(basename "$dependency")"
        if [ -f "$output/lib/$name" ] && [ "$dependency" != "$prefix/$name" ]; then
            /usr/bin/install_name_tool -change "$dependency" "$prefix/$name" "$binary"
        fi
    done
done
""",
        mnemonic = "InstallName",
        progress_message = "Rewriting install names for {}".format(ctx.label),
    )

    return [DefaultInfo(files = depset([output]))]

install_name = rule(
    implementation = _install_name,
    attrs = {
        "deps": attr.label_list(mandatory = True, doc = "Dependencies whose bin, lib, and share outputs are bundled together."),
        "_macos_constraint": attr.label(default = Label("@platforms//os:macos")),
    },
)
