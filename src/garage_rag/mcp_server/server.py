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
from pydantic import Field
from sqlalchemy import text

from ..db.emb_tables import list_models
from ..db.engine import session_scope
from ..db.models import Source
from ..search.hybrid import corpus_overview
from ..search.hybrid import search as run_search

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
        list[Literal["document", "code", "communication"]] | None,
        Field(
            description=(
                "Restrict by what the resource is. 'document' is prose, 'code' is "
                "source and config, 'communication' is messages and mail."
            )
        ),
    ] = None,
    trust: Annotated[
        list[Literal["authored", "reference", "received"]] | None,
        Field(
            description=(
                "Restrict by provenance. 'authored' is what the corpus owner "
                "wrote, 'reference' is external QA'ed material, 'received' is "
                "what others sent them. Use 'authored' for questions about the "
                "owner's own conclusions."
            )
        ),
    ] = None,
    source: Annotated[
        list[str] | None, Field(description="Restrict to these source slugs.")
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
            row = session.execute(
                text("SELECT * FROM documents WHERE id = :i"), {"i": document_id}
            ).mappings().one_or_none()
        else:
            expanded = (location or "").replace("~", _HOME)
            row = session.execute(
                text("SELECT * FROM documents WHERE uri = :u"), {"u": expanded}
            ).mappings().one_or_none()

        if row is None:
            raise ValueError(f"no such document: {document_id or location}")

        authors = [
            r[0]
            for r in session.execute(
                text(
                    "SELECT a.display_name FROM document_authors da "
                    "JOIN authors a ON a.id = da.author_id WHERE da.document_id = :d "
                    "ORDER BY da.confidence DESC"
                ),
                {"d": row["id"]},
            )
        ]
        chunk_count = int(
            session.execute(
                text("SELECT count(*) FROM chunks WHERE document_id = :d"), {"d": row["id"]}
            ).scalar_one()
        )

    content = row["content"] or ""
    truncated = len(content) > max_chars
    return DocumentResult(
        document_id=row["id"],
        location=_tidy(row["uri"]),
        title=row["title"],
        corpus_class=str(row["corpus_class"]),
        trust_tier=str(row["trust_tier"]),
        authors=authors,
        extractor=row["extractor"],
        byte_size=row["byte_size"],
        chunk_count=chunk_count,
        truncated=truncated,
        content=content[:max_chars],
    )


@mcp.tool()
def rag_list_sources() -> SourceList:
    """List indexed sources with their document and chunk counts."""
    with session_scope() as session:
        rows = session.execute(
            text(
                """
                SELECT s.slug, s.kind, s.default_class::text AS cls,
                       s.default_trust::text AS trust, s.root,
                       count(DISTINCT d.id) AS documents,
                       count(c.id)          AS chunks
                FROM sources s
                LEFT JOIN documents d ON d.source_id = s.id AND d.state = 'ok'
                LEFT JOIN chunks c    ON c.document_id = d.id
                GROUP BY s.id, s.slug, s.kind, s.default_class, s.default_trust, s.root
                ORDER BY documents DESC
                """
            )
        ).mappings().all()

    sources = [
        SourceInfo(
            slug=r["slug"],
            kind=r["kind"],
            corpus_class=r["cls"],
            trust_tier=r["trust"],
            root=_tidy(r["root"]),
            documents=int(r["documents"]),
            chunks=int(r["chunks"]),
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
        rows = session.execute(
            text(
                """
                SELECT a.display_name, a.is_self,
                       count(DISTINCT da.document_id) AS documents,
                       COALESCE(array_agg(DISTINCT i.kind || ':' || i.value)
                                FILTER (WHERE i.id IS NOT NULL), '{}') AS identities
                FROM authors a
                LEFT JOIN document_authors da ON da.author_id = a.id
                LEFT JOIN author_identities i  ON i.author_id = a.id
                GROUP BY a.id, a.display_name, a.is_self
                ORDER BY documents DESC, a.display_name
                LIMIT :limit
                """
            ),
            {"limit": limit},
        ).mappings().all()

    authors = [
        AuthorInfo(
            name=r["display_name"],
            is_self=bool(r["is_self"]),
            documents=int(r["documents"]),
            identities=list(r["identities"] or []),
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
            session.execute(
                text("SELECT count(*) FROM documents WHERE state = 'ok'")
            ).scalar_one()
        )
        chunks = int(session.execute(text("SELECT count(*) FROM chunks")).scalar_one())
        authors = int(session.execute(text("SELECT count(*) FROM authors")).scalar_one())
        pending = int(
            session.execute(
                text("SELECT count(*) FROM documents WHERE state = 'placeholder'")
            ).scalar_one()
        )
        overview = corpus_overview(session)

        models: list[ModelInfo] = []
        for m in list_models(session):
            have = int(
                session.execute(text(f"SELECT count(*) FROM {m.table_name}")).scalar_one()
            )
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
    from ..config import get_settings

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
