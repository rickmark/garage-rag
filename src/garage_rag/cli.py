"""``garage`` command line interface."""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Annotated

import typer
from rich.console import Console
from rich.table import Table
from sqlalchemy import text

from .config import get_settings
from .db.emb_tables import (
    drop_model,
    get_model,
    list_models,
    register_model,
    resolve_spec,
    set_default_model,
)
from .db.engine import reset_engine, session_scope
from .db.migrate import apply_migrations, schema_summary
from .db.models import CorpusClass, Source, TrustTier

app = typer.Typer(
    add_completion=False,
    help="Local-first personal RAG pipeline over Postgres + pgvector.",
    no_args_is_help=True,
)
console = Console()


def _setup_logging(verbose: bool) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(levelname)s %(name)s: %(message)s",
    )


@app.callback()
def main(verbose: Annotated[bool, typer.Option("--verbose", "-v")] = False) -> None:
    _setup_logging(verbose)


# ---------------------------------------------------------------------------
# schema
# ---------------------------------------------------------------------------
@app.command("init-db")
def init_db() -> None:
    """Apply the schema: extensions, enums, core tables, model registry."""
    with session_scope() as session:
        applied = apply_migrations(session)
    # Connections opened before the `vector` extension existed have no vector
    # types registered. Discard the pool so later work gets fresh connections.
    reset_engine()
    for name in applied:
        console.print(f"  applied [cyan]{name}[/cyan]")
    console.print(f"[green]schema ready[/green] ({get_settings().database_url})")


@app.command()
def stats() -> None:
    """Row counts across the corpus."""
    with session_scope() as session:
        summary = schema_summary(session)
        models = list_models(session)
        model_rows = [
            (
                m.slug,
                f"{m.dims}",
                f"{m.storage_kind}({m.stored_dims})",
                m.index_kind,
                "yes" if m.is_default else "",
                f"{session.execute(text(f'SELECT count(*) FROM {m.table_name}')).scalar_one():,}",
            )
            for m in models
        ]

    table = Table(title="corpus")
    table.add_column("table")
    table.add_column("rows", justify="right")
    for name, count in summary.items():
        table.add_row(name, f"{count:,}")
    console.print(table)

    if model_rows:
        mt = Table(title="embedding models")
        for col in ("slug", "dims", "storage", "index", "default", "vectors"):
            mt.add_column(col, justify="right" if col in {"dims", "vectors"} else "left")
        for row in model_rows:
            mt.add_row(*row)
        console.print(mt)


# ---------------------------------------------------------------------------
# embedding models
# ---------------------------------------------------------------------------
@app.command("register-model")
def register_model_cmd(
    slug: Annotated[str, typer.Argument(help="Model slug, e.g. bge-m3.")],
    dims: Annotated[
        int | None, typer.Option(help="Output width. Required for unknown models.")
    ] = None,
    model_ref: Annotated[
        str | None, typer.Option(help="Provider-side name, if it differs from the slug.")
    ] = None,
    default: Annotated[bool, typer.Option("--default", help="Make this the default.")] = False,
) -> None:
    """Register an embedding model and create its table + index."""
    spec = resolve_spec(slug, dims=dims, model_ref=model_ref)
    with session_scope() as session:
        row = register_model(session, spec, make_default=default)
        console.print(
            f"[green]registered[/green] {row.slug}: {row.dims}-dim -> "
            f"{row.storage_kind}({row.stored_dims}), index={row.index_kind}, "
            f"table={row.table_name}"
        )
        if row.stored_dims < row.dims:
            console.print(
                f"  [yellow]note[/yellow]: truncated {row.dims} -> {row.stored_dims} "
                "(Matryoshka) to fit the halfvec HNSW ceiling"
            )
        if row.index_kind == "hnsw_bq":
            console.print(
                "  [yellow]note[/yellow]: binary-quantized index; queries re-rank on exact cosine"
            )


@app.command("list-models")
def list_models_cmd() -> None:
    """List registered embedding models."""
    with session_scope() as session:
        models = list_models(session)
    if not models:
        console.print("[yellow]no models registered[/yellow]")
        return
    table = Table()
    for col in ("slug", "ref", "dims", "stored", "storage", "index", "table", "default"):
        table.add_column(col)
    for m in models:
        table.add_row(
            m.slug,
            m.model_ref,
            str(m.dims),
            str(m.stored_dims),
            m.storage_kind,
            m.index_kind,
            m.table_name,
            "*" if m.is_default else "",
        )
    console.print(table)


@app.command("set-default-model")
def set_default_model_cmd(slug: str) -> None:
    """Point the default embedding model at SLUG."""
    with session_scope() as session:
        get_model(session, slug)
        set_default_model(session, slug)
    console.print(f"[green]default model[/green] = {slug}")


@app.command("drop-model")
def drop_model_cmd(
    slug: str,
    yes: Annotated[bool, typer.Option("--yes", help="Skip confirmation.")] = False,
) -> None:
    """Deregister a model and drop its vectors."""
    if not yes:
        typer.confirm(f"Drop model {slug} and discard all its vectors?", abort=True)
    with session_scope() as session:
        drop_model(session, slug)
    console.print(f"[green]dropped[/green] {slug}")


# ---------------------------------------------------------------------------
# sources
# ---------------------------------------------------------------------------
@app.command("add-source")
def add_source(
    slug: Annotated[str, typer.Argument(help="Short name, e.g. dropbox.")],
    root: Annotated[Path, typer.Argument(help="Directory or file to index.")],
    kind: Annotated[
        str, typer.Option(help="filesystem | git | sqlite | maildir | feed")
    ] = "filesystem",
    corpus_class: Annotated[
        str,
        typer.Option(
            "--class",
            help="Default grouping: document | code | communication",
        ),
    ] = "document",
    trust: Annotated[
        str, typer.Option(help="Default trust: authored | reference | received")
    ] = "authored",
    allow_cloud: Annotated[
        bool,
        typer.Option(
            "--allow-cloud-enrichment",
            help="Permit cloud OCR fallback for this source. Never valid for communications.",
        ),
    ] = False,
) -> None:
    """Register a source root to be walked."""
    tier = TrustTier(trust)
    klass = CorpusClass(corpus_class)
    # Egress guard, level 3: keyed on the class, since "is this a private
    # conversation" is a property of what the content is, not how trusted it is.
    if klass is CorpusClass.COMMUNICATION and allow_cloud:
        raise typer.BadParameter(
            "communication sources may never enable cloud enrichment",
            param_hint="--allow-cloud-enrichment",
        )

    expanded = root.expanduser()
    if not expanded.exists():
        raise typer.BadParameter(f"{expanded} does not exist", param_hint="ROOT")

    with session_scope() as session:
        existing = session.query(Source).filter_by(slug=slug).one_or_none()
        if existing is not None:
            existing.root = str(expanded)
            existing.kind = kind
            existing.default_trust = tier
            existing.default_class = klass
            existing.allow_cloud_enrichment = allow_cloud
            console.print(f"[green]updated source[/green] {slug} -> {expanded}")
        else:
            session.add(
                Source(
                    slug=slug,
                    kind=kind,
                    root=str(expanded),
                    default_trust=tier,
                    default_class=klass,
                    allow_cloud_enrichment=allow_cloud,
                )
            )
            console.print(
                f"[green]added source[/green] {slug} -> {expanded} ({klass}/{tier})"
            )


@app.command("remove-source")
def remove_source(
    slug: str,
    yes: Annotated[bool, typer.Option("--yes", help="Skip confirmation.")] = False,
) -> None:
    """Deregister a source and delete its documents, chunks, and vectors."""
    with session_scope() as session:
        source = session.query(Source).filter_by(slug=slug).one_or_none()
        if source is None:
            console.print(f"[yellow]no such source[/yellow]: {slug}")
            raise typer.Exit(code=1)
        count = session.execute(
            text("SELECT count(*) FROM documents WHERE source_id = :sid"),
            {"sid": source.id},
        ).scalar_one()
        if not yes:
            typer.confirm(
                f"Remove source {slug} and delete {count:,} documents?", abort=True
            )
        # Cascades through chunks into every per-model embedding table.
        session.delete(source)
    console.print(f"[green]removed[/green] {slug} ({count:,} documents)")


@app.command("list-sources")
def list_sources() -> None:
    """List registered sources."""
    with session_scope() as session:
        sources = session.query(Source).order_by(Source.id).all()
    if not sources:
        console.print("[yellow]no sources registered[/yellow]")
        return
    table = Table()
    for col in ("slug", "kind", "class", "trust", "cloud", "enabled", "root"):
        table.add_column(col)
    for s in sources:
        table.add_row(
            s.slug,
            s.kind,
            str(s.default_class),
            str(s.default_trust),
            "yes" if s.allow_cloud_enrichment else "no",
            "yes" if s.enabled else "no",
            s.root,
        )
    console.print(table)


# ---------------------------------------------------------------------------
# ingest
# ---------------------------------------------------------------------------
@app.command()
def ingest(
    source: Annotated[str, typer.Option("--source", "-s", help="Source slug to walk.")],
    include_code: Annotated[
        bool,
        typer.Option("--include-code", help="Also index source files, not just documents."),
    ] = False,
    limit: Annotated[
        int | None, typer.Option(help="Stop after this many candidates (for trials).")
    ] = None,
    force: Annotated[
        bool, typer.Option("--force", help="Re-extract and re-chunk even if unchanged.")
    ] = False,
) -> None:
    """Walk a source and index it. Safe to re-run; unchanged files are skipped."""
    from .db.engine import get_session_factory
    from .ingest.pipeline import ingest_source

    factory = get_session_factory()
    if source == '*':
        with factory() as session:
            sources = [s.slug for s in session.query(Source).order_by(Source.id).all()]
    else:
        sources = [source]

    for source in sources:
        with console.status(f"ingesting {source}...") as status:
            def on_progress(counters, budget) -> None:
                note = ""
                if budget.files_done or budget.deferred:
                    note = f" | downloaded {budget.files_done:,} deferred {budget.deferred:,}"
                status.update(
                    f"{source}: seen {counters.seen:,} indexed {counters.indexed:,} "
                    f"skipped {counters.skipped:,} failed {counters.failed:,}{note}"
                )


            counters, walk_stats, budget = ingest_source(
                factory,
                source,
                include_code=include_code,
                limit=limit,
                force=force,
                progress=on_progress,
            )


        table = Table(title=f"ingest: {source}")
        table.add_column("metric")
        table.add_column("count", justify="right")
        for label, value in (
            ("candidates seen", counters.seen),
            ("indexed", counters.indexed),
            ("skipped (unchanged)", counters.skipped),
            ("failed", counters.failed),
            ("rejected: machine-generated", counters.rejected),
            ("chunks written", counters.chunks_written),
            ("placeholders pending", counters.placeholders),
            ("dirs walked", walk_stats.dirs),
            ("files examined", walk_stats.files_seen),
            ("skipped: not indexable", walk_stats.skipped_extension),
            ("skipped: diagnostic", walk_stats.skipped_diagnostic),
            ("skipped: code", walk_stats.skipped_code),
            ("skipped: too large", walk_stats.skipped_too_large),
        ):
            table.add_row(label, f"{value:,}")
        console.print(table)

        if budget.enabled:
            console.print(f"[cyan]placeholders[/cyan]: {budget.summary()}")
            if budget.deferred:
                console.print(
                    "  [yellow]budget reached[/yellow]: re-run to continue "
                    "(unchanged files are skipped, so progress accumulates)"
                )
        elif counters.placeholders:
            console.print(
                f"[yellow]{counters.placeholders:,} placeholders skipped[/yellow] "
                "(set GARAGE_MATERIALIZE_PLACEHOLDERS=true to download them)"
            )

        if counters.errors:
            console.print(f"\n[red]first {min(5, len(counters.errors))} errors[/red]:")
            for message in counters.errors[:5]:
                console.print(f"  {message}")


# ---------------------------------------------------------------------------
# extraction / chunking inspection
# ---------------------------------------------------------------------------
@app.command("extract")
def extract_cmd(
    path: Annotated[Path, typer.Argument(help="File to extract and chunk.")],
    show: Annotated[int, typer.Option(help="How many chunks to print.")] = 3,
    full: Annotated[bool, typer.Option("--full", help="Print whole chunks.")] = False,
) -> None:
    """Extract and chunk a single file without touching the database."""
    from .extract.base import ExtractionError
    from .extract.dispatch import extract as run_extract
    from .extract.placeholder import PlaceholderFile
    from .ingest.chunking import chunk_text

    target = path.expanduser()
    try:
        result = run_extract(target)
    except PlaceholderFile as exc:
        # Not a parser problem: the bytes are not on this machine.
        console.print(f"[yellow]placeholder[/yellow] ({exc.provider}): {target}")
        console.print("  no local content; make it available offline, then re-run")
        raise typer.Exit(code=2) from None
    except ExtractionError as exc:
        console.print(f"[red]extraction failed[/red]: {exc}")
        raise typer.Exit(code=1) from None

    chunks = chunk_text(
        result.text,
        result.kind,
        extension=target.suffix.lower(),
    )

    console.print(f"[bold]{target}[/bold]")
    console.print(
        f"  extractor : [cyan]{result.extractor}[/cyan] v{result.extractor_version}"
    )
    console.print(f"  kind      : {result.kind}")
    console.print(f"  title     : {result.title!r}")
    console.print(f"  chars     : {len(result.text):,}")
    console.print(f"  chunks    : {len(chunks)}")
    if chunks:
        sizes = [len(c.text) for c in chunks]
        console.print(
            f"  chunk len : min={min(sizes)} median="
            f"{sorted(sizes)[len(sizes) // 2]} max={max(sizes)}"
        )
        console.print(f"  chunker   : {chunks[0].chunker}")
    if result.meta:
        console.print(f"  meta      : {result.meta}")
    if result.author_hints:
        console.print(f"  author?   : {result.author_hints}")

    for chunk in chunks[:show]:
        console.print()
        header = f"[dim]--- chunk {chunk.ord} ({len(chunk.text)} chars)"
        if chunk.heading_path:
            header += f" | {chunk.heading_path}"
        console.print(header + " ---[/dim]")
        body = chunk.text if full else chunk.text[:400]
        console.print(body + ("" if full or len(chunk.text) <= 400 else " [dim]...[/dim]"))


if __name__ == "__main__":
    app()
