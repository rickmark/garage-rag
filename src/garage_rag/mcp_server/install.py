"""Registering this server in an MCP client's configuration.

Every client that reads a JSON config uses the same envelope:

.. code-block:: json

    {"mcpServers": {"<name>": {"command": "...", "args": [], "env": {}}}}

They differ only in *where* that file lives, so the client-specific part is a
lookup table and the merge logic is shared.

Two properties matter more than convenience here, because these are files the
user owns and did not ask us to rewrite:

* **Merge, never replace.** Unrelated servers and unrelated top-level keys are
  preserved. Claude Desktop's config, for instance, holds ``preferences``
  alongside ``mcpServers``; clobbering it would lose real settings.
* **Back up, and write atomically.** The existing file is copied aside first, and
  the new content is written to a temporary file in the same directory then
  renamed, so an interrupted write cannot leave a truncated config that stops the
  client from starting at all.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import sys
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

DEFAULT_SERVER_NAME = "garage-rag"


@dataclass(frozen=True)
class ClientTarget:
    """Where one MCP client keeps its server configuration."""

    key: str
    label: str
    path: Path
    # Project-scoped files are usually committed, so an absolute interpreter path
    # in them is a portability problem worth warning about.
    project_scoped: bool = False
    note: str = ""


def client_targets(project_dir: Path | None = None) -> dict[str, ClientTarget]:
    """Known client config locations, keyed by ``--target`` value."""
    home = Path.home()
    project = (project_dir or Path.cwd()).resolve()
    support = home / "Library" / "Application Support"

    targets = [
        ClientTarget(
            key="project",
            label="Claude Code (this project)",
            path=project / ".mcp.json",
            project_scoped=True,
            note="committed with the repo; shared with anyone who clones it",
        ),
        ClientTarget(
            key="claude-desktop",
            label="Claude Desktop",
            path=support / "Claude" / "claude_desktop_config.json",
            note="restart Claude Desktop to pick up changes",
        ),
        ClientTarget(
            key="lmstudio",
            label="LM Studio",
            path=home / ".lmstudio" / "mcp.json",
        ),
        ClientTarget(
            key="cursor",
            label="Cursor",
            path=home / ".cursor" / "mcp.json",
        ),
        ClientTarget(
            key="vscode",
            label="VS Code (this project)",
            path=project / ".vscode" / "mcp.json",
            project_scoped=True,
        ),
    ]
    return {t.key: t for t in targets}


def server_command(config_path: Path | None = None) -> tuple[str, list[str]]:
    """The command an MCP client should run to start this server.

    A client launches the server from an arbitrary working directory, where the
    config search order would find nothing. ``--config`` is therefore passed
    explicitly with an absolute path -- which is why the ``garage`` entry point
    is preferred over ``garage-mcp``: it accepts the flag.

    ``sys.executable`` is used **unresolved** on purpose. Inside a virtualenv it
    is already the right path (``.venv/bin/python``); resolving it follows the
    symlink out to the base interpreter, which has none of this project's
    packages installed and fails with ModuleNotFoundError at launch.
    """
    interpreter = Path(sys.executable)

    # `--config` is a global option on the Typer callback, so it must precede the
    # subcommand. Placed after `mcp-serve` it fails with "No such option".
    head: list[str] = []
    if config_path is not None:
        head = ["--config", str(config_path.expanduser().resolve())]

    garage = interpreter.parent / "garage"
    if garage.is_file() and os.access(garage, os.X_OK):
        return str(garage), [*head, "mcp-serve", "--stdio"]

    console_script = interpreter.parent / "garage-mcp"
    if console_script.is_file() and os.access(console_script, os.X_OK) and not head:
        return str(console_script), []

    return str(interpreter), [
        "-m",
        "garage_rag.cli",
        *head,
        "mcp-serve",
        "--stdio",
    ]


def http_url(host: str, port: int, path: str) -> str:
    """The URL a client should connect to for the HTTP transport."""
    route = path if path.startswith("/") else f"/{path}"
    # IPv6 literals need brackets in a URL authority.
    authority = f"[{host}]" if ":" in host else host
    return f"http://{authority}:{port}{route}"


def server_entry(
    *,
    config_path: Path | None = None,
    extra_env: dict[str, str] | None = None,
    url: str | None = None,
    transport: str = "http",
) -> dict[str, Any]:
    """The JSON object describing this server.

    Two shapes, because the two transports are configured differently: a stdio
    server is a command the client *spawns*, whereas an HTTP server is a URL the
    client *connects to* — and something else is responsible for keeping it
    running.
    """
    if url is not None:
        return {"type": transport, "url": url}

    command, args = server_command(config_path)
    entry: dict[str, Any] = {"command": command, "args": args}
    # Only present if a caller explicitly asks for it; the server itself needs
    # no environment.
    if extra_env:
        entry["env"] = dict(extra_env)
    return entry


def _read_config(path: Path) -> dict[str, Any]:
    """Load an existing config, or return an empty one.

    A malformed file is an error rather than something to silently overwrite --
    it may be hand-edited and worth preserving.
    """
    if not path.is_file():
        return {}
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(f"cannot read {path}: {exc}") from exc
    if not text.strip():
        return {}
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise RuntimeError(
            f"{path} is not valid JSON ({exc}); fix or move it before installing"
        ) from exc
    if not isinstance(data, dict):
        raise RuntimeError(f"{path} does not contain a JSON object")
    return data


def _backup(path: Path) -> Path | None:
    if not path.is_file():
        return None
    stamp = datetime.now(tz=UTC).strftime("%Y%m%d%H%M%S")
    backup = path.with_suffix(path.suffix + f".bak-{stamp}")
    shutil.copy2(path, backup)
    return backup


def _write_atomic(path: Path, data: dict[str, Any]) -> None:
    """Write JSON via a temp file in the same directory, then rename.

    Same directory so the rename stays on one filesystem and is therefore atomic;
    a partial write can never leave the client unable to start.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".tmp")
    payload = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    temp.write_text(payload, encoding="utf-8")
    temp.replace(path)


@dataclass
class InstallResult:
    target: ClientTarget
    server_name: str
    entry: dict[str, Any]
    path: Path
    created_file: bool
    replaced_entry: bool
    backup: Path | None
    other_servers: list[str]
    dry_run: bool


def install(
    target: ClientTarget,
    *,
    server_name: str = DEFAULT_SERVER_NAME,
    config_path: Path | None = None,
    extra_env: dict[str, str] | None = None,
    url: str | None = None,
    transport: str = "http",
    force: bool = False,
    dry_run: bool = False,
) -> InstallResult:
    """Merge this server into ``target``'s config.

    Raises :class:`FileExistsError` if ``server_name`` is already configured and
    ``force`` is not set, so an existing entry is never silently rewritten.
    """
    config = _read_config(target.path)
    servers = config.get("mcpServers")
    if servers is None:
        servers = {}
    elif not isinstance(servers, dict):
        raise RuntimeError(f"{target.path}: 'mcpServers' is not an object")

    replaced = server_name in servers
    if replaced and not force:
        raise FileExistsError(
            f"{server_name!r} is already configured in {target.path}; "
            "pass --force to overwrite it"
        )

    entry = server_entry(
        config_path=config_path, extra_env=extra_env, url=url, transport=transport
    )
    others = sorted(k for k in servers if k != server_name)

    result = InstallResult(
        target=target,
        server_name=server_name,
        entry=entry,
        path=target.path,
        created_file=not target.path.is_file(),
        replaced_entry=replaced,
        backup=None,
        other_servers=others,
        dry_run=dry_run,
    )
    if dry_run:
        return result

    result.backup = _backup(target.path)
    # Preserve every other key: Claude Desktop keeps `preferences` here.
    servers[server_name] = entry
    config["mcpServers"] = servers
    _write_atomic(target.path, config)
    log.info("registered %s in %s", server_name, target.path)
    return result


def uninstall(
    target: ClientTarget,
    *,
    server_name: str = DEFAULT_SERVER_NAME,
    dry_run: bool = False,
) -> bool:
    """Remove this server from ``target``'s config. Returns True if removed."""
    config = _read_config(target.path)
    servers = config.get("mcpServers")
    if not isinstance(servers, dict) or server_name not in servers:
        return False
    if dry_run:
        return True

    _backup(target.path)
    del servers[server_name]
    config["mcpServers"] = servers
    _write_atomic(target.path, config)
    log.info("removed %s from %s", server_name, target.path)
    return True


def installed_in(
    target: ClientTarget, *, server_name: str = DEFAULT_SERVER_NAME
) -> bool:
    try:
        config = _read_config(target.path)
    except RuntimeError:
        return False
    servers = config.get("mcpServers")
    return isinstance(servers, dict) and server_name in servers
