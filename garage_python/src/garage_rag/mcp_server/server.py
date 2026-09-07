"""MCP server exposing the corpus to Claude.

Two details of the MCP 2.0 Python SDK shape this module:

* The entry point is ``MCPServer``. ``FastMCP`` was removed in 2.0 -- the old
  import path does not exist, it is not merely deprecated.
* Return **annotations** are the output schema. Dataclasses, Pydantic models, and
  TypedDicts map field-for-field, whereas bare scalars, lists, and unions get
  wrapped in ``{"result": ...}``. Every tool here therefore returns a dataclass,
  so clients see named fields rather than an opaque wrapper.

stdout is the protocol wire. Logging goes to stderr, and nothing here may
``print``.
"""

from __future__ import annotations

import logging
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Annotated, Literal

from mcp.server import MCPServer
from pydantic import BeforeValidator, Field
from sqlalchemy import func

from garage_rag.config import get_settings
from garage_rag.db.emb_tables import count_vectors, list_models
from garage_rag.db.engine import session_scope
from garage_rag.db.models import (
    Author,
    AuthorIdentity,
    Chunk,
    Document,
    DocumentAuthor,
    IngestState,
    Source,
)
from garage_rag.search.hybrid import corpus_overview
from garage_rag.search.hybrid import search as run_search

# stderr only: anything on stdout corrupts the JSON-RPC stream.
logging.basicConfig(
    level=logging.INFO,
    stream=sys.stderr,
    format="%(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("garage_rag.mcp")

mcp = MCPServer("garage-rag")

# Home is collapsed to ~ in returned paths: absolute paths leak the account name
# into transcripts and are no more useful to the caller.
_HOME = str(Path.home())


def _tidy(uri: str) -> str:
    return uri.replace(_HOME, "~") if uri.startswith(_HOME) else uri


def _as_list(value: object) -> object:
    """Accept a single value where a list is expected.

    ``{"trust": "reference"}`` is how a person -- and a language model -- writes a
    single filter, but a bare ``list[...]`` annotation rejects it with
    "Input should be a valid list". Coercing here, and advertising both shapes in
    the schema below, makes the obvious spelling work instead of failing the whole
    call over a pair of brackets.
    """
    if isinstance(value, str):
        return [value]
    return value


# Filter parameters accept either one value or several. The union is what puts
# both shapes in the published input schema; the validator normalizes them.
ClassFilter = Annotated[
    list[Literal["document", "code", "communication"]]
    | Literal["document", "code", "communication"]
    | None,
    BeforeValidator(_as_list),
]
TrustFilter = Annotated[
    list[Literal["authored", "reference", "received"]]
    | Literal["authored", "reference", "received"]
    | None,
    BeforeValidator(_as_list),
]
SourceFilter = Annotated[list[str] | str | None, BeforeValidator(_as_list)]


# ---------------------------------------------------------------------------
# result types
# ---------------------------------------------------------------------------
@dataclass
class Hit:
    """One retrieved chunk."""

    chunk_id: int
    document_id: int
    location: str
    title: str | None
    corpus_class: str
    trust_tier: str
    section: str | None
    authors: list[str]
    matched_by: str
    score: float
    text: str


@dataclass
class SearchResult:
    query: str
    mode: str
    model: str
    count: int
    hits: list[Hit] = field(default_factory=list)


@dataclass
class DocumentResult:
    document_id: int
    location: str
    title: str | None
    corpus_class: str
    trust_tier: str
    authors: list[str]
    extractor: str
    byte_size: int | None
    chunk_count: int
    truncated: bool
    content: str


@dataclass
class SourceInfo:
    slug: str
    kind: str
    corpus_class: str
    trust_tier: str
    root: str
    documents: int
    chunks: int


@dataclass
class SourceList:
    count: int
    sources: list[SourceInfo] = field(default_factory=list)


@dataclass
class AuthorInfo:
    name: str
    is_self: bool
    documents: int
    identities: list[str]


@dataclass
class AuthorList:
    count: int
    authors: list[AuthorInfo] = field(default_factory=list)


@dataclass
class ModelInfo:
    slug: str
    dims: int
    stored_dims: int
    storage: str
    index: str
    is_default: bool
    vectors: int
    pending: int


@dataclass
class CorpusStats:
    documents: int
    chunks: int
    authors: int
    placeholders_pending: int
    by_class_and_trust: list[dict]
    models: list[ModelInfo] = field(default_factory=list)


# ---------------------------------------------------------------------------
# tools
# ---------------------------------------------------------------------------
@mcp.tool()
def rag_search(
    query: Annotated[
        str, Field(description="Natural-language question or keywords to search for.")
    ],
    limit: Annotated[int, Field(ge=1, le=50, description="Maximum hits to return.")] = 10,
    mode: Annotated[
        Literal["hybrid", "vector", "fts"],
        Field(
            description=(
                "hybrid fuses semantic and keyword search (best default); "
                "vector is semantic only; fts is exact-keyword only and needs no "
                "embedding model."
            )
        ),
    ] = "hybrid",
    corpus_class: Annotated[
        ClassFilter,
        Field(
            description=(
                "Restrict by what the resource is. 'document' is prose, 'code' is "
                "source and config, 'communication' is messages and mail. "
                "Accepts one value or a list."
            )
        ),
    ] = None,
    trust: Annotated[
        TrustFilter,
        Field(
            description=(
                "Restrict by provenance. 'authored' is what the corpus owner "
                "wrote, 'reference' is external QA'ed material, 'received' is "
                "what others sent them. Use 'authored' for questions about the "
                "owner's own conclusions. Accepts one value or a list."
            )
        ),
    ] = None,
    source: Annotated[
        SourceFilter,
        Field(description="Restrict to these source slugs. Accepts one value or a list."),
    ] = None,
    author: Annotated[
        str | None, Field(description="Restrict to documents by this author (substring match).")
    ] = None,
) -> SearchResult:
    """Search the personal corpus with hybrid semantic + keyword retrieval.

    Filter by trust to separate the owner's own writing from reference material,
    and by corpus_class to keep source code out of prose answers.
    """
    with session_scope() as session:
        hits = run_search(
            session,
            query,
            limit=limit,
            mode=mode,
            corpus_classes=list(corpus_class) if corpus_class else None,
            trust_tiers=list(trust) if trust else None,
            sources=list(source) if source else None,
            author=author,
        )
        models = list_models(session)
        default = next((m.slug for m in models if m.is_default), "none")

    return SearchResult(
        query=query,
        mode=mode,
        model=default if mode != "fts" else "n/a",
        count=len(hits),
        hits=[
            Hit(
                chunk_id=h.chunk_id,
                document_id=h.document_id,
                location=_tidy(h.uri),
                title=h.title,
                corpus_class=h.corpus_class,
                trust_tier=h.trust_tier,
                section=h.heading_path,
                authors=h.authors,
                matched_by=h.matched_by,
                score=round(h.score, 6),
                text=h.text,
            )
            for h in hits
        ],
    )


@mcp.tool()
def rag_get_document(
    document_id: Annotated[
        int | None, Field(description="Document id, as returned by rag_search.")
    ] = None,
    location: Annotated[
        str | None,
        Field(description="Path of the document; '~' is accepted. Used when no id is given."),
    ] = None,
    max_chars: Annotated[
        int, Field(ge=500, le=200_000, description="Truncate content beyond this length.")
    ] = 20_000,
) -> DocumentResult:
    """Fetch a document's full extracted text, to read past a search snippet."""
    if document_id is None and not location:
        raise ValueError("pass either document_id or location")

    with session_scope() as session:
        if document_id is not None:
            doc = session.query(Document).filter(Document.id == document_id).one_or_none()
        else:
            expanded = (location or "").replace("~", _HOME)
            doc = session.query(Document).filter(Document.uri == expanded).one_or_none()

        if doc is None:
            raise ValueError(f"no such document: {document_id or location}")

        authors = [
            r[0]
            for r in (
                session.query(Author.display_name)
                .join(DocumentAuthor, DocumentAuthor.author_id == Author.id)
                .filter(DocumentAuthor.document_id == doc.id)
                .order_by(DocumentAuthor.confidence.desc())
                .all()
            )
        ]
        chunk_count = (
            session.query(func.count(Chunk.id))
            .filter(Chunk.document_id == doc.id)
            .scalar()
            or 0
        )

    content = doc.content or ""
    truncated = len(content) > max_chars
    return DocumentResult(
        document_id=doc.id,
        location=_tidy(doc.uri),
        title=doc.title,
        corpus_class=str(doc.corpus_class),
        trust_tier=str(doc.trust_tier),
        authors=authors,
        extractor=doc.extractor,
        byte_size=doc.byte_size,
        chunk_count=chunk_count,
        truncated=truncated,
        content=content[:max_chars],
    )


@mcp.tool()
def rag_list_sources() -> SourceList:
    """List indexed sources with their document and chunk counts."""
    with session_scope() as session:
        rows = (
            session.query(
                Source.slug,
                Source.kind,
                Source.default_class.label("cls"),
                Source.default_trust.label("trust"),
                Source.root,
                func.count(func.distinct(Document.id)).label("documents"),
                func.count(Chunk.id).label("chunks"),
            )
            .outerjoin(
                Document,
                (Document.source_id == Source.id) & (Document.state == IngestState.OK),
            )
            .outerjoin(Chunk, Chunk.document_id == Document.id)
            .group_by(
                Source.id,
                Source.slug,
                Source.kind,
                Source.default_class,
                Source.default_trust,
                Source.root,
            )
            .order_by(func.count(func.distinct(Document.id)).desc())
            .all()
        )

    sources = [
        SourceInfo(
            slug=r.slug,
            kind=r.kind,
            corpus_class=str(r.cls),
            trust_tier=str(r.trust),
            root=_tidy(r.root),
            documents=int(r.documents),
            chunks=int(r.chunks),
        )
        for r in rows
    ]
    return SourceList(count=len(sources), sources=sources)


@mcp.tool()
def rag_list_authors(
    limit: Annotated[int, Field(ge=1, le=200)] = 30,
) -> AuthorList:
    """List authors in the corpus, most-documented first."""
    with session_scope() as session:
        identity_expr = AuthorIdentity.kind + ":" + AuthorIdentity.value
        rows = (
            session.query(
                Author.display_name,
                Author.is_self,
                func.count(func.distinct(DocumentAuthor.document_id)).label("documents"),
                func.array_agg(func.distinct(identity_expr))
                .filter(AuthorIdentity.id.is_not(None))
                .label("identities"),
            )
            .outerjoin(DocumentAuthor, DocumentAuthor.author_id == Author.id)
            .outerjoin(AuthorIdentity, AuthorIdentity.author_id == Author.id)
            .group_by(Author.id, Author.display_name, Author.is_self)
            .order_by(
                func.count(func.distinct(DocumentAuthor.document_id)).desc(),
                Author.display_name,
            )
            .limit(limit)
            .all()
        )

    authors = [
        AuthorInfo(
            name=r.display_name,
            is_self=bool(r.is_self),
            documents=int(r.documents),
            identities=list(r.identities or []),
        )
        for r in rows
    ]
    return AuthorList(count=len(authors), authors=authors)


@mcp.tool()
def rag_stats() -> CorpusStats:
    """Summarize corpus size, composition, and embedding coverage.

    Useful before searching: it shows which classes and trust tiers actually hold
    content, and whether embeddings are complete enough for semantic search.
    """
    with session_scope() as session:
        documents = int(
            session.query(func.count(Document.id))
            .filter(Document.state == IngestState.OK)
            .scalar()
            or 0
        )
        chunks = int(session.query(func.count(Chunk.id)).scalar() or 0)
        authors = int(session.query(func.count(Author.id)).scalar() or 0)
        pending = int(
            session.query(func.count(Document.id))
            .filter(Document.state == IngestState.PLACEHOLDER)
            .scalar()
            or 0
        )
        overview = corpus_overview(session)

        models: list[ModelInfo] = []
        for m in list_models(session):
            have = count_vectors(session, m)
            models.append(
                ModelInfo(
                    slug=m.slug,
                    dims=m.dims,
                    stored_dims=m.stored_dims,
                    storage=m.storage_kind,
                    index=m.index_kind,
                    is_default=bool(m.is_default),
                    vectors=have,
                    pending=max(0, chunks - have),
                )
            )

    return CorpusStats(
        documents=documents,
        chunks=chunks,
        authors=authors,
        placeholders_pending=pending,
        by_class_and_trust=overview,
        models=models,
    )


LOOPBACK_HOSTS = frozenset({"127.0.0.1", "::1", "localhost", "127.0.0.0/8"})


def is_loopback(host: str) -> bool:
    """Whether ``host`` can only be reached from this machine."""
    import ipaddress

    if host in LOOPBACK_HOSTS:
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        # A hostname we cannot classify; treat as remote and make the caller
        # opt in explicitly.
        return False


def _log_startup() -> None:
    settings = get_settings()
    log.info("database connection: %s", settings.database_url)
    with session_scope() as session:
        count = session.query(Source).count()
    log.info("%d sources registered", count)


def serve(
    transport: str = "stdio",
    *,
    host: str | None = None,
    port: int | None = None,
    path: str | None = None,
    allowed_origins: list[str] | None = None,
    json_response: bool = False,
    stateless: bool = False,
) -> None:
    """Run the server on ``stdio``, ``streamable-http``, or ``sse``.

    HTTP transports get DNS-rebinding protection configured explicitly. Without
    it a page in your browser could reach a loopback-bound server via a
    rebound hostname, and this server answers questions about your private
    corpus — so the ``Host`` and ``Origin`` allowlists are the only thing
    standing between "local only" and "any website you visit".
    """
    settings = get_settings()
    log.info("garage-rag MCP server starting (transport=%s)", transport)
    _log_startup()

    if transport == "stdio":
        # stdio is the default and the call blocks.
        mcp.run()
        return

    if transport not in ("streamable-http", "sse"):
        raise ValueError(f"unsupported transport: {transport!r}")

    from mcp.server.transport_security import TransportSecuritySettings

    bind_host = host or settings.mcp_host
    bind_port = port or settings.mcp_port
    http_path = path or settings.mcp_http_path

    # Host header allowlist: the addresses a client may legitimately use.
    allowed_hosts = [
        f"{bind_host}:{bind_port}",
        f"localhost:{bind_port}",
        f"127.0.0.1:{bind_port}",
    ]
    security = TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=sorted(set(allowed_hosts)),
        allowed_origins=sorted(set(allowed_origins or [])),
    )

    if not is_loopback(bind_host):
        # Not fatal here — the CLI already required an explicit opt-in — but it
        # belongs in the log so it is visible in whatever captured stderr.
        log.warning(
            "listening on %s, which is reachable from other machines; this "
            "server has no authentication and exposes the whole corpus",
            bind_host,
        )

    log.info("listening on http://%s:%d%s", bind_host, bind_port, http_path)

    if transport == "sse":
        mcp.run(
            "sse",
            host=bind_host,
            port=bind_port,
            sse_path=http_path,
            transport_security=security,
        )
        return

    mcp.run(
        "streamable-http",
        host=bind_host,
        port=bind_port,
        streamable_http_path=http_path,
        json_response=json_response,
        stateless_http=stateless,
        transport_security=security,
    )


def main() -> None:
    """Console-script entry point: stdio, which is what MCP clients spawn."""
    serve("stdio")


# Required: `mcp dev`, `mcp run`, and the tests all *import* this module.
if __name__ == "__main__":
    main()
