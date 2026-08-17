"""Creation and lookup of the per-model embedding tables.

Registering a model creates exactly one table plus its index. Because the table
is keyed on ``chunk_id`` with ``ON DELETE CASCADE``, deleting a chunk removes its
vectors from every model table at once, with no application bookkeeping. That is
what makes re-indexing safe and idempotency cheap.
"""

from __future__ import annotations

import logging
import re

from sqlalchemy import text
from sqlalchemy.orm import Session

from ..embed.registry import (
    KNOWN_MODELS,
    ModelSpec,
    StoragePlan,
    column_type_sql,
    index_ddl,
    plan_storage,
    table_name_for,
)
from .models import EmbeddingModel

log = logging.getLogger(__name__)

# Matches the CHECK constraint in sql/003_registry.sql. Validated again here
# because these identifiers are interpolated into DDL and search SQL, where bind
# parameters are not usable.
_TABLE_RE = re.compile(r"^emb_[a-z0-9_]+$")


def assert_safe_table(name: str) -> str:
    """Reject any table name that is not a registry-shaped identifier."""
    if not _TABLE_RE.match(name):
        raise ValueError(f"unsafe embedding table name: {name!r}")
    return name


def create_embedding_table(session: Session, table: str, plan: StoragePlan) -> None:
    """Create one per-model embedding table and its vector index."""
    assert_safe_table(table)
    coltype = column_type_sql(plan)

    session.execute(
        text(
            f"""
            CREATE TABLE IF NOT EXISTS {table} (
                chunk_id    bigint PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,
                embedding   {coltype} NOT NULL,
                embedded_at timestamptz NOT NULL DEFAULT now()
            )
            """
        )
    )

    ddl = index_ddl(table, plan)
    if ddl:
        session.execute(text(ddl))
    else:
        log.warning("model table %s created without a vector index", table)


def resolve_spec(slug: str, *, dims: int | None = None, model_ref: str | None = None) -> ModelSpec:
    """Look up a known model, or build a spec from explicit arguments."""
    known = KNOWN_MODELS.get(slug)
    if known is not None:
        if dims is not None and dims != known.dims:
            # Trust the caller: a quantized or MRL-truncated pull can differ.
            return ModelSpec(
                slug=known.slug,
                model_ref=model_ref or known.model_ref,
                dims=dims,
                provider=known.provider,
                normalized=known.normalized,
                supports_mrl=known.supports_mrl,
            )
        return known

    if dims is None:
        raise ValueError(
            f"model {slug!r} is not in the known-model table; pass --dims explicitly"
        )
    return ModelSpec(slug=slug, model_ref=model_ref or slug, dims=dims)


def register_model(
    session: Session,
    spec: ModelSpec,
    *,
    make_default: bool = False,
) -> EmbeddingModel:
    """Register a model and create its table. Idempotent on ``slug``."""
    existing = session.query(EmbeddingModel).filter_by(slug=spec.slug).one_or_none()
    if existing is not None:
        if make_default:
            set_default_model(session, existing.slug)
        return existing

    plan = plan_storage(spec.dims, supports_mrl=spec.supports_mrl)
    table = table_name_for(spec.slug)

    if plan.is_truncated:
        log.warning(
            "%s is %d-dim, above the halfvec HNSW ceiling; storing %d dims "
            "via Matryoshka truncation",
            spec.slug,
            spec.dims,
            plan.stored_dims,
        )
    if plan.index_kind == "hnsw_bq":
        log.warning(
            "%s is %d-dim and not MRL-capable; indexing a binary quantization "
            "and re-ranking on exact cosine at query time",
            spec.slug,
            spec.dims,
        )

    create_embedding_table(session, table, plan)

    row = EmbeddingModel(
        slug=spec.slug,
        provider=spec.provider,
        model_ref=spec.model_ref,
        dims=spec.dims,
        stored_dims=plan.stored_dims,
        storage_kind=plan.storage_kind,
        index_kind=plan.index_kind,
        normalized=spec.normalized,
        table_name=table,
        is_default=False,
    )
    session.add(row)
    session.flush()

    # First model registered becomes the default unless told otherwise.
    if make_default or session.query(EmbeddingModel).count() == 1:
        set_default_model(session, spec.slug)

    return row


def set_default_model(session: Session, slug: str) -> None:
    """Point the default at ``slug``, clearing any previous default first.

    Two statements rather than one, because a partial unique index enforces at
    most one default and a single UPDATE could transiently violate it.
    """
    session.execute(text("UPDATE embedding_models SET is_default = false WHERE is_default"))
    session.execute(
        text("UPDATE embedding_models SET is_default = true WHERE slug = :slug"),
        {"slug": slug},
    )


def get_model(session: Session, slug: str | None = None) -> EmbeddingModel:
    """Fetch a model by slug, or the default when ``slug`` is None."""
    query = session.query(EmbeddingModel)
    row = (
        query.filter_by(slug=slug).one_or_none()
        if slug
        else query.filter_by(is_default=True).one_or_none()
    )
    if row is None:
        which = f"model {slug!r}" if slug else "default model"
        raise LookupError(f"no {which} registered; run 'garage register-model' first")
    return row


def list_models(session: Session) -> list[EmbeddingModel]:
    return session.query(EmbeddingModel).order_by(EmbeddingModel.id).all()


def drop_model(session: Session, slug: str) -> None:
    """Deregister a model and drop its table, discarding its vectors."""
    row = get_model(session, slug)
    table = assert_safe_table(row.table_name)
    session.execute(text(f"DROP TABLE IF EXISTS {table}"))
    session.delete(row)
