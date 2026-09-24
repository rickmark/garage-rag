"""Apache AGE source tree with its Cypher parser and scanner already generated.

AGE's Makefile runs bison and flex through PGXS, which would pick up whatever the build host
has: macOS ships Bison 2.3, too old for AGE's grammar (it needs -W warning categories and
%expect-rr). Generating both files here with the hermetic rules_bison / rules_flex toolchains
and overlaying them onto the checkout leaves make nothing to regenerate; //ext/age tells make
to treat them as current (-o) and points BISON/FLEX at `false` so a stray rebuild fails.
"""

load("@aspect_bazel_lib//lib:copy_to_directory.bzl", "copy_to_directory")

# Relative to the AGE source root. The names are fixed: cypher_gram.c includes its header as
# "cypher_gram_def.h" (found through -Isrc/include/parser), and the Makefile's -o list below
# names the same paths.
GRAM_C = "src/backend/parser/cypher_gram.c"
GRAM_H = "src/include/parser/cypher_gram_def.h"
SCANNER_C = "src/backend/parser/ag_scanner.c"
GENERATED = [GRAM_C, GRAM_H, SCANNER_C]

def age_source(name, repo, tags = []):
    """Declares :<name>, a directory holding repo's AGE checkout plus the generated parser.

    Call from a package of its own (//ext/age/pg18, //ext/age/pg19): the genrule outputs sit at
    their source-tree paths relative to that package, which is what copy_to_directory strips.

    Args:
        name: name of the resulting directory target.
        repo: the AGE source repository, e.g. "@age_pg18".
        tags: tags applied to every target.
    """
    native.genrule(
        name = name + "_gram",
        srcs = [repo + "//:src/backend/parser/cypher_gram.y"],
        outs = [GRAM_C, GRAM_H],
        # The flags AGE's Makefile adds, plus PGXS's own -Wno-deprecated (the grammar still
        # uses %name-prefix and %pure-parser).
        cmd = " ".join([
            "M4=$(M4) $(BISON)",
            "-Wno-deprecated",
            "-Werror -Wno-error=conflicts-sr -Wno-error=conflicts-rr",
            "--defines=$(location %s)" % GRAM_H,
            "--output=$(location %s)" % GRAM_C,
            "$<",
        ]),
        tags = tags,
        toolchains = [
            "@rules_bison//bison:current_bison_toolchain",
            "@rules_m4//m4:current_m4_toolchain",
        ],
    )

    native.genrule(
        name = name + "_scanner",
        srcs = [repo + "//:src/backend/parser/ag_scanner.l"],
        outs = [SCANNER_C],
        # The scanner declares `%option backup`, so flex always writes `lex.backup` to its working
        # directory (upstream flex has no option to redirect it; PGXS only reads it to assert there
        # is no backing up). Run it from a scratch directory, which takes absolute paths for the
        # tool, m4, input and output. --noline keeps sandbox paths out of the generated file.
        cmd = """
abs() { case "$$1" in /*) echo "$$1" ;; *) echo "$$PWD/$$1" ;; esac; }
flex=$$(abs $(FLEX)) m4=$$(abs $(M4)) src=$$(abs $<) out=$$(abs $@)
tmp=$$(mktemp -d)
(cd "$$tmp" && M4="$$m4" "$$flex" --noline --outfile="$$out" "$$src")
rc=$$?
rm -rf "$$tmp"
exit $$rc
""",
        tags = tags,
        toolchains = [
            "@rules_flex//flex:current_flex_toolchain",
            "@rules_m4//m4:current_m4_toolchain",
        ],
    )

    copy_to_directory(
        name = name,
        srcs = [
            repo + "//:age_source",
            ":" + name + "_gram",
            ":" + name + "_scanner",
        ],
        out = name,
        include_external_repositories = ["*" + repo.lstrip("@")],
        tags = tags,
        visibility = ["//ext/age:__pkg__"],
    )
