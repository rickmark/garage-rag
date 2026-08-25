"""The single point at which data may leave this machine.

Private communications must never reach a cloud API. That is enforced
structurally rather than by convention, at four independent levels:

1. **Chokepoint.** This module is the only place an Anthropic client is
   constructed. No other module imports ``anthropic``; a test asserts it.
2. **Type-level.** :class:`EgressRequest` *requires* a ``corpus_class``, and its
   ``__post_init__`` raises :class:`EgressBlocked` for ``communication``. There is
   no way to build a request without declaring what kind of content it carries,
   and no way to declare it a conversation and still send it.
3. **Source flag.** ``sources.allow_cloud_enrichment`` defaults to false and is
   never set true for Messages or Mail. Checked here in addition to the class.
4. **Global switch.** ``cloud.enable_ocr`` in the config file gates everything,
   and a missing ``cloud.api_key_file`` disables it too -- so the whole path can
   be turned off in one place, and fails closed when half-configured.

The ordering matters: the class check runs before anything else, so a coding
mistake elsewhere in the pipeline fails closed rather than leaking.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any

import anthropic

from garage_rag.config import get_settings
from garage_rag.db.models import CorpusClass

log = logging.getLogger(__name__)


class EgressBlocked(RuntimeError):
    """Sending this content off the machine is not permitted."""


class CloudUnavailable(RuntimeError):
    """Cloud enrichment is configured off, or credentials are absent."""


@dataclass
class EgressRequest:
    """A request to send content to a cloud model.

    ``corpus_class`` is mandatory and validated on construction. That is the
    point of the type: callers cannot forget to consider it.
    """

    corpus_class: CorpusClass
    purpose: str
    source_allows_cloud: bool
    # Payload blocks, in Anthropic message-content form.
    content: list[dict[str, Any]] = field(default_factory=list)
    max_tokens: int = 2048

    def __post_init__(self) -> None:
        # Level 2. First check, before any other consideration.
        if self.corpus_class is CorpusClass.COMMUNICATION:
            raise EgressBlocked(
                f"communications may never be sent to a cloud API (purpose={self.purpose!r})"
            )
        # Level 3.
        if not self.source_allows_cloud:
            raise EgressBlocked(
                f"source does not permit cloud enrichment (purpose={self.purpose!r}); "
                "enable it per-source with --allow-cloud-enrichment"
            )


def cloud_enabled() -> bool:
    """Whether cloud enrichment is switched on, importable, and has a key."""
    settings = get_settings()
    if not settings.enable_cloud_ocr:
        return False
    if settings.read_api_key() is None:
        return False
    return True


def _client():
    """Construct the one Anthropic client this project uses.

    Deliberately the only such call in the codebase. The key is read from the
    file named by ``cloud.api_key_file`` and passed explicitly, so the config
    itself never contains a secret and no environment variable is involved.
    """
    settings = get_settings()
    if not settings.enable_cloud_ocr:
        raise CloudUnavailable(
            "cloud enrichment is disabled; set cloud.enable_ocr = true in "
            f"{settings.config_path or 'garage.json'}"
        )

    key = settings.read_api_key()
    if key is None:
        raise CloudUnavailable(
            "no API key available; point cloud.api_key_file at a file containing your Anthropic key"
        )
    return anthropic.Anthropic(api_key=key)

def send(request: EgressRequest, *, system: str | None = None) -> str:
    """Execute an approved egress request and return the model's text.

    Validation already happened in :class:`EgressRequest`; reaching this function
    means the content is permitted to leave.
    """
    settings = get_settings()
    client = _client()

    kwargs: dict[str, Any] = {
        "model": settings.cloud_ocr_model,
        "max_tokens": request.max_tokens,
        "messages": [{"role": "user", "content": request.content}],
    }
    if system:
        kwargs["system"] = system

    log.debug("egress: %s (%s)", request.purpose, request.corpus_class)
    response = client.messages.create(**kwargs)

    parts = [block.text for block in response.content if getattr(block, "type", None) == "text"]
    return "\n".join(parts).strip()


def assert_egress_allowed(corpus_class: CorpusClass) -> None:
    """Raise if this class of content may never be sent to a cloud API.

    Exposed so callers can fail fast before assembling an expensive payload.
    """
    if corpus_class is CorpusClass.COMMUNICATION:
        raise EgressBlocked("communications may never be sent to a cloud API")
