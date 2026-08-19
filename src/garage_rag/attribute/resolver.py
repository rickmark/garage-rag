"""Combining attribution signals into a decision.

Signal precedence, strongest first:

1. **Git history** -- who actually committed the file. Authoritative when
   available, and the only signal that distinguishes your own repository from a
   clone of somebody else's.
2. **Embedded document metadata** -- PDF ``/Author``, Office core properties,
   Markdown frontmatter. Reliable when present, absent most of the time.
3. **Filesystem layout** -- path conventions (``Reference/``, ``Personal/``).
   Always available, so it is the fallback rather than the lead.
4. **Source default** -- whatever the source was registered with.

Every decision records the evidence that produced it, so a wrong attribution can
be traced to the rule responsible instead of being a mystery.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from pathlib import Path

from sqlalchemy.orm import Session

from ..config import get_settings
from ..db.models import Author, AuthorIdentity, AuthorRole, TrustTier
from .git import (
    RepoAttribution,
    cached_repo_attribution,
    find_repo_root,
    relative_posix,
    remote_owner,
)
from .pathrules import classify_path

log = logging.getLogger(__name__)


@dataclass
class AttributedAuthor:
    """One resolved author with its role and provenance."""

    name: str
    email: str | None
    role: AuthorRole
    confidence: float
    evidence: str

    @property
    def identity_pairs(self) -> list[tuple[str, str]]:
        """Identity rows to associate with this author."""
        pairs: list[tuple[str, str]] = []
        if self.email:
            kind = "git_email" if self.evidence.startswith("git") else "email"
            pairs.append((kind, self.email.lower()))
        if self.name:
            pairs.append(("git_name", self.name))
        return pairs


@dataclass
class Attribution:
    """The full attribution decision for one document."""

    trust: TrustTier
    authors: list[AttributedAuthor] = field(default_factory=list)
    evidence: str = ""
    meta: dict = field(default_factory=dict)

    @property
    def primary(self) -> AttributedAuthor | None:
        for author in self.authors:
            if author.role in (AuthorRole.AUTHOR, AuthorRole.SENDER):
                return author
        return self.authors[0] if self.authors else None


class SelfIdentity:
    """The corpus owner's identities, used to tell authored from reference."""

    def __init__(self, name: str, pairs: list[tuple[str, str]]) -> None:
        self.name = name
        self._emails = {value.lower() for kind, value in pairs if "email" in kind}
        self._names = {value.lower() for kind, value in pairs if kind == "git_name"}
        if name:
            self._names.add(name.lower())

    def matches(self, *, name: str | None = None, email: str | None = None) -> bool:
        if email and email.lower() in self._emails:
            return True
        return bool(name and name.lower() in self._names)

    @property
    def emails(self) -> set[str]:
        return set(self._emails)

    @classmethod
    def from_settings(cls) -> SelfIdentity:
        settings = get_settings()
        return cls(settings.self_name, settings.self_identity_pairs())


def _git_attribution(path: Path, self_identity: SelfIdentity) -> Attribution | None:
    """Attribution from git history, or None when the file is not tracked."""
    repo_root = find_repo_root(path)
    if repo_root is None:
        return None

    repo: RepoAttribution = cached_repo_attribution(str(repo_root))
    relative = relative_posix(repo_root, path)
    if relative is None:
        return None

    tallies = repo.authors_for(relative)
    if not tallies:
        # Inside a repo but untracked (build output, ignored file, or a path the
        # history does not mention). Let the path rules decide.
        return None

    owner = remote_owner(repo.remote)
    self_commits = sum(
        t.commits for t in tallies if self_identity.matches(name=t.name, email=t.email)
    )
    total_commits = sum(t.commits for t in tallies) or 1

    authors: list[AttributedAuthor] = []
    top = tallies[0]
    authors.append(
        AttributedAuthor(
            name=top.name,
            email=top.email or None,
            role=AuthorRole.AUTHOR,
            confidence=round(top.commits / total_commits, 3),
            evidence=f"git-log:top-committer:{top.commits}/{total_commits}",
        )
    )
    # Remaining contributors, capped: a widely-touched file in a large project
    # can have dozens, and they add little beyond the top few.
    for tally in tallies[1:6]:
        authors.append(
            AttributedAuthor(
                name=tally.name,
                email=tally.email or None,
                role=AuthorRole.COMMITTER,
                confidence=round(tally.commits / total_commits, 3),
                evidence=f"git-log:committer:{tally.commits}/{total_commits}",
            )
        )

    # The distinction that matters: did the owner actually write this, or is it a
    # clone of somebody else's work that happens to live on their disk?
    if self_commits > 0:
        trust = TrustTier.AUTHORED
        evidence = f"git-log:self-commits:{self_commits}/{total_commits}"
    else:
        trust = TrustTier.REFERENCE
        evidence = f"git-log:no-self-commits:owner={owner}"

    return Attribution(
        trust=trust,
        authors=authors,
        evidence=evidence,
        meta={
            "git_repo": repo_root.name,
            "git_remote": repo.remote,
            "git_remote_owner": owner,
            "git_commits_total": total_commits,
            "git_commits_self": self_commits,
        },
    )


def _metadata_attribution(
    author_hints: list[str], self_identity: SelfIdentity
) -> Attribution | None:
    """Attribution from embedded document metadata."""
    if not author_hints:
        return None

    authors = [
        AttributedAuthor(
            name=hint,
            email=None,
            role=AuthorRole.AUTHOR if index == 0 else AuthorRole.COMMITTER,
            confidence=0.8 if index == 0 else 0.5,
            evidence="document-metadata",
        )
        for index, hint in enumerate(author_hints[:5])
    ]

    # Somebody else's name in the metadata means collected, not written.
    if any(self_identity.matches(name=hint) for hint in author_hints):
        return Attribution(
            trust=TrustTier.AUTHORED, authors=authors, evidence="document-metadata:self"
        )
    return Attribution(
        trust=TrustTier.REFERENCE,
        authors=authors,
        evidence="document-metadata:third-party",
    )


def resolve(
    path: Path,
    source_root: Path,
    *,
    source_default_trust: TrustTier,
    author_hints: list[str] | None = None,
    self_identity: SelfIdentity | None = None,
) -> Attribution:
    """Decide trust and authorship for one file."""
    identity = self_identity or SelfIdentity.from_settings()
    hints = author_hints or []

    # 1. Git history wins when the file is tracked.
    from_git = _git_attribution(path, identity)
    if from_git is not None:
        return from_git

    # 2. Embedded metadata, when a real name is present.
    from_meta = _metadata_attribution(hints, identity)

    # 3. Path conventions.
    path_trust, path_label = classify_path(path, source_root, default=source_default_trust)

    if from_meta is not None:
        # Metadata names an author; a reference-shaped path still overrides an
        # authored guess, since "in Reference/ but has my name" is usually a
        # paper the owner collected rather than wrote.
        trust = TrustTier.REFERENCE if path_trust is TrustTier.REFERENCE else from_meta.trust
        return Attribution(
            trust=trust,
            authors=from_meta.authors,
            evidence=f"{from_meta.evidence}+{path_label}",
        )

    # 4. Nothing but the path. Attribute to the owner only when the path says
    # this is their own material.
    authors: list[AttributedAuthor] = []
    if path_trust is TrustTier.AUTHORED and identity.name:
        authors.append(
            AttributedAuthor(
                name=identity.name,
                email=next(iter(identity.emails), None),
                role=AuthorRole.AUTHOR,
                confidence=0.6,
                evidence=path_label,
            )
        )
    return Attribution(trust=path_trust, authors=authors, evidence=path_label)


# ---------------------------------------------------------------------------
# persistence
# ---------------------------------------------------------------------------
def get_or_create_author(
    session: Session,
    name: str,
    *,
    identities: list[tuple[str, str]],
    is_self: bool = False,
) -> Author:
    """Resolve an author by identity, creating one on first sight.

    Identity lookup comes first so the same person arriving via a git email and
    later via a PDF byline collapses onto one row.
    """
    for kind, value in identities:
        existing = session.query(AuthorIdentity).filter_by(kind=kind, value=value).one_or_none()
        if existing is not None:
            return existing.author

    author = session.query(Author).filter_by(display_name=name).one_or_none()
    if author is None:
        author = Author(display_name=name or "unknown", is_self=is_self)
        session.add(author)
        session.flush()

    # Attach any identities not yet recorded.
    for kind, value in identities:
        present = session.query(AuthorIdentity).filter_by(kind=kind, value=value).one_or_none()
        if present is None:
            session.add(AuthorIdentity(author_id=author.id, kind=kind, value=value))
    session.flush()
    return author


def ensure_self_author(session: Session) -> Author | None:
    """Create or update the row representing the corpus owner."""
    settings = get_settings()
    if not settings.self_name:
        return None

    existing = session.query(Author).filter_by(is_self=True).one_or_none()
    pairs = settings.self_identity_pairs()
    if existing is not None:
        for kind, value in pairs:
            present = session.query(AuthorIdentity).filter_by(kind=kind, value=value).one_or_none()
            if present is None:
                session.add(AuthorIdentity(author_id=existing.id, kind=kind, value=value))
        session.flush()
        return existing

    author = Author(display_name=settings.self_name, is_self=True)
    session.add(author)
    session.flush()
    for kind, value in pairs:
        session.add(AuthorIdentity(author_id=author.id, kind=kind, value=value))
    session.flush()
    return author
