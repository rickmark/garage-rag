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
# The one module that hands document text to LangExtract.
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
    """LangExtract picks a *cloud* backend by regex on ``model_id`` when no
    provider is given (``gemini*`` -> Google, ``gpt-*`` -> OpenAI). The facts
    module must therefore never call ``lx.extract`` with a bare ``model_id``;
    every call names the backend explicitly, and the Ollama config is built
    with the Ollama provider class.
    """

    @staticmethod
    def _calls_to(tree: ast.AST, attr: str) -> list[ast.Call]:
        return [
            node
            for node in ast.walk(tree)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == attr
        ]

    @staticmethod
    def _keywords(call: ast.Call) -> dict[str, ast.expr]:
        return {kw.arg: kw.value for kw in call.keywords if kw.arg is not None}

    def test_every_lx_extract_call_names_its_backend(self) -> None:
        tree = ast.parse(FACTS_MODULE.read_text(encoding="utf-8"), filename=str(FACTS_MODULE))
        calls = self._calls_to(tree, "extract")
        assert calls, "expected at least one lx.extract(...) call in enrich/facts.py"
        for call in calls:
            keywords = self._keywords(call)
            assert "model_id" not in keywords and "model_url" not in keywords, (
                f"line {call.lineno}: lx.extract must not be given a bare model_id -- "
                "LangExtract would route cloud-looking model names to a cloud API"
            )
            assert "model" in keywords or "config" in keywords, (
                f"line {call.lineno}: lx.extract must be given an explicit model= or config="
            )
            assert not any(kw.arg is None for kw in call.keywords), (
                f"line {call.lineno}: **kwargs could smuggle a model_id past this check"
            )

    def test_model_config_pins_the_ollama_provider(self) -> None:
        tree = ast.parse(FACTS_MODULE.read_text(encoding="utf-8"), filename=str(FACTS_MODULE))
        configs = self._calls_to(tree, "ModelConfig")
        assert configs, "expected lx.factory.ModelConfig(...) in enrich/facts.py"
        for call in configs:
            provider = self._keywords(call).get("provider")
            assert provider is not None, f"line {call.lineno}: ModelConfig without an explicit provider"
            # Either the literal, or the module constant that holds it.
            if isinstance(provider, ast.Constant):
                assert provider.value == "OllamaLanguageModel"
            else:
                assert isinstance(provider, ast.Name) and provider.id == "OLLAMA_PROVIDER"

        constants = {
            node.targets[0].id: node.value.value
            for node in ast.walk(tree)
            if isinstance(node, ast.Assign)
            and len(node.targets) == 1
            and isinstance(node.targets[0], ast.Name)
            and isinstance(node.value, ast.Constant)
        }
        assert constants.get("OLLAMA_PROVIDER") == "OllamaLanguageModel"


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
