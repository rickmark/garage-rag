"""Helpers for extracting individual files out of rules_foreign_cc build outputs."""

def extract_foreign_cc_file(name, target, filename, out):
    """Copies a single named file out of a foreign_cc target's outputs.

    rules_foreign_cc targets bundle all of their declared outputs (bin/lib/include/share)
    under one label; this pulls one file out by basename so it can be referenced on its
    own, e.g. by cc_import or by //bazel:rpath.bzl's install_name rule.
    """
    native.genrule(
        name = name,
        srcs = [target],
        outs = [out],
        cmd = """
src=""
for f in $(locations {target}); do
    if [ "$$(basename "$$f")" = "{filename}" ]; then
        src="$$f"
        break
    fi
done
if [ -z "$$src" ]; then
    echo "{name}: {filename} not found in {target} outputs" >&2
    exit 1
fi
cp -L "$$src" "$@"
""".format(target = target, filename = filename, name = name),
    )
