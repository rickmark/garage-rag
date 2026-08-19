"""Rejecting machine-generated text.

A personal corpus accumulates enormous volumes of text that no human wrote:
``sysdiagnose`` bundles, crash reports, IORegistry dumps, checksum manifests,
build logs. In this corpus a single diagnostic bundle produced ~200k of 262k
chunks -- 76% of the index, none of it writing.

Embedding it is worse than merely wasteful. It costs hours, inflates the index,
and puts near-duplicate log lines into competition with real prose at query time,
so retrieval quality drops as the corpus grows.

Extension and directory rules catch most of it. This module is the content-based
backstop for whatever slips through, using cheap structural signals rather than a
model:

* **Repetition** -- logs restate the same line shape thousands of times, so the
  ratio of distinct lines to total lines collapses.
* **Timestamp prefixes** -- log lines usually begin with a date or time.
* **Hex and base64 density** -- dumps and manifests are mostly non-words.
* **Low alphabetic ratio** -- prose is mostly letters and spaces.

Any single signal produces false positives (a table of contents repeats; a paper
about cryptography contains hex), so a document is rejected only when several
agree.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass

log = logging.getLogger(__name__)

# How much of a document to inspect. Enough to characterize it, cheap on a 32MB
# file.
SAMPLE_BYTES = 64 * 1024
MIN_LINES_TO_JUDGE = 40

_TIMESTAMP_PREFIX = re.compile(
    r"""^\s*(
        \d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}          # 2026-07-27 11:30
      | \d{2}:\d{2}:\d{2}[.,]\d+                  # 11:30:31.163
      | \w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}       # Dec 24 04:09:06
      | \[\d+\.\d+\]                              # [12345.678] kernel style
      | \d{10,13}\b                               # epoch millis
    )""",
    re.VERBOSE,
)

# A long unbroken run of hex or base64: hashes, manifests, memory dumps.
_HEX_RUN = re.compile(r"\b[0-9a-fA-F]{16,}\b")
_BASE64_RUN = re.compile(r"\b[A-Za-z0-9+/]{40,}={0,2}\b")

# Structured-dump shapes: "+-o Root <class IORegistryEntry, id 0x...>", key = {
_DUMP_SHAPE = re.compile(r"^\s*([+|`\-]{1,4}[o\-]|\{|\}|<\w+ |0x[0-9a-f]{6,})")


@dataclass
class QualityVerdict:
    """Why a document was accepted or rejected."""

    machine_generated: bool
    reasons: list[str]
    metrics: dict[str, float]

    @property
    def reason_text(self) -> str:
        return ", ".join(self.reasons) if self.reasons else "looks human-authored"


def _alpha_ratio(text: str) -> float:
    if not text:
        return 0.0
    letters = sum(1 for ch in text if ch.isalpha() or ch.isspace())
    return letters / len(text)


def assess(text: str, *, sample_bytes: int = SAMPLE_BYTES) -> QualityVerdict:
    """Judge whether ``text`` looks machine-generated."""
    sample = text[:sample_bytes]
    lines = [line for line in sample.split("\n") if line.strip()]
    # Dumps can have single lines longer than the byte sample, leaving too few
    # lines to judge. Widen the sample until there are enough, or the text runs out.
    limit = sample_bytes
    while len(lines) < MIN_LINES_TO_JUDGE and limit < len(text):
        limit *= 8
        sample = text[:limit]
        lines = [line for line in sample.split("\n") if line.strip()]

    metrics: dict[str, float] = {}
    reasons: list[str] = []

    if len(lines) < MIN_LINES_TO_JUDGE:
        # Too few lines for the structural signals to mean anything -- but a
        # short file can still be unmistakably machine output. A checksum
        # manifest is 18 lines of pure hex, and skipping the check entirely let
        # exactly that into the index.
        if lines:
            # `match`, not `fullmatch`: checksum manifests are "<hash>  <path>",
            # so the hash leads the line but does not fill it.
            dense = sum(
                1
                for line in lines
                if _HEX_RUN.match(line.strip()) or _BASE64_RUN.match(line.strip())
            ) / len(lines)
            if dense > 0.8:
                return QualityVerdict(
                    True,
                    [f"every line is a hash or blob ({dense:.0%})"],
                    {"lines": float(len(lines)), "hash_lines": round(dense, 3)},
                )
        return QualityVerdict(False, [], {"lines": float(len(lines))})

    total = len(lines)
    distinct_shapes = {re.sub(r"\d+", "#", line[:120]) for line in lines}
    repetition = 1.0 - (len(distinct_shapes) / total)
    timestamped = sum(1 for line in lines if _TIMESTAMP_PREFIX.match(line)) / total
    dumpish = sum(1 for line in lines if _DUMP_SHAPE.match(line)) / total
    hexish = len(_HEX_RUN.findall(sample)) / total
    b64ish = len(_BASE64_RUN.findall(sample)) / total
    alpha = _alpha_ratio(sample)

    metrics.update(
        lines=float(total),
        repetition=round(repetition, 3),
        timestamped=round(timestamped, 3),
        dumpish=round(dumpish, 3),
        hex_per_line=round(hexish, 3),
        base64_per_line=round(b64ish, 3),
        alpha_ratio=round(alpha, 3),
    )

    # Individually suggestive signals.
    if timestamped > 0.45:
        reasons.append(f"timestamp-prefixed lines {timestamped:.0%}")
    if repetition > 0.65:
        reasons.append(f"repetitive line shapes {repetition:.0%}")
    if dumpish > 0.4:
        reasons.append(f"structured-dump lines {dumpish:.0%}")
    if hexish > 0.6:
        reasons.append(f"hex runs {hexish:.2f}/line")
    if b64ish > 0.4:
        reasons.append(f"base64 runs {b64ish:.2f}/line")
    if alpha < 0.55:
        reasons.append(f"low alphabetic ratio {alpha:.0%}")

    # Decisive on its own. Extreme repetition is included because human prose
    # never restates the same line *shape* four times in five -- an ASN.1 dump
    # sits at 0.85 while the prose in this corpus stays below 0.65.
    decisive = timestamped > 0.6 or hexish > 1.0 or dumpish > 0.7 or repetition > 0.82
    # Otherwise require corroboration, so prose about hex is not rejected.
    machine = decisive or len(reasons) >= 2

    return QualityVerdict(machine, reasons, metrics)


def is_machine_generated(text: str) -> bool:
    return assess(text).machine_generated
