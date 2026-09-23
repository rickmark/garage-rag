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

def _soname_stem(soname):
    """Strips the .dylib suffix and any trailing numeric components: libz.1.3.2.dylib -> libz."""
    stem = soname[:-len(".dylib")] if soname.endswith(".dylib") else soname
    for _ in range(16):
        (head, separator, tail) = stem.rpartition(".")
        if not separator or not tail.isdigit():
            break
        stem = head
    return stem

def normalize_install_names(sonames):
    """Returns a foreign_cc postfix_script that stamps shared libraries with @rpath ids.

    Two problems make the default ids unusable for a consuming target:

    * They are absolute paths into the *producing* target's sandbox
      (.../sandbox/darwin-sandbox/NNNN/.../<name>.build_tmpdir/...), which no longer exists
      by the time anything links against them. PostgreSQL's `checking test program` conftest
      links, runs, and aborts with "dyld: Library not loaded"; ICU is worse still and stamps
      a bare filename with no path at all.
    * An autotools `make install` lays each library down under several names
      (libz.dylib, libz.1.dylib, libz.1.3.2.dylib) as independent regular files rather than
      symlinks. Left alone each gets an id matching its own basename, so `-lz` resolves to
      the *unversioned* libz.dylib — a name the app bundle never ships, because
      //bazel:rpath.bzl only bundles the versioned one.

    So every alias of a library is stamped with the one canonical versioned soname, and
    references between the libraries are repointed at it. Aliases are matched on the stem
    left after dropping trailing numeric components, so libz.dylib, libz.1.dylib and
    libz.1.3.2.dylib all take the id of the soname whose stem is likewise "libz".

    Consumers supply the location at build time with -Wl,-rpath,$EXT_BUILD_DEPS/<dep>/lib;
    //bazel:rpath.bzl's install_name rule rewrites them once more to @loader_path-relative
    paths for the shipped bundle.

    The case arms are generated here rather than computed in the script because
    rules_foreign_cc reserves ## for its own ##function## syntax and Bazel rejects ${var}
    in this attribute outright, which between them rule out the usual shell idioms.

    Args:
        sonames: canonical versioned filenames, e.g. ["libz.1.dylib"]. These are the names
            the app bundle ships, i.e. the ones named by extract_foreign_cc_file.

    Returns:
        A shell fragment suitable for a foreign_cc rule's postfix_script attribute.
    """
    arms = []
    for soname in sonames:
        stem = _soname_stem(soname)
        arms.append('            {stem}.dylib|{stem}.[0-9]*.dylib) canonical="{soname}" ;;'.format(
            stem = stem,
            soname = soname,
        ))
    cases = "\n".join(arms)

    return """
for lib in $$INSTALLDIR/lib/*.dylib; do
    if [ ! -f "$$lib" ]; then continue; fi
    canonical=""
    case "$$(basename "$$lib")" in
{cases}
    esac
    if [ -n "$$canonical" ]; then
        /usr/bin/install_name_tool -id "@rpath/$$canonical" "$$lib"
    fi
done

for lib in $$INSTALLDIR/lib/*.dylib; do
    if [ ! -f "$$lib" ]; then continue; fi
    otool -L "$$lib" | tail -n +2 | awk '{{print $$1}}' | while IFS= read -r dependency; do
        if [ -z "$$dependency" ]; then continue; fi
        canonical=""
        case "$$(basename "$$dependency")" in
{cases}
        esac
        if [ -n "$$canonical" ] && [ "$$dependency" != "@rpath/$$canonical" ]; then
            /usr/bin/install_name_tool -change "$$dependency" "@rpath/$$canonical" "$$lib"
        fi
    done
done
""".format(cases = cases)
