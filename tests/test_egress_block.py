"""The privacy guarantee: communications never reach a cloud API.

These tests exist because "we don't send private messages to the cloud" is worth
nothing as a comment. Each level of the guard is asserted independently, so
removing any one of them fails the suite.
"""

from __future__ import annotations

import ast
from pathlib import Path

import pytest

from garage_rag.db.models import CorpusClass
from garage_rag.enrich.egress import (
    EgressBlocked,
    EgressRequest,
    assert_egress_allowed,
)

SRC = Path(__file__).resolve().parent.parent / "src" / "garage_rag"
# The only module permitted to touch the Anthropic SDK.
EGRESS_MODULE = SRC / "enrich" / "egress.py"


class TestTypeLevelBlock:
    """Level 2: the request type refuses to represent a forbidden send."""

    def test_communication_cannot_be_constructed(self) -> None:
        with pytest.raises(EgressBlocked, match="communications may never"):
            EgressRequest(
                corpus_class=CorpusClass.COMMUNICATION,
                purpose="image-ocr",
                source_allows_cloud=True,
            )

    def test_communication_blocked_even_when_source_allows(self) -> None:
        """The class check must precede, and override, the source flag."""
        with pytest.raises(EgressBlocked):
            EgressRequest(
                corpus_class=CorpusClass.COMMUNICATION,
                purpose="anything",
                source_allows_cloud=True,
                max_tokens=10,
            )

    @pytest.mark.parametrize(
        "klass", [CorpusClass.DOCUMENT, CorpusClass.CODE]
    )
    def test_other_classes_allowed_when_source_permits(self, klass: CorpusClass) -> None:
        request = EgressRequest(
            corpus_class=klass, purpose="image-ocr", source_allows_cloud=True
        )
        assert request.corpus_class is klass

    @pytest.mark.parametrize(
        "klass", [CorpusClass.DOCUMENT, CorpusClass.CODE, CorpusClass.COMMUNICATION]
    )
    def test_source_flag_is_required_for_every_class(self, klass: CorpusClass) -> None:
        """Level 3: no class egresses from a source that has not opted in."""
        with pytest.raises(EgressBlocked):
            EgressRequest(
                corpus_class=klass, purpose="image-ocr", source_allows_cloud=False
            )

    def test_assert_helper_matches_the_type(self) -> None:
        with pytest.raises(EgressBlocked):
            assert_egress_allowed(CorpusClass.COMMUNICATION)
        assert_egress_allowed(CorpusClass.DOCUMENT)
        assert_egress_allowed(CorpusClass.CODE)


class TestChokepoint:
    """Level 1: exactly one module may import the Anthropic SDK."""

    @staticmethod
    def _imports_anthropic(path: Path) -> bool:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                if any(a.name.split(".")[0] == "anthropic" for a in node.names):
                    return True
            elif isinstance(node, ast.ImportFrom):
                if (node.module or "").split(".")[0] == "anthropic":
                    return True
        return False

    def test_only_egress_module_imports_anthropic(self) -> None:
        offenders = [
            path.relative_to(SRC).as_posix()
            for path in SRC.rglob("*.py")
            if path != EGRESS_MODULE and self._imports_anthropic(path)
        ]
        assert not offenders, (
            "anthropic must only be imported by enrich/egress.py, the single "
            f"egress chokepoint; found in: {offenders}"
        )

    def test_egress_module_exists_and_is_the_chokepoint(self) -> None:
        assert EGRESS_MODULE.is_file()
        assert self._imports_anthropic(EGRESS_MODULE)

    def test_no_module_constructs_a_client_outside_egress(self) -> None:
        """Guards against a second client sneaking in via a local import."""
        offenders = []
        for path in SRC.rglob("*.py"):
            if path == EGRESS_MODULE:
                continue
            body = path.read_text(encoding="utf-8")
            if "Anthropic(" in body or "AsyncAnthropic(" in body:
                offenders.append(path.relative_to(SRC).as_posix())
        assert not offenders, f"Anthropic client constructed outside egress: {offenders}"


class TestCommunicationSourcesStayLocal:
    """Level 3, at the schema level rather than in Python."""

    def test_schema_defaults_cloud_enrichment_off(self) -> None:
        sql = (SRC.parent.parent / "sql" / "002_core.sql").read_text()
        assert "allow_cloud_enrichment  boolean     NOT NULL DEFAULT false" in sql, (
            "sources.allow_cloud_enrichment must default to false"
        )

    def test_cli_refuses_cloud_on_communication_sources(self) -> None:
        cli = (SRC / "cli.py").read_text()
        assert "CorpusClass.COMMUNICATION" in cli
        assert "may never enable cloud enrichment" in cli
