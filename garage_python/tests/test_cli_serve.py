"""Tests for CLI serve and version commands."""

from __future__ import annotations

from typer.testing import CliRunner

from garage_rag.cli import app

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
