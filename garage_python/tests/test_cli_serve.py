"""Tests for CLI serve and version commands."""

from __future__ import annotations

from typer.testing import CliRunner

from garage_rag.cli import app, main_cli

runner = CliRunner()


def test_cli_version():
    result = runner.invoke(app, ["version"])
    assert result.exit_code == 0
    assert "garage v" in result.output


def test_cli_serve_help():
    result = runner.invoke(app, ["serve", "--help"])
    assert result.exit_code == 0
    assert "--host" in result.output
    assert "--port" in result.output
    assert "--xpc" in result.output
    assert "--service-name" in result.output
    assert "--team-id" in result.output
    assert "--bundle-id" in result.output


def test_main_cli_returns_exit_code(monkeypatch):
    import sys

    monkeypatch.setattr(sys, "argv", ["garage", "version"])
    code = main_cli()
    assert code == 0

    monkeypatch.setattr(sys, "argv", ["garage", "--help"])
    code = main_cli()
    assert code == 0


def test_cli_ingest_no_sources(monkeypatch):
    from unittest.mock import MagicMock, patch

    mock_session = MagicMock()
    mock_session.query.return_value.order_by.return_value.all.return_value = []
    mock_factory = MagicMock()
    mock_factory.return_value.__enter__.return_value = mock_session

    with patch("garage_rag.db.engine.get_session_factory", return_value=mock_factory):
        result = runner.invoke(app, ["ingest"])
        assert result.exit_code == 0
        assert "no sources registered to ingest" in result.output


def test_cli_ingest_missing_source(monkeypatch):
    from unittest.mock import MagicMock, patch

    mock_session = MagicMock()
    mock_session.query.return_value.filter_by.return_value.one_or_none.return_value = None
    mock_factory = MagicMock()
    mock_factory.return_value.__enter__.return_value = mock_session

    with patch("garage_rag.db.engine.get_session_factory", return_value=mock_factory):
        result = runner.invoke(app, ["ingest", "--source", "non-existent"])
        assert result.exit_code == 1
        assert "no such source" in result.output
