"""Hybrid retrieval: vector KNN fused with Postgres full-text search.

Neither half is sufficient alone. Dense vectors find paraphrase and concept
matches but miss exact identifiers -- an error code, a function name, a person's
surname. Full-text nails those and misses everything phrased differently.

The two are combined with Reciprocal Rank Fusion rather than by blending scores.
RRF only needs each side's *ranking*, which matters because cosine distance and
``ts_rank_cd`` are not on comparable scales and their distributions shift with
corpus size. Each side contributes ``1 / (k + rank)``, with ``k = 60`` as in the
original formulation: large enough that the top few results dominate without one
engine's runaway top hit swamping the other's consensus.

Filters apply to both halves, so restricting to ``corpus_class = 'document'`` or
``trust_tier = 'reference'`` narrows the candidate pool before fusion rather than
discarding results afterwards.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Literal

from pgvector import HalfVector
from pgvector.sqlalchemy import VECTOR
from sqlalchemy import bindparam, text
from sqlalchemy.orm import Session

from garage_rag.db.emb_tables import assert_safe_table, get_model
from garage_rag.db.engine import apply_search_tuning
from garage_rag.db.registry import StoragePlan, truncate_vector
from garage_rag.embed.factory import get_embedder

log = logging.getLogger(__name__)

SearchMode = Literal["hybrid", "vector", "fts"]

# RRF constant from Cormack et al. Damps the influence of any single top rank.
RRF_K = 60
# Candidates drawn from each engine before fusion. Deeper than the final limit so
# a result ranked mid-pack by one engine can still win on consensus.
CANDIDATE_DEPTH = 200


@dataclass
class SearchHit:
    chunk_id: int
    document_id: int
    uri: str
    title: str | None
    corpus_class: str
    trust_tier: str
    heading_path: str | None
    text: str
    score: float
    vector_rank: int | None = None
    fts_rank: int | None = None
    authors: list[str] = field(default_factory=list)

    @property
    def matched_by(self) -> str:
        if self.vector_rank is not None and self.fts_rank is not None:
            return "both"
        return "vector" if self.vector_rank is not None else "keyword"


# Operators that mean the user is writing a deliberate query rather than a
# natural-language question, in which case their intent is respected verbatim.
_EXPLICIT_QUERY_CHARS = ('"', " OR ", " or ", " -")


def tsquery_expr(query: str) -> str:
    """SQL expression producing the tsquery for the keyword half.

    ``websearch_to_tsquery`` ANDs every term, so "secure enclave firmware
    validation" would require all four words in a single chunk and return
    nothing. For hybrid retrieval the keyword side should favour recall -- RRF
    is what decides the ordering -- so terms are ORed instead.

    The trick is to let Postgres normalize and stem the query, then swap its
    conjunctions for disjunctions. Doing it this way keeps the user's text a bind
    parameter, where hand-building a ``to_tsquery`` string would risk both
    injection and syntax errors on stray punctuation.

    A query containing quotes, ``OR``, or a leading ``-`` is treated as
    deliberate and passed through unchanged.
    """
    if any(token in query for token in _EXPLICIT_QUERY_CHARS):
        return "websearch_to_tsquery('english', :q)"
    return "replace(plainto_tsquery('english', :q)::text, ' & ', ' | ')::tsquery"


def _filter_clause(
    *,
    corpus_classes: list[str] | None,
    trust_tiers: list[str] | None,
    sources: list[str] | None,
    author: str | None,
) -> str:
    """SQL fragment shared by both engines, so filtering precedes fusion."""
    parts = ["d.state = 'ok'"]
    # CAST(... AS ...) rather than the `::` shorthand: SQLAlchemy's text() reads
    # `:trust_tiers::trust_tier[]` as a bind parameter named `trust_tier`, so the
    # real parameter is never bound and the statement fails to parse.
    if corpus_classes:
        parts.append("d.corpus_class = ANY(CAST(:corpus_classes AS corpus_class[]))")
    if trust_tiers:
        parts.append("d.trust_tier = ANY(CAST(:trust_tiers AS trust_tier[]))")
    if sources:
        parts.append("s.slug = ANY(:sources)")
    if author:
        parts.append(
            "EXISTS (SELECT 1 FROM document_authors da JOIN authors a ON a.id = da.author_id "
            "WHERE da.document_id = d.id AND a.display_name ILIKE :author)"
        )
    return " AND ".join(parts)


def _embed_query(model, query: str) -> tuple[object, StoragePlan]:
    plan = StoragePlan(
        stored_dims=model.stored_dims,
        storage_kind=model.storage_kind,
        index_kind=model.index_kind,
        truncated_from=model.dims if model.stored_dims < model.dims else None,
    )
    raw = get_embedder(model.provider, model.model_ref).embed([query])[0]
    reduced = truncate_vector(raw, plan)
    value = HalfVector(reduced) if plan.storage_kind == "halfvec" else reduced
    return value, plan


def search(
    session: Session,
    query: str,
    *,
    limit: int = 10,
    mode: SearchMode = "hybrid",
    model_slug: str | None = None,
    corpus_classes: list[str] | None = None,
    trust_tiers: list[str] | None = None,
    sources: list[str] | None = None,
    author: str | None = None,
    snippet_chars: int = 600,
) -> list[SearchHit]:
    """Search the corpus. Returns hits ordered best-first."""
    if not query.strip():
        return []

    apply_search_tuning(session)
    model = get_model(session, model_slug)
    table = assert_safe_table(model.table_name)
    where = _filter_clause(
        corpus_classes=corpus_classes,
        trust_tiers=trust_tiers,
        sources=sources,
        author=author,
    )

    params: dict = {
        "q": query,
        "limit": limit,
        "depth": CANDIDATE_DEPTH,
        "k": RRF_K,
        "snippet": snippet_chars,
    }
    if corpus_classes:
        params["corpus_classes"] = corpus_classes
    if trust_tiers:
        params["trust_tiers"] = trust_tiers
    if sources:
        params["sources"] = sources
    if author:
        params["author"] = f"%{author}%"

    need_vector = mode in ("hybrid", "vector")

    # Each CTE is included only when its engine is in play, so `--mode fts`
    # never loads an embedding model and `--mode vector` never parses a tsquery.
    vector_cte = f"""
        vec AS (
            SELECT c.id AS chunk_id,
                   row_number() OVER (ORDER BY e.embedding <=> :qv) AS rnk
            FROM {table} e
            JOIN chunks c    ON c.id = e.chunk_id
            JOIN documents d ON d.id = c.document_id
            JOIN sources s   ON s.id = d.source_id
            WHERE {where}
            ORDER BY e.embedding <=> :qv
            LIMIT :depth
        )
    """
    tsq = tsquery_expr(query)
    fts_cte = f"""
        fts AS (
            SELECT c.id AS chunk_id,
                   row_number() OVER (
                       ORDER BY ts_rank_cd(c.tsv, {tsq}) DESC
                   ) AS rnk
            FROM chunks c
            JOIN documents d ON d.id = c.document_id
            JOIN sources s   ON s.id = d.source_id
            WHERE c.tsv @@ {tsq}
              AND {where}
            LIMIT :depth
        )
    """

    if mode == "hybrid":
        ctes = f"WITH {vector_cte}, {fts_cte}"
        join = """
            LEFT JOIN vec ON vec.chunk_id = c.id
            LEFT JOIN fts ON fts.chunk_id = c.id
        """
        having = "WHERE vec.chunk_id IS NOT NULL OR fts.chunk_id IS NOT NULL"
        score = "COALESCE(1.0/(:k + vec.rnk), 0) + COALESCE(1.0/(:k + fts.rnk), 0)"
        vrank, frank = "vec.rnk", "fts.rnk"
    elif mode == "vector":
        ctes = f"WITH {vector_cte}"
        join = "JOIN vec ON vec.chunk_id = c.id"
        having = ""
        score = "1.0/(:k + vec.rnk)"
        vrank, frank = "vec.rnk", "NULL::bigint"
    else:
        ctes = f"WITH {fts_cte}"
        join = "JOIN fts ON fts.chunk_id = c.id"
        having = ""
        score = "1.0/(:k + fts.rnk)"
        vrank, frank = "NULL::bigint", "fts.rnk"

    sql = text(
        f"""
        {ctes}
        SELECT c.id            AS chunk_id,
               d.id            AS document_id,
               d.uri,
               d.title,
               d.corpus_class::text,
               d.trust_tier::text,
               c.heading_path,
               left(c.text, :snippet) AS snippet,
               {score}         AS score,
               {vrank}         AS vector_rank,
               {frank}         AS fts_rank,
               COALESCE(
                   (SELECT array_agg(DISTINCT a.display_name)
                    FROM document_authors da
                    JOIN authors a ON a.id = da.author_id
                    WHERE da.document_id = d.id),
                   '{{}}'
               )               AS authors
        FROM chunks c
        JOIN documents d ON d.id = c.document_id
        JOIN sources s   ON s.id = d.source_id
        {join}
        {having}
        ORDER BY score DESC, c.id
        LIMIT :limit
        """
    )

    if need_vector:
        params["qv"], _plan = _embed_query(model, query)
        sql = sql.bindparams(bindparam("qv", type_=VECTOR))

    rows = session.execute(sql, params).mappings().all()
    return [
        SearchHit(
            chunk_id=row["chunk_id"],
            document_id=row["document_id"],
            uri=row["uri"],
            title=row["title"],
            corpus_class=row["corpus_class"],
            trust_tier=row["trust_tier"],
            heading_path=row["heading_path"],
            text=row["snippet"],
            score=float(row["score"]),
            vector_rank=row["vector_rank"],
            fts_rank=row["fts_rank"],
            authors=list(row["authors"] or []),
        )
        for row in rows
    ]


def corpus_overview(session: Session) -> list[dict]:
    """Counts by (corpus_class, trust_tier), for `stats` and the MCP server."""
    rows = (
        session.execute(
            text(
                """
            SELECT d.corpus_class::text AS corpus_class,
                   d.trust_tier::text   AS trust_tier,
                   count(DISTINCT d.id)  AS documents,
                   count(c.id)           AS chunks
            FROM documents d
            LEFT JOIN chunks c ON c.document_id = d.id
            WHERE d.state = 'ok'
            GROUP BY 1, 2
            ORDER BY documents DESC
            """
            )
        )
        .mappings()
        .all()
    )
    return [dict(row) for row in rows]
