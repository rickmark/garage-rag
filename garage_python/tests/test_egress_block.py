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
# The one module that hands document text to (vendored) LangExtract.
FACTS_MODULE = SRC / "enrich" / "facts.py"


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

    @pytest.mark.parametrize("klass", [CorpusClass.DOCUMENT, CorpusClass.CODE])
    def test_other_classes_allowed_when_source_permits(self, klass: CorpusClass) -> None:
        request = EgressRequest(corpus_class=klass, purpose="image-ocr", source_allows_cloud=True)
        assert request.corpus_class is klass

    @pytest.mark.parametrize("klass", [CorpusClass.DOCUMENT, CorpusClass.CODE, CorpusClass.COMMUNICATION])
    def test_source_flag_is_required_for_every_class(self, klass: CorpusClass) -> None:
        """Level 3: no class egresses from a source that has not opted in."""
        with pytest.raises(EgressBlocked):
            EgressRequest(corpus_class=klass, purpose="image-ocr", source_allows_cloud=False)

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
            if isinstance(node, ast.Import) and any(a.name.split(".")[0] == "anthropic" for a in node.names):
                return True
            if isinstance(node, ast.ImportFrom) and (node.module or "").split(".")[0] == "anthropic":
                return True
        return False

    def test_only_egress_module_imports_anthropic(self) -> None:
        offenders = [
            path.relative_to(SRC).as_posix()
            for path in SRC.rglob("*.py")
            if path != EGRESS_MODULE and self._imports_anthropic(path)
        ]
        assert not offenders, (
            f"anthropic must only be imported by enrich/egress.py, the single egress chokepoint; found in: {offenders}"
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


class TestFactExtractionStaysLocal:
    """Upstream LangExtract picks a *cloud* backend by regex on ``model_id``
    (``gemini*`` -> Google, ``gpt-*`` -> OpenAI). Only the local part is vendored
    (``enrich/langextract``); these tests keep it that way: no module imports the
    upstream package, the vendored copy has no provider routing, and every
    extraction runs on a model built from one of the two local providers.
    """

    LOCAL_MODELS = {"OllamaLanguageModel", "LlamaXPCLanguageModel"}

    @staticmethod
    def _imports_upstream_langextract(path: Path) -> bool:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        for node in ast.walk(tree):
            if isinstance(node, ast.Import) and any(a.name.split(".")[0] == "langextract" for a in node.names):
                return True
            if (
                isinstance(node, ast.ImportFrom)
                and node.level == 0
                and (node.module or "").split(".")[0] == "langextract"
            ):
                return True
        return False

    def test_no_module_imports_upstream_langextract(self) -> None:
        offenders = [p.relative_to(SRC).as_posix() for p in SRC.rglob("*.py") if self._imports_upstream_langextract(p)]
        assert not offenders, f"import garage_rag.enrich.langextract, not upstream langextract: {offenders}"

    def test_vendored_langextract_has_no_provider_routing(self) -> None:
        vendored = SRC / "enrich" / "langextract"
        names = {p.stem for p in vendored.rglob("*.py")}
        assert not names & {"factory", "providers", "router", "gemini", "openai", "io"}
        source = "\n".join(p.read_text(encoding="utf-8") for p in vendored.rglob("*.py"))
        assert "model_id" not in source.split("def extract(")[1].split(")")[0]

    def test_every_extract_call_is_given_a_local_model(self) -> None:
        tree = ast.parse(FACTS_MODULE.read_text(encoding="utf-8"), filename=str(FACTS_MODULE))
        calls = [
            node
            for node in ast.walk(tree)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "extract"
        ]
        assert calls, "expected an lx.extract(...) call in enrich/facts.py"
        for call in calls:
            keywords = {kw.arg for kw in call.keywords}
            assert "model" in keywords, f"line {call.lineno}: lx.extract must be given model="
            assert None not in keywords, f"line {call.lineno}: **kwargs could smuggle other options in"
        constructed = {
            node.func.id
            for node in ast.walk(tree)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id.endswith("LanguageModel")
        }
        assert constructed == self.LOCAL_MODELS


class TestCommunicationSourcesStayLocal:
    """Level 3, at the schema level rather than in Python."""

    def test_schema_defaults_cloud_enrichment_off(self) -> None:
        sql_path = SRC.parent.parent / "sql" / "003_core.sql"
        if not sql_path.exists():
            sql_path = SRC.parent.parent.parent / "data" / "sql" / "003_core.sql"
        sql = sql_path.read_text()
        assert "allow_cloud_enrichment  boolean     NOT NULL DEFAULT false" in sql, (
            "sources.allow_cloud_enrichment must default to false"
        )

    def test_source_operations_refuse_cloud_on_communication_sources(self) -> None:
        """Level 3 lives in ops/sources.py, shared by `garage add-source`, `garage sync`
        and the AddSource/Sync RPCs, so no entry point can register such a source."""
        ops = (SRC / "ops" / "sources.py").read_text()
        assert "CorpusClass.COMMUNICATION" in ops
        assert "may never enable cloud enrichment" in ops

    def test_add_source_refuses_before_touching_the_database(self, tmp_path: Path) -> None:
        from garage_rag.ops.sources import SourceArgumentError, add_source

        with pytest.raises(SourceArgumentError, match="may never enable cloud enrichment"):
            add_source("sms", tmp_path, corpus_class="communication", allow_cloud_enrichment=True)

    def test_cli_add_source_refuses(self, tmp_path: Path) -> None:
        from typer.testing import CliRunner

        from garage_rag.cli import app

        result = CliRunner().invoke(
            app,
            ["add-source", "sms", str(tmp_path), "--class", "communication", "--allow-cloud-enrichment"],
        )
        assert result.exit_code != 0
        # Rich wraps the error inside a box; compare the words, not the layout.
        assert "may never enable cloud enrichment" in " ".join(result.output.replace("│", " ").split())

    def test_sync_refuses_a_declared_communication_source_with_cloud(self, tmp_path: Path) -> None:
        from garage_rag.config import Settings, SourceSpec
        from garage_rag.ops.sources import SourceArgumentError, sync_sources

        spec = SourceSpec(slug="sms", root=str(tmp_path), **{"class": "communication"}, allow_cloud_enrichment=True)
        with pytest.raises(SourceArgumentError, match="may never enable cloud enrichment"):
            sync_sources(settings=Settings(sources=[spec]))


def test_guards_do_not_need_a_database_driver() -> None:
    """The egress checks must hold wherever the code runs, libpq or not.

    Run in a fresh interpreter that refuses to import psycopg: the modules the
    level-3 guard and search live in must still import, so the guard's tests
    (and the guard) never depend on a database driver being installed.
    """
    import subprocess
    import sys

    script = """
import sys

class BlockPsycopg:
    def find_spec(self, name, path=None, target=None):
        if name.split(".")[0] in ("psycopg", "psycopg_c", "psycopg_binary"):
            raise ImportError(f"{name} blocked for this test")
        return None

sys.meta_path.insert(0, BlockPsycopg())
import garage_rag.ops.sources
import garage_rag.search.hybrid
import garage_rag.enrich.egress
import garage_rag.cli
print("ok")
"""
    result = subprocess.run([sys.executable, "-c", script], capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "ok"
