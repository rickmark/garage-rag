"""Email extraction: RFC 822 ``.eml`` files and Apple Mail's ``.emlx``.

An ``.emlx`` is the message's byte count on the first line, the RFC 822 message,
then an XML property list of Mail's flags. Only the message is read; the flags
are Mail's bookkeeping, not writing.

The text is a short header block (subject, sender, recipients, date) followed by
the body, preferring the plain-text part and falling back to the HTML part with
its markup stripped. Attachments are listed by name, never extracted.
"""

from __future__ import annotations

import logging
from email import policy
from email.message import EmailMessage
from email.parser import BytesParser
from email.utils import formataddr, getaddresses, parsedate_to_datetime
from html.parser import HTMLParser
from pathlib import Path

from garage_rag.extract.base import (
    ContentKind,
    ExtractionError,
    ExtractResult,
    normalize_text,
)

log = logging.getLogger(__name__)

VERSION = "1"


def read_message_bytes(path: Path) -> bytes:
    """The RFC 822 bytes of ``path``: the whole file, or an ``.emlx``'s message part."""
    data = path.read_bytes()
    if path.suffix.lower() != ".emlx":
        return data
    first, sep, rest = data.partition(b"\n")
    try:
        length = int(first.strip())
    except ValueError:
        # Not the framing Mail writes; read what is there rather than lose the message.
        log.debug("%s has no byte count on its first line", path)
        return data
    if not sep or length < 0:
        return rest
    return rest[:length]


class _TextFromHTML(HTMLParser):
    """Visible text of an HTML body, one line per block element."""

    _BLOCKS = frozenset({"p", "div", "br", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre"})
    _SKIPPED = frozenset({"script", "style", "head", "title"})

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self._parts: list[str] = []
        self._skipping = 0

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag in self._SKIPPED:
            self._skipping += 1
        elif tag in self._BLOCKS:
            self._parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag in self._SKIPPED:
            self._skipping = max(0, self._skipping - 1)
        elif tag in self._BLOCKS:
            self._parts.append("\n")

    def handle_data(self, data: str) -> None:
        if not self._skipping:
            self._parts.append(data)

    def text(self) -> str:
        lines = ("".join(self._parts)).split("\n")
        return "\n".join(" ".join(line.split()) for line in lines).strip()


def html_to_text(html: str) -> str:
    parser = _TextFromHTML()
    parser.feed(html)
    parser.close()
    return parser.text()


def _part_text(part: EmailMessage) -> str:
    try:
        content = part.get_content()
    except (LookupError, UnicodeError, AssertionError):
        # An unknown or lying charset: decode the bytes leniently rather than drop the body.
        payload = part.get_payload(decode=True)
        content = payload.decode("utf-8", errors="replace") if isinstance(payload, bytes) else ""
    if not isinstance(content, str):
        return ""
    if part.get_content_type() == "text/html":
        return html_to_text(content)
    return content


def _header(message: EmailMessage, name: str) -> str:
    try:
        value = message.get(name)
    except (IndexError, ValueError) as exc:  # malformed header the policy could not parse
        log.debug("unreadable %s header: %s", name, exc)
        return ""
    return " ".join(str(value).split()) if value is not None else ""


def _author_hints(message: EmailMessage) -> list[str]:
    """The senders, as ``Name <address>`` (or the bare address), for the resolver's sender rule.

    Not filtered through ``clean_author_hints``: its tool-name tokens ("user",
    "admin", "owner") are common in real mailbox names.
    """
    hints: list[str] = []
    for name, address in getaddresses([_header(message, "From")]):
        if not address or "@" not in address:
            continue
        hint = formataddr((name, address)) if name else address
        if hint not in hints:
            hints.append(hint)
    return hints


def extract_email(path: Path) -> ExtractResult:
    raw = read_message_bytes(path)
    if not raw.strip():
        raise ExtractionError(f"no message in {path.name}")
    message = BytesParser(policy=policy.default).parsebytes(raw)
    if not isinstance(message, EmailMessage):
        raise ExtractionError(f"not an email message: {path.name}")

    subject = _header(message, "Subject")
    sender = _header(message, "From")
    recipients = _header(message, "To")
    cc = _header(message, "Cc")
    date = _header(message, "Date")

    body_part = message.get_body(preferencelist=("plain", "html"))
    body = _part_text(body_part) if isinstance(body_part, EmailMessage) else ""

    attachments = [name for part in message.iter_attachments() if (name := part.get_filename())]

    header_lines = [
        f"{label}: {value}"
        for label, value in (("Subject", subject), ("From", sender), ("To", recipients), ("Cc", cc), ("Date", date))
        if value
    ]
    if attachments:
        header_lines.append("Attachments: " + ", ".join(attachments))
    text = normalize_text("\n".join(header_lines) + "\n\n" + body)
    if not body.strip() and not subject:
        raise ExtractionError(f"email has neither a subject nor a body: {path.name}")

    meta: dict = {"email_from": sender, "email_to": recipients}
    if cc:
        meta["email_cc"] = cc
    if message_id := _header(message, "Message-ID"):
        meta["message_id"] = message_id
    if date:
        try:
            meta["email_date"] = parsedate_to_datetime(date).isoformat()
        except (TypeError, ValueError):
            meta["email_date"] = date
    if attachments:
        meta["attachments"] = attachments
    if path.name.lower().endswith(".partial.emlx"):
        # Mail keeps only the headers and text of a large message locally.
        meta["partial"] = True

    return ExtractResult(
        text=text,
        # Mail is communication wherever it is found, whatever its source's default.
        kind=ContentKind.CONVERSATION,
        extractor="email",
        extractor_version=VERSION,
        title=subject or path.stem,
        meta=meta,
        author_hints=_author_hints(message),
    )


__all__ = ["extract_email", "html_to_text", "read_message_bytes"]
