"""The per-launch shared token that guards the GarageService gRPC port.

The app generates a random token each launch and hands it to the gRPC server and
its XPC workers as ``GARAGE_GRPC_TOKEN``. When it is set, the server rejects any
call whose ``x-garage-token`` metadata does not match, and every client in this
package sends it. When it is unset (``garage grpc serve`` for developers, the tests),
nothing changes.

This is a stopgap until the app talks to the server over XPC with code-signing
checks and no network socket at all; the whole module goes away then.
"""

from __future__ import annotations

import hmac
import os

TOKEN_ENV = "GARAGE_GRPC_TOKEN"
METADATA_KEY = "x-garage-token"

# Methods the server answers without the token. EnsureLlamaModel is how a stdio
# `garage-mcp` spawned by an MCP client (outside the app, so without the token) gets
# its llama_xpc model loaded; it only loads a model the app already knows by slug.
UNAUTHENTICATED_METHODS = frozenset({"EnsureLlamaModel"})


def token_from_env() -> str | None:
    """The token in ``GARAGE_GRPC_TOKEN``, or None when it is unset or empty."""
    token = os.environ.get(TOKEN_ENV, "").strip()
    return token or None


def token_matches(presented: str | bytes | None, expected: str) -> bool:
    """Constant-time comparison of a presented token against the expected one."""
    if presented is None:
        return False
    presented_bytes = presented.encode() if isinstance(presented, str) else presented
    return hmac.compare_digest(presented_bytes, expected.encode())
