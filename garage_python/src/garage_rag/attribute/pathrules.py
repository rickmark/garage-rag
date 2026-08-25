"""Trust classification from filesystem layout.

Where a file sits is often the strongest available signal about whether it is
something the owner wrote or something they collected. These rules encode the
conventions observed in this corpus; they are data, not logic, so adapting them
to a different layout means editing the table rather than the algorithm.

Rules are evaluated in order and the first match wins, so the most specific
patterns are listed first.
"""

from __future__ import annotations

import fnmatch
import logging
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

from garage_rag.db.models import TrustTier

log = logging.getLogger(__name__)


@dataclass(frozen=True)
class PathRule:
    """A glob over a source-relative path, and the trust it implies."""

    pattern: str
    trust: TrustTier
    # Recorded on the attribution so a decision can be traced back.
    label: str

    def matches(self, relative: str) -> bool:
        return fnmatch.fnmatch(relative, self.pattern)


# Vendored dependency directories: third-party code by definition, wherever found.
VENDOR_MARKERS: frozenset[str] = frozenset(
    {
        "node_modules",
        "vendor",
        "third_party",
        "3rd_party",
        "thirdparty",
        "external",
        "externals",
        "deps",
        "dependencies",
        "Pods",
        "Carthage",
        "site-packages",
        "bower_components",
        "submodules",
        "subprojects",
    }
)

# Ordered: first match wins.
DEFAULT_RULES: tuple[PathRule, ...] = (
    # --- explicit reference collections -----------------------------------
    PathRule("Reference/*", TrustTier.REFERENCE, "path:Reference"),
    PathRule("Documents/Paper/Reference/*", TrustTier.REFERENCE, "path:Paper/Reference"),
    PathRule("Documents/Reference/*", TrustTier.REFERENCE, "path:Documents/Reference"),
    # Collected papers and manuals, as opposed to research the owner wrote.
    PathRule("**/Army Field Manuals/*", TrustTier.REFERENCE, "path:field-manuals"),
    PathRule("**/Documentation/*", TrustTier.REFERENCE, "path:Documentation"),
    PathRule("**/Datasheets/*", TrustTier.REFERENCE, "path:Datasheets"),
    PathRule("**/Manuals/*", TrustTier.REFERENCE, "path:Manuals"),
    PathRule("**/Books/*", TrustTier.REFERENCE, "path:Books"),
    PathRule("**/Papers/*", TrustTier.REFERENCE, "path:Papers"),
    PathRule("**/Specs/*", TrustTier.REFERENCE, "path:Specs"),
    PathRule("**/RFCs/*", TrustTier.REFERENCE, "path:RFCs"),
    # --- the owner's own material -----------------------------------------
    PathRule("Personal/*", TrustTier.AUTHORED, "path:Personal"),
    PathRule("Projects/*", TrustTier.AUTHORED, "path:Projects"),
    PathRule("Documents/Research/*", TrustTier.AUTHORED, "path:Documents/Research"),
    PathRule("Documents/Paper/*", TrustTier.AUTHORED, "path:Documents/Paper"),
    PathRule("Notes/*", TrustTier.AUTHORED, "path:Notes"),
)

# Subtrees holding applications and binary objects rather than writing.
EXCLUDED_PREFIXES: tuple[str, ...] = ("Library/", "Objects/", "Software/", "Public/")


def is_vendored(path: Path) -> bool:
    """Whether any path component marks a vendored dependency tree."""
    return any(part in VENDOR_MARKERS for part in path.parts)


def is_excluded_prefix(relative: str) -> bool:
    return any(relative.startswith(prefix) for prefix in EXCLUDED_PREFIXES)


def relative_to_root(root: Path, path: Path) -> str:
    """Source-relative POSIX path, or the bare name when outside the root."""
    try:
        return PurePosixPath(path.resolve().relative_to(root.resolve())).as_posix()
    except ValueError:
        return path.name


def classify_path(
    path: Path,
    root: Path,
    *,
    rules: tuple[PathRule, ...] = DEFAULT_RULES,
    default: TrustTier = TrustTier.AUTHORED,
) -> tuple[TrustTier, str]:
    """Trust tier for ``path``, with the label of the rule that decided it."""
    # Vendored code is third-party regardless of where the tree sits.
    if is_vendored(path):
        return TrustTier.REFERENCE, "path:vendored"

    relative = relative_to_root(root, path)
    for rule in rules:
        if rule.matches(relative):
            return rule.trust, rule.label

    # A bare "Reference" or "Papers" component anywhere is a strong hint that
    # the enclosing tree is collected rather than written.
    lowered = {part.lower() for part in path.parts}
    for marker in ("reference", "references", "papers", "manuals", "datasheets", "books"):
        if marker in lowered:
            return TrustTier.REFERENCE, f"path:component:{marker}"

    return default, "path:default"
