"""Email extraction: Apple Mail's .emlx framing, MIME bodies, and the walk over a Mail folder."""

from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path
from unittest.mock import MagicMock

import pytest

from garage_rag.attribute.resolver import SelfIdentity, resolve
from garage_rag.db.models import CorpusClass, TrustTier
from garage_rag.extract.base import ContentKind, ExtractionError
from garage_rag.extract.dispatch import extract, extractor_for, is_indexable
from garage_rag.extract.mail import extract_email, html_to_text, read_message_bytes
from garage_rag.extract.quality import assess
from garage_rag.ingest.classify import classify
from garage_rag.ingest.gateway import ExistingDocStat, SourceContext
from garage_rag.ingest.materialize import MaterializationBudget
from garage_rag.ingest.pipeline import IngestCounters, ingest_one
from garage_rag.ingest.walker import walk

PLIST = (
    b'<?xml version="1.0" encoding="UTF-8"?>\n'
    b'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    b'<plist version="1.0">\n<dict>\n\t<key>flags</key>\n\t<integer>8590195713</integer>\n</dict>\n</plist>\n'
)

PLAIN = (
    b"From: Fixture Gardener <gardener@example.com>\r\n"
    b"To: Fixture Owner <owner@example.net>\r\n"
    b"Subject: Seed swap at the community garden\r\n"
    b"Date: Thu, 10 Sep 2026 09:30:00 -0700\r\n"
    b"Message-ID: <fixture-1@example.com>\r\n"
    b"MIME-Version: 1.0\r\n"
    b"Content-Type: text/plain; charset=utf-8\r\n"
    b"\r\n"
    b"Bring any spare tomato and bean seeds on Sunday. We will label them by variety and trade over lunch.\r\n"
)


def _emlx(message: bytes, plist: bytes = PLIST) -> bytes:
    return str(len(message)).encode() + b"\n" + message + plist


def _write(path: Path, data: bytes) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


def test_emlx_reads_only_the_counted_message(tmp_path):
    path = _write(tmp_path / "1.emlx", _emlx(PLAIN))
    assert read_message_bytes(path) == PLAIN


def test_emlx_without_a_byte_count_is_read_whole(tmp_path):
    path = _write(tmp_path / "2.emlx", PLAIN)
    assert read_message_bytes(path) == PLAIN


def test_plain_message_becomes_headers_and_body(tmp_path):
    result = extract_email(_write(tmp_path / "1.emlx", _emlx(PLAIN)))

    assert result.kind is ContentKind.CONVERSATION
    assert result.extractor == "email"
    assert result.title == "Seed swap at the community garden"
    assert result.text.splitlines()[:4] == [
        "Subject: Seed swap at the community garden",
        "From: Fixture Gardener <gardener@example.com>",
        "To: Fixture Owner <owner@example.net>",
        "Date: Thu, 10 Sep 2026 09:30:00 -0700",
    ]
    assert "tomato and bean seeds" in result.text
    # The plist trailer is Mail's bookkeeping, not the message.
    assert "plist" not in result.text and "8590195713" not in result.text
    assert result.meta["message_id"] == "<fixture-1@example.com>"
    assert result.meta["email_date"] == "2026-09-10T09:30:00-07:00"
    assert result.author_hints == ["Fixture Gardener <gardener@example.com>"]


def test_multipart_prefers_plain_and_lists_attachments(tmp_path):
    message = (
        b"From: billing@example.org\r\n"
        b"To: owner@example.net\r\n"
        b"Subject: =?utf-8?q?Invoice_for_the_kayak_rental_=E2=80=94_paid?=\r\n"
        b"MIME-Version: 1.0\r\n"
        b'Content-Type: multipart/mixed; boundary="outer"\r\n'
        b"\r\n"
        b"--outer\r\n"
        b'Content-Type: multipart/alternative; boundary="alt"\r\n'
        b"\r\n"
        b"--alt\r\n"
        b"Content-Type: text/plain; charset=utf-8\r\n"
        b"\r\n"
        b"Two kayaks for four hours comes to eighty dollars.\r\n"
        b"--alt\r\n"
        b"Content-Type: text/html; charset=utf-8\r\n"
        b"\r\n"
        b"<p>HTML version</p>\r\n"
        b"--alt--\r\n"
        b"--outer\r\n"
        b'Content-Type: application/pdf; name="receipt.pdf"\r\n'
        b'Content-Disposition: attachment; filename="receipt.pdf"\r\n'
        b"Content-Transfer-Encoding: base64\r\n"
        b"\r\n"
        b"JVBERi0xLjQK\r\n"
        b"--outer--\r\n"
    )
    result = extract_email(_write(tmp_path / "2.emlx", _emlx(message)))

    assert result.title == "Invoice for the kayak rental — paid"
    assert "eighty dollars" in result.text
    assert "HTML version" not in result.text
    assert "Attachments: receipt.pdf" in result.text
    assert "JVBERi0" not in result.text
    assert result.meta["attachments"] == ["receipt.pdf"]
    # A bare address is still a sender.
    assert result.author_hints == ["billing@example.org"]


def test_html_only_body_is_stripped_of_markup(tmp_path):
    message = (
        b"From: News <news@example.com>\r\n"
        b"Subject: Weekly letter\r\n"
        b"Content-Type: text/html; charset=utf-8\r\n"
        b"\r\n"
        b"<html><head><style>p{color:red}</style></head>"
        b"<body><p>First &amp; foremost</p><div>second   line</div><script>x()</script></body></html>\r\n"
    )
    result = extract_email(_write(tmp_path / "news.eml", message))
    body = result.text.split("\n\n", 1)[1]
    assert body.splitlines() == ["First & foremost", "", "second line"]


def test_html_to_text_skips_scripts_and_styles():
    assert html_to_text("<style>a{}</style>Hello<br>world<script>1</script>") == "Hello\nworld"


def test_message_with_no_subject_or_body_is_an_error(tmp_path):
    path = _write(tmp_path / "3.emlx", _emlx(b"From: a@example.com\r\n\r\n"))
    with pytest.raises(ExtractionError):
        extract_email(path)


def test_dispatch_routes_eml_and_emlx_to_the_email_extractor(tmp_path):
    for name in ("1.emlx", "1.partial.emlx", "saved.eml"):
        assert is_indexable(Path(name))
        assert extractor_for(Path(name)).__name__ == "_email"
    partial = extract(_write(tmp_path / "4.partial.emlx", _emlx(PLAIN)))
    assert partial.meta["partial"] is True


def test_email_is_communication_even_in_a_document_source(tmp_path):
    path = _write(tmp_path / "1.emlx", _emlx(PLAIN))
    result = extract(path)
    assert classify(path, result.kind, source_default=CorpusClass.DOCUMENT) is CorpusClass.COMMUNICATION


def test_a_mail_folder_walks_to_every_message_and_passes_the_quality_gate(tmp_path):
    """Apple Mail's layout, as `garage` sees ~/Library/Mail: every .emlx is found and indexed."""
    messages = tmp_path / "Mail/V10/ACCOUNT/INBOX.mbox/STORE/Data/Messages"
    _write(messages / "1.emlx", _emlx(PLAIN))
    _write(messages / "2.partial.emlx", _emlx(PLAIN.replace(b"fixture-1", b"fixture-2")))
    _write(tmp_path / "Mail/V10/MailData/Envelope Index", b"SQLite format 3\x00")

    found = sorted(candidate.path.name for candidate in walk(tmp_path / "Mail"))
    assert found == ["1.emlx", "2.partial.emlx"]
    for name in found:
        verdict = assess(extract(messages / name).text)
        assert not verdict.machine_generated, verdict.reason_text


OWNER = SelfIdentity("Fixture Owner", [("email", "owner@example.net")])


def test_mail_from_someone_else_is_received_whatever_the_source_default(tmp_path):
    path = _write(tmp_path / "1.emlx", _emlx(PLAIN))
    result = extract(path)
    attribution = resolve(
        path,
        tmp_path,
        source_default_trust=TrustTier.AUTHORED,
        author_hints=result.author_hints,
        self_identity=OWNER,
        communication=True,
    )
    assert attribution.trust is TrustTier.RECEIVED
    assert [(a.name, a.email) for a in attribution.authors] == [("Fixture Gardener", "gardener@example.com")]


def test_mail_the_owner_sent_is_authored(tmp_path):
    sent = PLAIN.replace(b"From: Fixture Gardener <gardener@example.com>", b"From: Someone <OWNER@example.net>")
    path = _write(tmp_path / "2.emlx", _emlx(sent))
    result = extract(path)
    attribution = resolve(
        path,
        tmp_path,
        source_default_trust=TrustTier.RECEIVED,
        author_hints=result.author_hints,
        self_identity=OWNER,
        communication=True,
    )
    assert attribution.trust is TrustTier.AUTHORED


def _ingest_existing(tmp_path, path: Path, chunker: str) -> MagicMock:
    stat = path.stat()
    gateway = MagicMock()
    gateway.check_stat.return_value = ExistingDocStat(
        exists=True,
        byte_size=stat.st_size,
        mtime=stat.st_mtime,
        content_sha256="",
        chunker=chunker,
        state="OK",
    )
    gateway.replace_document.return_value = 1
    ctx = SourceContext(
        source_id=1,
        slug="mail",
        root=tmp_path,
        default_class=CorpusClass.DOCUMENT,
        default_trust=TrustTier.AUTHORED,
        run_id=3,
    )
    candidate = MagicMock(path=path, size=stat.st_size, mtime=datetime.fromtimestamp(stat.st_mtime, tz=UTC))
    candidate.placeholder = False
    candidate.uri = str(path)
    ingest_one(gateway, ctx, candidate, self_identity=OWNER, budget=MaterializationBudget(), counters=IngestCounters())
    return gateway


def test_an_unchanged_eml_indexed_as_plain_text_is_indexed_again_as_mail(tmp_path):
    path = _write(tmp_path / "saved.eml", PLAIN)
    gateway = _ingest_existing(tmp_path, path, chunker="prose:recursive")
    gateway.replace_document.assert_called_once()
    assert gateway.replace_document.call_args.kwargs["corpus_class"] == "communication"
    assert gateway.replace_document.call_args.kwargs["trust_tier"] == "received"


def test_an_unchanged_eml_already_indexed_as_mail_is_skipped_on_stat(tmp_path):
    path = _write(tmp_path / "saved.eml", PLAIN)
    gateway = _ingest_existing(tmp_path, path, chunker="conversation:recursive")
    gateway.replace_document.assert_not_called()
    gateway.record_seen.assert_called_once_with(3, "mail", str(path))
