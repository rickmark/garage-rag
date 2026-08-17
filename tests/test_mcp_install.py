"""Registering the server in a client config.

These write to files the user owns and did not ask us to rewrite, so the
non-negotiable behaviours are: merge rather than replace, never silently
overwrite an existing entry, and never leave a truncated file behind.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

from garage_rag.mcp_server.install import (
    ClientTarget,
    client_targets,
    install,
    installed_in,
    server_command,
    server_entry,
    uninstall,
)


@pytest.fixture
def target(tmp_path: Path) -> ClientTarget:
    return ClientTarget(key="test", label="test client", path=tmp_path / "mcp.json")


def _read(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


class TestServerCommand:
    def test_uses_unresolved_sys_executable(self) -> None:
        """Regression: resolving sys.executable escapes the virtualenv.

        Inside a venv, sys.executable is already correct. Following the symlink
        lands on the base interpreter, which has none of this project's packages
        and dies with ModuleNotFoundError when a client launches it.
        """
        command, _args = server_command()
        venv_dir = Path(sys.executable).parent
        assert Path(command).parent == venv_dir

    def test_command_is_absolute(self) -> None:
        """A client launches with its own PATH, which excludes this venv."""
        command, _ = server_command()
        assert Path(command).is_absolute()

    def test_module_form_names_the_server_module(self) -> None:
        command, args = server_command()
        if args:
            assert args == ["-m", "garage_rag.mcp_server.server"]
        else:
            assert Path(command).name == "garage-mcp"


class TestServerEntry:
    def test_references_env_file_rather_than_copying_values(self, tmp_path: Path) -> None:
        env = tmp_path / ".env"
        env.write_text("GARAGE_SELF_NAME=X\n")
        entry = server_entry(env_file=env)
        assert entry["env"]["GARAGE_ENV_FILE"] == str(env.resolve())
        # The point: settings are not duplicated into the client config, so
        # editing .env takes effect without re-installing.
        assert "GARAGE_SELF_NAME" not in entry["env"]

    def test_no_env_key_when_nothing_to_set(self) -> None:
        assert "env" not in server_entry()

    def test_extra_env_is_merged(self, tmp_path: Path) -> None:
        entry = server_entry(env_file=tmp_path / ".env", extra_env={"FOO": "bar"})
        assert entry["env"]["FOO"] == "bar"


class TestInstallMerge:
    def test_creates_file_when_absent(self, target: ClientTarget) -> None:
        result = install(target)
        assert result.created_file
        assert _read(target.path)["mcpServers"]["garage-rag"]["command"]

    def test_preserves_other_servers(self, target: ClientTarget) -> None:
        target.path.write_text(
            json.dumps({"mcpServers": {"other": {"command": "/bin/true", "args": []}}})
        )
        install(target)
        servers = _read(target.path)["mcpServers"]
        assert set(servers) == {"other", "garage-rag"}
        assert servers["other"]["command"] == "/bin/true"

    def test_preserves_unrelated_top_level_keys(self, target: ClientTarget) -> None:
        """Claude Desktop keeps `preferences` in this file; losing it is real damage."""
        target.path.write_text(
            json.dumps({"preferences": {"theme": "dark"}, "coworkUserFilesPath": "/x"})
        )
        install(target)
        data = _read(target.path)
        assert data["preferences"] == {"theme": "dark"}
        assert data["coworkUserFilesPath"] == "/x"
        assert "garage-rag" in data["mcpServers"]

    def test_refuses_to_overwrite_without_force(self, target: ClientTarget) -> None:
        install(target)
        with pytest.raises(FileExistsError, match="already configured"):
            install(target)

    def test_force_overwrites_and_backs_up(self, target: ClientTarget) -> None:
        target.path.write_text(
            json.dumps({"mcpServers": {"garage-rag": {"command": "stale", "args": []}}})
        )
        result = install(target, force=True)
        assert result.replaced_entry
        assert result.backup is not None and result.backup.is_file()
        assert _read(target.path)["mcpServers"]["garage-rag"]["command"] != "stale"
        # The backup still holds the old value.
        assert _read(result.backup)["mcpServers"]["garage-rag"]["command"] == "stale"

    def test_dry_run_changes_nothing(self, target: ClientTarget) -> None:
        result = install(target, dry_run=True)
        assert result.dry_run
        assert not target.path.exists()

    def test_dry_run_reports_servers_it_would_preserve(self, target: ClientTarget) -> None:
        target.path.write_text(json.dumps({"mcpServers": {"a": {}, "b": {}}}))
        result = install(target, dry_run=True)
        assert result.other_servers == ["a", "b"]

    def test_custom_server_name(self, target: ClientTarget) -> None:
        install(target, server_name="corpus")
        assert "corpus" in _read(target.path)["mcpServers"]

    def test_malformed_json_is_an_error_not_an_overwrite(self, target: ClientTarget) -> None:
        """A hand-edited file may be worth preserving; do not clobber it."""
        target.path.write_text("{ this is not json")
        with pytest.raises(RuntimeError, match="not valid JSON"):
            install(target)
        assert target.path.read_text() == "{ this is not json"

    def test_empty_file_is_treated_as_empty_config(self, target: ClientTarget) -> None:
        target.path.write_text("   \n")
        install(target)
        assert "garage-rag" in _read(target.path)["mcpServers"]

    def test_non_object_mcpservers_is_rejected(self, target: ClientTarget) -> None:
        target.path.write_text(json.dumps({"mcpServers": ["nope"]}))
        with pytest.raises(RuntimeError, match="not an object"):
            install(target)

    def test_creates_parent_directories(self, tmp_path: Path) -> None:
        nested = ClientTarget("t", "t", tmp_path / "a" / "b" / "mcp.json")
        install(nested)
        assert nested.path.is_file()

    def test_output_is_valid_indented_json(self, target: ClientTarget) -> None:
        install(target)
        text = target.path.read_text()
        assert text.endswith("\n")
        assert "\n  " in text  # indented, so it stays hand-editable
        json.loads(text)

    def test_no_temp_file_left_behind(self, target: ClientTarget) -> None:
        install(target)
        assert not list(target.path.parent.glob("*.tmp"))


class TestUninstall:
    def test_removes_only_our_entry(self, target: ClientTarget) -> None:
        target.path.write_text(json.dumps({"mcpServers": {"other": {"command": "x"}}}))
        install(target)
        assert uninstall(target)
        servers = _read(target.path)["mcpServers"]
        assert set(servers) == {"other"}

    def test_returns_false_when_absent(self, target: ClientTarget) -> None:
        target.path.write_text(json.dumps({"mcpServers": {}}))
        assert not uninstall(target)

    def test_missing_file_is_not_an_error(self, target: ClientTarget) -> None:
        assert not uninstall(target)

    def test_installed_in_roundtrip(self, target: ClientTarget) -> None:
        assert not installed_in(target)
        install(target)
        assert installed_in(target)
        uninstall(target)
        assert not installed_in(target)


class TestClientTargets:
    def test_known_targets_present(self) -> None:
        keys = set(client_targets())
        assert {"project", "claude-desktop", "lmstudio", "cursor", "vscode"} <= keys

    def test_project_target_is_scoped_to_the_given_directory(self, tmp_path: Path) -> None:
        targets = client_targets(project_dir=tmp_path)
        assert targets["project"].path == tmp_path.resolve() / ".mcp.json"
        assert targets["project"].project_scoped

    def test_user_level_targets_are_absolute(self) -> None:
        for key in ("claude-desktop", "lmstudio", "cursor"):
            assert client_targets()[key].path.is_absolute()


class TestHttpEntry:
    """The HTTP form is a URL the client connects to, not a command it spawns."""

    def test_url_entry_shape(self) -> None:
        entry = server_entry(url="http://127.0.0.1:8787/mcp")
        assert entry == {"type": "http", "url": "http://127.0.0.1:8787/mcp"}

    def test_url_entry_has_no_command_or_env(self) -> None:
        """Nothing is spawned, so a command or env would be misleading."""
        entry = server_entry(url="http://127.0.0.1:8787/mcp", env_file=Path("/tmp/.env"))
        assert "command" not in entry
        assert "env" not in entry

    def test_transport_override(self) -> None:
        entry = server_entry(url="http://x/mcp", transport="sse")
        assert entry["type"] == "sse"

    def test_install_writes_url_entry(self, target: ClientTarget) -> None:
        install(target, url="http://127.0.0.1:8787/mcp")
        entry = _read(target.path)["mcpServers"]["garage-rag"]
        assert entry["url"] == "http://127.0.0.1:8787/mcp"

    def test_switching_stdio_to_http_needs_force(self, target: ClientTarget) -> None:
        install(target)
        with pytest.raises(FileExistsError):
            install(target, url="http://127.0.0.1:8787/mcp")
        install(target, url="http://127.0.0.1:8787/mcp", force=True)
        entry = _read(target.path)["mcpServers"]["garage-rag"]
        assert "command" not in entry


class TestHttpUrl:
    @pytest.mark.parametrize(
        ("host", "port", "path", "expected"),
        [
            ("127.0.0.1", 8787, "/mcp", "http://127.0.0.1:8787/mcp"),
            # A route without a leading slash must not produce a bad URL.
            ("127.0.0.1", 8787, "mcp", "http://127.0.0.1:8787/mcp"),
            ("localhost", 9000, "/rag", "http://localhost:9000/rag"),
            # IPv6 literals need brackets in the authority.
            ("::1", 8787, "/mcp", "http://[::1]:8787/mcp"),
        ],
    )
    def test_url_construction(self, host: str, port: int, path: str, expected: str) -> None:
        from garage_rag.mcp_server.install import http_url

        assert http_url(host, port, path) == expected


class TestLoopbackDetection:
    """Gates whether binding an address needs an explicit opt-in."""

    @pytest.mark.parametrize("host", ["127.0.0.1", "::1", "localhost", "127.0.0.53"])
    def test_loopback(self, host: str) -> None:
        from garage_rag.mcp_server.server import is_loopback

        assert is_loopback(host)

    @pytest.mark.parametrize(
        "host", ["0.0.0.0", "192.168.1.10", "10.0.0.5", "example.com", "::"]
    )
    def test_not_loopback(self, host: str) -> None:
        """0.0.0.0 binds every interface, so it is emphatically not loopback."""
        from garage_rag.mcp_server.server import is_loopback

        assert not is_loopback(host)

    def test_unknown_hostname_treated_as_remote(self) -> None:
        """Fail closed: an unclassifiable name requires the explicit opt-in."""
        from garage_rag.mcp_server.server import is_loopback

        assert not is_loopback("some-host.local")
