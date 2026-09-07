"""Tests for MCP server tools, helpers, transports, and CLI serving."""

from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
from typer.testing import CliRunner

from garage_rag.cli import app
from garage_rag.mcp_server.server import (
    _HOME,
    AuthorInfo,
    AuthorList,
    CorpusStats,
    DocumentResult,
    Hit,
    ModelInfo,
    SearchResult,
    SourceInfo,
    SourceList,
    _as_list,
    _log_startup,
    _tidy,
    is_loopback,
    main,
    rag_get_document,
    rag_list_authors,
    rag_list_sources,
    rag_search,
    rag_stats,
    serve,
)


# ---------------------------------------------------------------------------
# Helper tests
# ---------------------------------------------------------------------------
class TestServerHelpers:
    def test_tidy_replaces_home_prefix(self) -> None:
        assert _tidy(f"{_HOME}/Documents/note.md") == "~/Documents/note.md"
        assert _tidy("/var/data/note.md") == "/var/data/note.md"
        assert _tidy("relative/path.md") == "relative/path.md"

    def test_as_list(self) -> None:
        assert _as_list("reference") == ["reference"]
        assert _as_list(["reference", "authored"]) == ["reference", "authored"]
        assert _as_list(None) is None
        assert _as_list(123) == 123

    @pytest.mark.parametrize(
        ("host", "expected"),
        [
            ("127.0.0.1", True),
            ("::1", True),
            ("localhost", True),
            ("127.0.0.53", True),
            ("0.0.0.0", False),
            ("192.168.1.100", False),
            ("example.com", False),
            ("invalid-host-name", False),
        ],
    )
    def test_is_loopback(self, host: str, expected: bool) -> None:
        assert is_loopback(host) is expected


# ---------------------------------------------------------------------------
# Tool tests
# ---------------------------------------------------------------------------
@dataclass
class MockSearchHit:
    chunk_id: int = 1
    document_id: int = 10
    uri: str = f"{_HOME}/docs/guide.md"
    title: str = "User Guide"
    corpus_class: str = "document"
    trust_tier: str = "authored"
    heading_path: str = "Introduction > Getting Started"
    authors: list[str] = None
    matched_by: str = "hybrid"
    score: float = 0.87654321
    text: str = "Sample content"

    def __post_init__(self):
        if self.authors is None:
            self.authors = ["Rick Mark"]


@dataclass
class MockModelRow:
    slug: str
    dims: int = 768
    stored_dims: int = 768
    storage_kind: str = "halfvec"
    index_kind: str = "hnsw"
    is_default: bool = True
    table_name: str = "emb_bge_base"


class TestMcpTools:
    def test_rag_search_basic(self) -> None:
        mock_hit = MockSearchHit()
        mock_model = MockModelRow(slug="bge-base", is_default=True)

        with patch("garage_rag.mcp_server.server.session_scope") as mock_scope:
            mock_session = MagicMock()
            mock_scope.return_value.__enter__.return_value = mock_session
            with patch("garage_rag.mcp_server.server.run_search", return_value=[mock_hit]) as mock_run_search:
                with patch("garage_rag.mcp_server.server.list_models", return_value=[mock_model]):
                    result = rag_search(
                        query="test query",
                        limit=5,
                        mode="hybrid",
                        corpus_class="document",
                        trust="authored",
                        source="notes",
                        author="Rick",
                    )

                    mock_run_search.assert_called_once_with(
                        mock_session,
                        "test query",
                        limit=5,
                        mode="hybrid",
                        corpus_classes=["document"],
                        trust_tiers=["authored"],
                        sources=["notes"],
                        author="Rick",
                    )
                    assert isinstance(result, SearchResult)
                    assert result.query == "test query"
                    assert result.mode == "hybrid"
                    assert result.model == "bge-base"
                    assert result.count == 1
                    assert len(result.hits) == 1
                    hit = result.hits[0]
                    assert isinstance(hit, Hit)
                    assert hit.chunk_id == 1
                    assert hit.document_id == 10
                    assert hit.location == "~/docs/guide.md"
                    assert hit.title == "User Guide"
                    assert hit.score == 0.876543
                    assert hit.section == "Introduction > Getting Started"
                    assert hit.authors == ["Rick Mark"]

    def test_rag_search_fts_mode_and_no_default_model(self) -> None:
        mock_hit = MockSearchHit()
        with patch("garage_rag.mcp_server.server.session_scope") as mock_scope:
            mock_session = MagicMock()
            mock_scope.return_value.__enter__.return_value = mock_session
            with patch("garage_rag.mcp_server.server.run_search", return_value=[mock_hit]):
                with patch("garage_rag.mcp_server.server.list_models", return_value=[]):
                    result_fts = rag_search(query="fts query", mode="fts")
                    assert result_fts.model == "n/a"

                    result_vec = rag_search(query="vec query", mode="vector")
                    assert result_vec.model == "none"

    def test_rag_get_document_requires_id_or_location(self) -> None:
        with pytest.raises(ValueError, match="pass either document_id or location"):
            rag_get_document()

    def test_rag_get_document_by_id_found(self) -> None:
        doc_obj = MagicMock(
            id=42,
            uri=f"{_HOME}/docs/report.pdf",
            title="Annual Report",
            corpus_class="document",
            trust_tier="reference",
            extractor="pypdf",
            byte_size=1024,
            content="A" * 100,
        )

        with patch("garage_rag.mcp_server.server.session_scope") as mock_scope:
            mock_session = MagicMock()
            mock_scope.return_value.__enter__.return_value = mock_session

            mock_session.query.return_value.filter.return_value.one_or_none.return_value = doc_obj
            mock_session.query.return_value.join.return_value.filter.return_value.order_by.return_value.all.return_value = [
                ("Alice",),
                ("Bob",),
            ]
            mock_session.query.return_value.filter.return_value.scalar.return_value = 5

            result = rag_get_document(document_id=42, max_chars=500)
            assert isinstance(result, DocumentResult)
            assert result.document_id == 42
            assert result.location == "~/docs/report.pdf"
            assert result.title == "Annual Report"
            assert result.corpus_class == "document"
            assert result.trust_tier == "reference"
            assert result.authors == ["Alice", "Bob"]
            assert result.chunk_count == 5
            assert result.truncated is False
            assert len(result.content) == 100

    def test_rag_get_document_by_location_truncated(self) -> None:
        doc_obj = MagicMock(
            id=99,
            uri=f"{_HOME}/code/main.rs",
            title=None,
            corpus_class="code",
            trust_tier="authored",
            extractor="treesitter",
            byte_size=2048,
            content="X" * 1500,
        )

        with patch("garage_rag.mcp_server.server.session_scope") as mock_scope:
            mock_session = MagicMock()
            mock_scope.return_value.__enter__.return_value = mock_session

            mock_session.query.return_value.filter.return_value.one_or_none.return_value = doc_obj
            mock_session.query.return_value.join.return_value.filter.return_value.order_by.return_value.all.return_value = []
            mock_session.query.return_value.filter.return_value.scalar.return_value = 12

            result = rag_get_document(location="~/code/main.rs", max_chars=1000)
            assert result.document_id == 99
            assert result.location == "~/code/main.rs"
            assert result.truncated is True
            assert len(result.content) == 1000

    def test_rag_get_document_not_found(self) -> None:
        with patch("garage_rag.mcp_server.server.session_scope") as mock_scope:
            mock_session = MagicMock()
            mock_scope.return_value.__enter__.return_value = mock_session
            mock_session.query.return_value.filter.return_value.one_or_none.return_value = None

            with pytest.raises(ValueError, match="no such document: 999"):
                rag_get_document(document_id=999)

    def test_rag_list_sources(self) -> None:
        rows = [
            MagicMock(
                slug="vault",
                kind="obsidian",
                cls="document",
                trust="authored",
                root=f"{_HOME}/Obsidian",
                documents=120,
                chunks=450,
            ),
            MagicMock(
                slug="repo",
                kind="git",
                cls="code",
                trust="authored",
                root="/var/repo",
                documents=80,
                chunks=300,
            ),
        ]

        with patch("garage_rag.mcp_server.server.session_scope") as mock_scope:
            mock_session = MagicMock()
            mock_scope.return_value.__enter__.return_value = mock_session

            mock_session.query.return_value.outerjoin.return_value.outerjoin.return_value.group_by.return_value.order_by.return_value.all.return_value = rows

            result = rag_list_sources()
            assert isinstance(result, SourceList)
            assert result.count == 2
            assert len(result.sources) == 2
            src1 = result.sources[0]
            assert isinstance(src1, SourceInfo)
            assert src1.slug == "vault"
            assert src1.root == "~/Obsidian"
            assert src1.documents == 120
            assert src1.chunks == 450

    def test_rag_list_authors(self) -> None:
        rows = [
            MagicMock(
                display_name="Rick Mark",
                is_self=True,
                documents=50,
                identities=["git_email:rickmark@outlook.com", "git_name:Rick Mark"],
            ),
            MagicMock(
                display_name="Ada Lovelace",
                is_self=False,
                documents=10,
                identities=[],
            ),
        ]

        with patch("garage_rag.mcp_server.server.session_scope") as mock_scope:
            mock_session = MagicMock()
            mock_scope.return_value.__enter__.return_value = mock_session

            mock_session.query.return_value.outerjoin.return_value.outerjoin.return_value.group_by.return_value.order_by.return_value.limit.return_value.all.return_value = rows

            result = rag_list_authors(limit=10)
            assert isinstance(result, AuthorList)
            assert result.count == 2
            assert len(result.authors) == 2
            a1 = result.authors[0]
            assert isinstance(a1, AuthorInfo)
            assert a1.name == "Rick Mark"
            assert a1.is_self is True
            assert a1.documents == 50
            assert len(a1.identities) == 2

    def test_rag_stats(self) -> None:
        mock_model = MockModelRow(slug="bge-base", is_default=True, table_name="emb_bge_base")
        overview_data = [{"corpus_class": "document", "trust_tier": "authored", "documents": 10}]

        with patch("garage_rag.mcp_server.server.session_scope") as mock_scope:
            mock_session = MagicMock()
            mock_scope.return_value.__enter__.return_value = mock_session

            mock_session.query.return_value.filter.return_value.scalar.side_effect = [100, 3]
            mock_session.query.return_value.scalar.side_effect = [500, 8]

            with patch("garage_rag.mcp_server.server.corpus_overview", return_value=overview_data):
                with patch("garage_rag.mcp_server.server.list_models", return_value=[mock_model]):
                    with patch("garage_rag.mcp_server.server.count_vectors", return_value=450):
                        stats = rag_stats()
                        assert isinstance(stats, CorpusStats)
                        assert stats.documents == 100
                        assert stats.chunks == 500
                        assert stats.authors == 8
                        assert stats.placeholders_pending == 3
                        assert stats.by_class_and_trust == overview_data
                        assert len(stats.models) == 1
                        m = stats.models[0]
                        assert isinstance(m, ModelInfo)
                        assert m.slug == "bge-base"
                        assert m.vectors == 450
                        assert m.pending == 50


# ---------------------------------------------------------------------------
# Server startup & transport tests
# ---------------------------------------------------------------------------
class TestServerLifecycle:
    def test_log_startup(self, caplog: pytest.LogCaptureFixture) -> None:
        with patch("garage_rag.mcp_server.server.session_scope") as mock_scope:
            mock_session = MagicMock()
            mock_scope.return_value.__enter__.return_value = mock_session
            mock_session.query.return_value.count.return_value = 7

            with caplog.at_level(logging.INFO):
                _log_startup()
                assert "7 sources registered" in caplog.text

    def test_serve_stdio(self) -> None:
        with patch("garage_rag.mcp_server.server._log_startup"):
            with patch("garage_rag.mcp_server.server.mcp.run") as mock_mcp_run:
                serve("stdio")
                mock_mcp_run.assert_called_once_with()

    def test_serve_unsupported_transport(self) -> None:
        with patch("garage_rag.mcp_server.server._log_startup"):
            with pytest.raises(ValueError, match="unsupported transport: 'custom'"):
                serve("custom")

    def test_serve_sse(self) -> None:
        with patch("garage_rag.mcp_server.server._log_startup"):
            with patch("garage_rag.mcp_server.server.mcp.run") as mock_mcp_run:
                serve(
                    "sse",
                    host="127.0.0.1",
                    port=8000,
                    path="/events",
                    allowed_origins=["http://localhost:3000"],
                )
                mock_mcp_run.assert_called_once()
                call_args, call_kwargs = mock_mcp_run.call_args
                assert call_args[0] == "sse"
                assert call_kwargs["host"] == "127.0.0.1"
                assert call_kwargs["port"] == 8000
                assert call_kwargs["sse_path"] == "/events"
                sec = call_kwargs["transport_security"]
                assert sec.enable_dns_rebinding_protection is True
                assert "127.0.0.1:8000" in sec.allowed_hosts
                assert "http://localhost:3000" in sec.allowed_origins

    def test_serve_streamable_http(self) -> None:
        with patch("garage_rag.mcp_server.server._log_startup"):
            with patch("garage_rag.mcp_server.server.mcp.run") as mock_mcp_run:
                serve(
                    "streamable-http",
                    host="127.0.0.1",
                    port=9000,
                    path="/mcp",
                    json_response=True,
                    stateless=True,
                )
                mock_mcp_run.assert_called_once()
                call_args, call_kwargs = mock_mcp_run.call_args
                assert call_args[0] == "streamable-http"
                assert call_kwargs["host"] == "127.0.0.1"
                assert call_kwargs["port"] == 9000
                assert call_kwargs["streamable_http_path"] == "/mcp"
                assert call_kwargs["json_response"] is True
                assert call_kwargs["stateless_http"] is True

    def test_serve_non_loopback_logs_warning(self, caplog: pytest.LogCaptureFixture) -> None:
        with patch("garage_rag.mcp_server.server._log_startup"):
            with patch("garage_rag.mcp_server.server.mcp.run"):
                with caplog.at_level(logging.WARNING):
                    serve("streamable-http", host="0.0.0.0", port=9000)
                    assert "listening on 0.0.0.0, which is reachable from other machines" in caplog.text

    def test_main_calls_serve_stdio(self) -> None:
        with patch("garage_rag.mcp_server.server.serve") as mock_serve:
            main()
            mock_serve.assert_called_once_with("stdio")


# ---------------------------------------------------------------------------
# CLI Command tests for mcp-serve, mcp-status, mcp-uninstall
# ---------------------------------------------------------------------------
runner = CliRunner()


class TestMcpCliCommands:
    def test_mcp_serve_defaults_to_stdio(self) -> None:
        with patch("garage_rag.mcp_server.server.serve") as mock_serve:
            result = runner.invoke(app, ["mcp-serve"])
            assert result.exit_code == 0
            mock_serve.assert_called_once_with("stdio")

    def test_mcp_serve_conflicting_transports(self) -> None:
        result = runner.invoke(app, ["mcp-serve", "--stdio", "--http"])
        assert result.exit_code != 0
        assert "choose one of --stdio, --http, or --sse" in result.output

    def test_mcp_serve_remote_without_allow_remote_fails(self) -> None:
        result = runner.invoke(app, ["mcp-serve", "--http", "--host", "0.0.0.0"])
        assert result.exit_code != 0
        assert "is not a loopback address" in result.output
        assert "--allow-remote" in result.output

    def test_mcp_serve_remote_with_allow_remote_succeeds(self) -> None:
        with patch("garage_rag.mcp_server.server.serve") as mock_serve:
            result = runner.invoke(
                app,
                [
                    "mcp-serve",
                    "--http",
                    "--host",
                    "0.0.0.0",
                    "--port",
                    "8765",
                    "--path",
                    "/custom-mcp",
                    "--allow-remote",
                    "--json-response",
                    "--stateless",
                ],
            )
            assert result.exit_code == 0
            mock_serve.assert_called_once_with(
                "streamable-http",
                host="0.0.0.0",
                port=8765,
                path="/custom-mcp",
                allowed_origins=[],
                json_response=True,
                stateless=True,
            )

    def test_mcp_serve_sse_mode(self) -> None:
        with patch("garage_rag.mcp_server.server.serve") as mock_serve:
            result = runner.invoke(
                app,
                ["mcp-serve", "--sse", "--host", "127.0.0.1", "--port", "8888"],
            )
            assert result.exit_code == 0
            mock_serve.assert_called_once_with(
                "sse",
                host="127.0.0.1",
                port=8888,
                path="/mcp",
                allowed_origins=[],
                json_response=False,
                stateless=False,
            )

    def test_mcp_status_output(self) -> None:
        result = runner.invoke(app, ["mcp-status"])
        assert result.exit_code == 0
        assert "server command:" in result.output
        assert "claude-desktop" in result.output

    def test_mcp_uninstall_unknown_target_fails(self) -> None:
        result = runner.invoke(app, ["mcp-uninstall", "--target", "nonexistent"])
        assert result.exit_code != 0
        assert "unknown target" in result.output

    def test_mcp_uninstall_not_configured_shows_message(self, tmp_path: Path) -> None:
        cfg = tmp_path / "config.json"
        cfg.write_text("{}", encoding="utf-8")
        result = runner.invoke(app, ["mcp-uninstall", "--path", str(cfg)])
        assert result.exit_code == 0
        assert "was not configured" in result.output
