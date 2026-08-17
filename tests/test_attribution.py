"""Attribution: trust classification, identity matching, and path rules."""

from __future__ import annotations

from pathlib import Path

import pytest

from garage_rag.attribute.git import remote_owner
from garage_rag.attribute.pathrules import classify_path, is_vendored
from garage_rag.attribute.resolver import SelfIdentity
from garage_rag.db.models import CorpusClass, TrustTier
from garage_rag.extract.base import ContentKind, clean_author_hints, looks_like_tool_name
from garage_rag.ingest.classify import classify, is_code_path


class TestSelfIdentity:
    def setup_method(self) -> None:
        self.me = SelfIdentity(
            "Rick Mark",
            [("git_email", "rickmark@outlook.com"), ("git_name", "Rick Mark")],
        )

    def test_matches_email_case_insensitively(self) -> None:
        assert self.me.matches(email="RickMark@Outlook.com")

    def test_matches_name(self) -> None:
        assert self.me.matches(name="rick mark")

    def test_rejects_other_people(self) -> None:
        assert not self.me.matches(name="Nikias Bassen", email="nikias@gmail.com")

    def test_email_beats_name_mismatch(self) -> None:
        """A commit under a different display name but the owner's email is theirs."""
        assert self.me.matches(name="rmark", email="rickmark@outlook.com")


class TestPathRules:
    ROOT = Path("/Users/x/Dropbox")

    @pytest.mark.parametrize(
        "relative",
        [
            "Reference/Documentation/thing.pdf",
            "Reference/Companion Survival Resource Library/Army Field Manuals/fm.pdf",
            "Documents/Paper/Reference/paper.pdf",
        ],
    )
    def test_reference_trees(self, relative: str) -> None:
        trust, label = classify_path(self.ROOT / relative, self.ROOT)
        assert trust is TrustTier.REFERENCE, label

    @pytest.mark.parametrize(
        "relative",
        ["Personal/notes.md", "Projects/thing/plan.md", "Documents/Research/study.md"],
    )
    def test_authored_trees(self, relative: str) -> None:
        trust, label = classify_path(self.ROOT / relative, self.ROOT)
        assert trust is TrustTier.AUTHORED, label

    def test_vendored_is_reference_anywhere(self) -> None:
        """Third-party code is third-party wherever it sits."""
        path = self.ROOT / "Projects/app/node_modules/lib/README.md"
        trust, label = classify_path(path, self.ROOT)
        assert trust is TrustTier.REFERENCE
        assert label == "path:vendored"

    @pytest.mark.parametrize(
        "marker", ["node_modules", "vendor", "Pods", "third_party", "site-packages"]
    )
    def test_vendor_markers(self, marker: str) -> None:
        assert is_vendored(Path(f"/a/b/{marker}/c/d.md"))

    def test_unmatched_path_uses_supplied_default(self) -> None:
        trust, label = classify_path(
            self.ROOT / "Misc/thing.md", self.ROOT, default=TrustTier.RECEIVED
        )
        assert trust is TrustTier.RECEIVED
        assert label == "path:default"


class TestRemoteOwner:
    @pytest.mark.parametrize(
        ("remote", "expected"),
        [
            ("git@github.com:hack-different/libimobiledevice.git", "hack-different"),
            ("https://github.com/rickmark/garage.git", "rickmark"),
            ("https://github.com/anza-xyz/agave", "anza-xyz"),
            ("ssh://git@gitlab.com/group/repo.git", "group"),
            (None, None),
            ("", None),
        ],
    )
    def test_owner_extraction(self, remote: str | None, expected: str | None) -> None:
        assert remote_owner(remote) == expected


class TestCorpusClassification:
    def test_code_extension_is_code(self) -> None:
        assert classify(Path("/r/app/main.py"), ContentKind.CODE) is CorpusClass.CODE

    def test_readme_in_repo_stays_document(self) -> None:
        """A README is prose about code, not code."""
        assert (
            classify(Path("/r/app/README.md"), ContentKind.MARKDOWN)
            is CorpusClass.DOCUMENT
        )

    def test_license_without_extension_is_document(self) -> None:
        assert not is_code_path(Path("/r/LICENSE"))

    def test_conversation_is_communication(self) -> None:
        assert (
            classify(Path("/x/thread.txt"), ContentKind.CONVERSATION)
            is CorpusClass.COMMUNICATION
        )

    def test_communication_source_pins_class(self) -> None:
        """Messages stay communication regardless of file shape."""
        assert (
            classify(
                Path("/x/some.py"),
                ContentKind.CODE,
                source_default=CorpusClass.COMMUNICATION,
                source_pins_class=True,
            )
            is CorpusClass.COMMUNICATION
        )

    def test_code_path_excludes_docs(self) -> None:
        assert is_code_path(Path("/r/x.swift"))
        assert not is_code_path(Path("/r/x.md"))

    @pytest.mark.parametrize(
        "name", ["security.rb", "license.py", "changelog.js", "authors.go", "readme.ts"]
    )
    def test_doc_stem_does_not_override_code_extension(self, name: str) -> None:
        """Regression: a source file named `security.rb` is code, not prose.

        The documentation-stem list exists for SECURITY.md and LICENSE, but
        applying it before the extension check misfiled real source files as
        documents, which then bypassed the code filter entirely.
        """
        path = Path("/r/app") / name
        assert classify(path, ContentKind.CODE) is CorpusClass.CODE
        assert is_code_path(path)

    @pytest.mark.parametrize("name", ["SECURITY.md", "README.md", "LICENSE", "CHANGELOG"])
    def test_documentation_names_still_documents(self, name: str) -> None:
        path = Path("/r/app") / name
        assert classify(path, ContentKind.MARKDOWN) is CorpusClass.DOCUMENT
        assert not is_code_path(path)


class TestToolNameFiltering:
    @pytest.mark.parametrize(
        "value",
        ["openpyxl", "Steve Canny", "Microsoft Word", "Adobe InDesign 21.2", "unknown", "admin"],
    )
    def test_rejects_software_and_placeholders(self, value: str) -> None:
        assert looks_like_tool_name(value)

    @pytest.mark.parametrize("value", ["Rick Mark", "Nikias Bassen", "Ada Lovelace"])
    def test_accepts_real_names(self, value: str) -> None:
        assert not looks_like_tool_name(value)

    def test_clean_hints_dedupes_and_filters(self) -> None:
        out = clean_author_hints(
            ["Ada Lovelace", "openpyxl", "ada lovelace", "  ", "Grace Hopper"]
        )
        assert out == ["Ada Lovelace", "Grace Hopper"]
