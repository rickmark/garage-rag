"Define linter aspects"



load("@aspect_rules_lint//lint:lint_test.bzl", "lint_test")



load("@aspect_rules_lint//lint:ruff.bzl", "lint_ruff_aspect")
load("@aspect_rules_lint//lint:ty.bzl", "lint_ty_aspect")










ruff = lint_ruff_aspect(
    binary = "@multitool//tools/ruff",
    configs = [
        Label("//:pyproject.toml"),
        # if the repository has nested ruff.toml files, they must be added here as well
    ],
)

ruff_test = lint_test(aspect = ruff)

ty = lint_ty_aspect(
    binary = Label("@aspect_rules_lint//lint:ty_bin"),
    config = Label("@//:pyproject.toml"),
)




