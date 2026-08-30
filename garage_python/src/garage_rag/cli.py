"""``garage`` command line interface."""

from __future__ import annotations

import json
import os
import logging
from pathlib import Path
from typing import Annotated, Any, cast

import typer
from rich.console import Console
from rich.table import Table
from sqlalchemy import text

from garage_rag.config import (
    CONFIG_FILENAME,
    SCHEMA_URL,
    USER_CONFIG_FILENAME,
    ConfigError,
    Settings,
    candidate_paths,
    default_config_path,
    get_settings,
    json_schema,
    load_config,
    nest,
    repo_schema_path,
    save_config,
    set_settings,
)
from garage_rag.db.emb_tables import (
    drop_model,
    get_model,
    list_models,
    register_model,
    resolve_spec,
    set_default_model,
)
from garage_rag.db.engine import reset_engine, session_scope
from garage_rag.db.migrate import apply_migrations, schema_summary
from garage_rag.db.models import CorpusClass, Source, TrustTier

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
def main(
    verbose: Annotated[bool, typer.Option("--verbose", "-v")] = False,
    config: Annotated[
        Path | None,
        typer.Option(
            "--config",
            "-c",
            help=(f"Config file. Default: ./{CONFIG_FILENAME}, then ~/{USER_CONFIG_FILENAME}."),
        ),
    ] = None,
) -> None:
    _setup_logging(verbose)
    try:
        set_settings(load_config(config))
    except ConfigError as exc:
        console.print(f"[red]config error[/red]: {exc}")
        raise typer.Exit(code=2) from None

    # A leftover .env is worse than no .env: it looks like configuration and has
    # no effect. Say so rather than letting someone edit it for an hour.
    legacy = Path.cwd() / ".env"
    if legacy.is_file():
        console.print(
            f"[yellow]note[/yellow]: {legacy.name} is no longer read. Migrate it "
            f"with 'garage config init --from-env {legacy.name}', then delete it."
        )


# ---------------------------------------------------------------------------
# configuration
# ---------------------------------------------------------------------------
config_app = typer.Typer(help="Inspect and create the configuration file.", no_args_is_help=True)
app.add_typer(config_app, name="config")


@config_app.command("init")
def config_init(
    path: Annotated[
        Path | None, typer.Option("--path", help=f"Where to write. Default ./{CONFIG_FILENAME}.")
    ] = None,
    user: Annotated[
        bool,
        typer.Option("--user", help=f"Write to ~/{USER_CONFIG_FILENAME} instead of the project."),
    ] = False,
    from_env: Annotated[
        Path | None,
        typer.Option("--from-env", help="Migrate settings from a legacy .env file."),
    ] = None,
    force: Annotated[bool, typer.Option("--force", help="Overwrite an existing file.")] = False,
) -> None:
    """Write a configuration file with every setting at its default."""
    target = path or (default_config_path() if user else Path.cwd() / CONFIG_FILENAME)
    target = target.expanduser()

    if target.exists() and not force:
        console.print(f"[yellow]{target} already exists[/yellow]; pass --force to overwrite")
        raise typer.Exit(code=1)

    settings = Settings()
    migrated: list[str] = []
    if from_env is not None:
        settings, migrated = _settings_from_env_file(from_env.expanduser())

    save_config(settings, target)

    console.print(f"[green]wrote[/green] {target}")
    # No schema file is written beside the config: `$schema` names the published
    # URL, so editors resolve field documentation without a local copy.
    console.print(f"  [dim]$schema -> {SCHEMA_URL}[/dim]")
    if migrated:
        console.print(f"  migrated {len(migrated)} settings: {', '.join(migrated[:8])}")
        if len(migrated) > 8:
            console.print(f"  ...and {len(migrated) - 8} more")
    if not settings.self_name:
        console.print(
            "\n[yellow]next[/yellow]: set [cyan]identity.name[/cyan] and "
            "[cyan]identity.identities[/cyan] so your own writing can be told "
            "apart from reference material"
        )


def _settings_from_env_file(path: Path) -> tuple[Settings, list[str]]:
    """Translate a legacy GARAGE_* .env file into settings.

    Kept so upgrading does not silently lose a configured identity, which is the
    one setting that cannot be re-derived.
    """
    if not path.is_file():
        raise typer.BadParameter(f"{path} does not exist", param_hint="--from-env")

    # Legacy env name -> flat field. Only the names that ever existed.
    legacy = {f"GARAGE_{name.upper()}": name for name in Settings.model_fields}
    values: dict[str, Any] = {}
    migrated: list[str] = []

    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, _, raw = stripped.partition("=")
        field = legacy.get(key.strip())
        if field is None:
            continue
        raw = raw.strip().strip('"').strip("'")
        annotation = Settings.model_fields[field].annotation
        try:
            if annotation is bool:
                values[field] = raw.lower() in {"1", "true", "yes", "on"}
            elif annotation is int:
                values[field] = int(raw)
            elif annotation is float:
                values[field] = float(raw)
            elif annotation == list[str]:
                values[field] = json.loads(raw)
            else:
                values[field] = raw
        except (ValueError, json.JSONDecodeError):
            console.print(f"  [yellow]skipped[/yellow] {key}: cannot parse {raw!r}")
            continue
        migrated.append(field)

    return Settings(**values), migrated


@config_app.command("import-sources")
def config_import_sources(
    path: Annotated[
        Path | None, typer.Option("--path", help="Config file to update. Default: the one in use.")
    ] = None,
) -> None:
    """Copy the database's sources into the config file.

    Useful once, when moving from `add-source` to declared sources: it captures
    what already exists so the file becomes the source of truth without you
    retyping it.
    """
    from garage_rag.config import SourceSpec

    settings = get_settings()
    target = (path or settings.config_path or (Path.cwd() / CONFIG_FILENAME)).expanduser()

    with session_scope() as session:
        rows = session.query(Source).order_by(Source.slug).all()
        existing = {spec.slug for spec in settings.sources}
        added: list[str] = []
        for row in rows:
            if row.slug in existing:
                continue
            settings.sources.append(
                SourceSpec(
                    slug=row.slug,
                    root=str(row.root),
                    kind=row.kind,
                    **{"class": str(row.default_class)},
                    trust=str(row.default_trust),
                    include_code=bool((row.config or {}).get("include_code", False)),
                    allow_cloud_enrichment=bool(row.allow_cloud_enrichment),
                    enabled=bool(row.enabled),
                )
            )
            added.append(row.slug)

    if not added:
        console.print("[green]config already lists every database source[/green]")
        return

    save_config(settings, target)
    console.print(f"[green]added {len(added)} sources[/green] to {target}")
    for slug in added:
        console.print(f"  {slug}")


@config_app.command("show")
def config_show(
    defaults: Annotated[
        bool, typer.Option("--defaults/--diff", help="Show all values, or only overrides.")
    ] = True,
) -> None:
    """Print the effective configuration."""
    settings = get_settings()
    origin = settings.config_path or "(defaults; no file found)"
    console.print(f"[dim]loaded from: {origin}[/dim]")
    console.print(json.dumps(nest(settings, include_defaults=defaults), indent=2))


@config_app.command("path")
def config_path_cmd() -> None:
    """Show which config file is in use, and the search order."""
    settings = get_settings()
    console.print(f"in use : {settings.config_path or '[yellow](none)[/yellow]'}")
    console.print("search order:")
    for candidate in candidate_paths():
        mark = "[green]found[/green]" if candidate.is_file() else "[dim]absent[/dim]"
        console.print(f"  {mark}  {candidate}")


@config_app.command("schema")
def config_schema(
    path: Annotated[
        Path | None, typer.Option("--path", help="Write here instead of stdout.")
    ] = None,
    publish: Annotated[
        bool,
        typer.Option(
            "--publish",
            help="Write to the repository root, where it is committed and served from.",
        ),
    ] = False,
) -> None:
    """Emit the JSON Schema describing the config file.

    Use --publish after adding or renaming a setting, then commit the result so
    the URL in every config's $schema stays accurate.
    """
    payload = json.dumps(json_schema(), indent=2) + "\n"
    target = path.expanduser() if path else (repo_schema_path() if publish else None)
    if target is None:
        console.print_json(payload)
        return
    target.write_text(payload, encoding="utf-8")
    console.print(f"[green]wrote[/green] {target}")
    if publish:
        console.print(f"  [dim]commit it so {SCHEMA_URL} resolves[/dim]")


@app.command()
def sync(
    apply: Annotated[
        bool, typer.Option("--apply/--dry-run", help="Write changes to the database.")
    ] = True,
) -> None:
    """Apply sources declared in the config file to the database.

    Declared sources win: each is created or updated to match the file. Sources
    that exist only in the database are reported but never deleted, since that
    would discard indexed documents on the strength of an edit.
    """
    settings = get_settings()
    if not settings.sources:
        console.print(
            f"[yellow]no sources declared[/yellow] in {settings.config_path or 'the config file'}"
        )
        return

    created: list[str] = []
    updated: list[str] = []
    with session_scope() as session:
        declared = {spec.slug for spec in settings.sources}
        for spec in settings.sources:
            klass = CorpusClass(spec.corpus_class)
            tier = TrustTier(spec.trust)
            if klass is CorpusClass.COMMUNICATION and spec.allow_cloud_enrichment:
                console.print(
                    f"[red]{spec.slug}[/red]: communication sources may never "
                    "enable cloud enrichment"
                )
                raise typer.Exit(code=1)

            row = session.query(Source).filter_by(slug=spec.slug).one_or_none()
            if row is None:
                if apply:
                    session.add(
                        Source(
                            slug=spec.slug,
                            kind=spec.kind,
                            root=str(spec.expanded_root),
                            default_class=klass,
                            default_trust=tier,
                            allow_cloud_enrichment=spec.allow_cloud_enrichment,
                            enabled=spec.enabled,
                            config={"include_code": spec.include_code},
                        )
                    )
                created.append(spec.slug)
                continue

            changes = (
                row.kind != spec.kind
                or row.root != str(spec.expanded_root)
                or row.default_class != klass
                or row.default_trust != tier
                or row.allow_cloud_enrichment != spec.allow_cloud_enrichment
                or row.enabled != spec.enabled
            )
            if changes:
                if apply:
                    row.kind = spec.kind
                    row.root = str(spec.expanded_root)
                    row.default_class = klass
                    row.default_trust = tier
                    row.allow_cloud_enrichment = spec.allow_cloud_enrichment
                    row.enabled = spec.enabled
                    row.config = {**(row.config or {}), "include_code": spec.include_code}
                updated.append(spec.slug)

        # Rows are (slug, count) tuples, so unpack them rather than treating the
        # first element as an ORM object.
        undeclared = [
            (slug, int(count))
            for slug, count in session.execute(
                text(
                    "SELECT s.slug, count(d.id) FROM sources s "
                    "LEFT JOIN documents d ON d.source_id = s.id GROUP BY s.slug"
                )
            )
            if slug not in declared
        ]
        # No rollback needed: every mutation above is already gated on `apply`.

    verb = "" if apply else "would "
    if created:
        console.print(f"[green]{verb}create[/green]: {', '.join(created)}")
    if updated:
        console.print(f"[cyan]{verb}update[/cyan]: {', '.join(updated)}")
    if not created and not updated:
        console.print("[green]database already matches the config[/green]")
    if undeclared:
        console.print("\n[dim]in the database but not declared (left untouched):[/dim]")
        for slug, count in undeclared:
            console.print(f"  {slug} ({count:,} documents)")
        console.print(
            "  [dim]add them to the config, or remove with 'garage remove-source <slug>'[/dim]"
        )


# ---------------------------------------------------------------------------
# schema
# ---------------------------------------------------------------------------
@app.command("init-db")
def init_db(
    schema_dir: Annotated[
        Path | None,
        typer.Option("--schema-dir", help="Directory containing numbered SQL schema files."),
    ] = None,
) -> None:
    """Apply the schema: extensions, enums, core tables, model registry."""
    with session_scope() as session:
        applied = apply_migrations(session, schema_dir)
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
    provider: Annotated[
        str | None, typer.Option(help="Embedding backend: ollama | lmstudio.")
    ] = None,
    default: Annotated[bool, typer.Option("--default", help="Make this the default.")] = False,
) -> None:
    """Register an embedding model and create its table + index."""
    spec = resolve_spec(slug, dims=dims, model_ref=model_ref, provider=provider)
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
    for col in (
        "slug",
        "provider",
        "ref",
        "dims",
        "stored",
        "storage",
        "index",
        "table",
        "default",
    ):
        table.add_column(col)
    for m in models:
        table.add_row(
            m.slug,
            m.provider,
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
            console.print(f"[green]added source[/green] {slug} -> {expanded} ({klass}/{tier})")


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
            typer.confirm(f"Remove source {slug} and delete {count:,} documents?", abort=True)
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
    from garage_rag.db.engine import get_session_factory
    from garage_rag.ingest.pipeline import ingest_source

    factory = get_session_factory()
    if source == "*":
        with factory() as session:
            sources = [s.slug for s in session.query(Source).order_by(Source.id).all()]
    else:
        sources = [source]

    for source in sources:
        with console.status(f"ingesting {source}...") as status:
            # slug bound as a default: the closure outlives this loop iteration.
            def on_progress(counters, budget, slug=source) -> None:
                note = ""
                if budget.files_done or budget.deferred:
                    note = f" | downloaded {budget.files_done:,} deferred {budget.deferred:,}"
                status.update(
                    f"{slug}: seen {counters.seen:,} indexed {counters.indexed:,} "
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
                "(set placeholders.materialize = true in the config to download them)"
            )

        if counters.errors:
            console.print(f"\n[red]first {min(5, len(counters.errors))} errors[/red]:")
            for message in counters.errors[:5]:
                console.print(f"  {message}")


@app.command()
def backfill(
    model: Annotated[
        str | None, typer.Option("--model", "-m", help="Model slug. Default: all models.")
    ] = None,
    batch_size: Annotated[int | None, typer.Option(help="Chunks per request.")] = None,
    limit: Annotated[int | None, typer.Option(help="Stop after this many chunks.")] = None,
    verify: Annotated[
        bool, typer.Option("--verify/--no-verify", help="Probe the model's width first.")
    ] = True,
) -> None:
    """Embed chunks that a model has no vectors for. Pure insert; safe to re-run."""
    from garage_rag.embed.ollama import EmbeddingError, backfill_model, count_pending, verify_model_dims

    with session_scope() as session:
        targets = [get_model(session, model)] if model else list_models(session)
        if not targets:
            console.print("[yellow]no models registered[/yellow]")
            raise typer.Exit(code=1)

        for row in targets:
            pending = count_pending(session, row)
            if pending == 0:
                console.print(f"[green]{row.slug}[/green]: already complete")
                continue

            if verify:
                try:
                    ok, actual = verify_model_dims(row)
                except EmbeddingError as exc:
                    console.print(f"[red]{row.slug}[/red]: {exc}")
                    continue
                if not ok:
                    # Every insert would fail the column type check; stop now
                    # rather than after an hour of work.
                    console.print(
                        f"[red]{row.slug}[/red]: registered {row.dims} dims but the "
                        f"model emits {actual}. Re-register with --dims {actual}."
                    )
                    continue

            console.print(f"[cyan]{row.slug}[/cyan]: embedding {pending:,} chunks")
            with console.status(f"{row.slug}...") as status:

                def on_progress(state, slug=row.slug) -> None:
                    status.update(
                        f"{slug}: {state.embedded:,}/{state.total:,} ({state.batches} batches)"
                    )

                state = backfill_model(
                    session,
                    row,
                    batch_size=batch_size,
                    limit=limit,
                    progress=on_progress,
                )

            summary = f"embedded {state.embedded:,}"
            if state.failed:
                summary += f", [red]failed {state.failed:,}[/red]"
            if state.remaining:
                summary += f", remaining {state.remaining:,}"
            console.print(f"  {row.slug}: {summary}")


@app.command()
def reconcile(
    source: Annotated[str, typer.Option("--source", "-s", help="Source slug.")],
    apply: Annotated[
        bool, typer.Option("--apply", help="Actually delete. Default is a dry run.")
    ] = False,
    force: Annotated[
        bool, typer.Option("--force", help="Override the mass-deletion guard.")
    ] = False,
) -> None:
    """Delete documents whose source files no longer exist."""
    from garage_rag.ingest.reconcile import reconcile_source

    with session_scope() as session:
        result = reconcile_source(session, source, dry_run=not apply, force=force)

    if result.refused:
        console.print(f"[yellow]refused[/yellow]: {result.reason}")
        raise typer.Exit(code=1)

    if not result.candidates:
        console.print(f"[green]nothing to reconcile[/green] for {source}")
        return

    if apply:
        console.print(
            f"[green]deleted[/green] {result.deleted:,} of "
            f"{result.total_documents:,} documents from {source}"
        )
    else:
        console.print(
            f"[cyan]dry run[/cyan]: {result.candidates:,} of "
            f"{result.total_documents:,} documents in {source} are missing "
            f"({result.fraction:.1%}). Re-run with --apply to delete."
        )


# ---------------------------------------------------------------------------
# MCP
# ---------------------------------------------------------------------------
@app.command("mcp-install")
def mcp_install(
    target: Annotated[
        str,
        typer.Option(
            "--target",
            "-t",
            help="project | claude-desktop | lmstudio | cursor | vscode",
        ),
    ] = "project",
    path: Annotated[
        Path | None,
        typer.Option("--path", help="Write to this config file instead of a known target."),
    ] = None,
    name: Annotated[str, typer.Option("--name", help="Server name in the config.")] = "garage-rag",
    http: Annotated[
        bool,
        typer.Option(
            "--http",
            help="Register a URL for an already-running HTTP server instead of a spawned command.",
        ),
    ] = False,
    host: Annotated[str | None, typer.Option(help="HTTP host, with --http.")] = None,
    port: Annotated[int | None, typer.Option("--port", help="HTTP port, with --http.")] = None,
    path_route: Annotated[
        str | None, typer.Option("--route", help="HTTP route, with --http. Default /mcp.")
    ] = None,
    force: Annotated[
        bool, typer.Option("--force", help="Overwrite an existing entry of the same name.")
    ] = False,
    dry_run: Annotated[
        bool, typer.Option("--dry-run", help="Show what would be written, change nothing.")
    ] = False,
    yes: Annotated[bool, typer.Option("--yes", "-y", help="Do not prompt before writing.")] = False,
) -> None:
    """Register this MCP server in a client's config file.

    Merges into any existing config: other servers and unrelated keys are kept,
    the previous file is backed up, and the write is atomic.
    """
    from garage_rag.mcp_server.install import (
        ClientTarget,
        client_targets,
        http_url,
        install,
        server_command,
    )

    targets = client_targets()
    if path is not None:
        chosen = ClientTarget(key="custom", label="custom path", path=path.expanduser().resolve())
    else:
        if target not in targets:
            raise typer.BadParameter(
                f"unknown target {target!r}; choose from {', '.join(targets)}",
                param_hint="--target",
            )
        chosen = targets[target]

    console.print(f"[bold]{chosen.label}[/bold] -> {chosen.path}")

    url: str | None = None
    config_file: Path | None = None
    database_environment: dict[str, str] | None = None

    if http:
        settings = get_settings()
        url = http_url(
            host or settings.mcp_host,
            port or settings.mcp_port,
            path_route or settings.mcp_http_path,
        )
        console.print(f"  url     : {url}")
        # The client only connects; keeping the process alive is someone else's
        # job, so say so rather than letting it look like a spawned server.
        console.print(
            "  [dim]the client connects to this URL; run "
            "`garage mcp-serve --http` yourself to keep it up[/dim]"
        )
    else:
        # Point the server at this configuration explicitly: a client launches it
        # from an arbitrary cwd, where the config search order finds nothing.
        settings = get_settings()
        config_file = settings.config_path
        if config_file is None:
            console.print(
                "[yellow]note[/yellow]: no config file in use; the server will run "
                "on defaults. Create one with 'garage config init'."
            )
        command, args = server_command(config_file)
        console.print(f"  command : {command} {' '.join(args)}")
        if database_url := os.environ.get("GARAGE_DATABASE_URL"):
            database_environment = {"GARAGE_DATABASE_URL": database_url}

    if chosen.note:
        console.print(f"  [dim]{chosen.note}[/dim]")
    if chosen.project_scoped and not http:
        console.print(
            "  [yellow]note[/yellow]: project-scoped config records an absolute "
            "path to this virtualenv, which will not resolve on another machine"
        )

    try:
        preview = install(
            chosen,
            server_name=name,
            config_path=config_file,
            extra_env=database_environment,
            url=url,
            force=force,
            dry_run=True,
        )
    except FileExistsError as exc:
        console.print(f"[yellow]{exc}[/yellow]")
        raise typer.Exit(code=1) from None
    except RuntimeError as exc:
        console.print(f"[red]{exc}[/red]")
        raise typer.Exit(code=1) from None

    if preview.other_servers:
        console.print(f"  preserving: {', '.join(preview.other_servers)}")

    if dry_run:
        console.print("\n[cyan]would write[/cyan]:")
        console.print(json.dumps({"mcpServers": {name: preview.entry}}, indent=2))
        return

    action = "Replace" if preview.replaced_entry else "Add"
    if not yes:
        typer.confirm(f"{action} {name!r} in {chosen.path}?", abort=True)

    result = install(
        chosen,
        server_name=name,
        config_path=config_file,
        extra_env=database_environment,
        url=url,
        force=force,
    )
    verb = "created" if result.created_file else "updated"
    console.print(f"[green]{verb}[/green] {result.path}")
    if result.backup:
        console.print(f"  backup: {result.backup.name}")
    console.print(
        "\nRestart the client, then try: "
        "[cyan]what does my reference material say about secure boot?[/cyan]"
    )


@app.command("mcp-uninstall")
def mcp_uninstall(
    target: Annotated[str, typer.Option("--target", "-t")] = "project",
    path: Annotated[Path | None, typer.Option("--path")] = None,
    name: Annotated[str, typer.Option("--name")] = "garage-rag",
) -> None:
    """Remove this server from a client's config."""
    from garage_rag.mcp_server.install import ClientTarget, client_targets, uninstall

    targets = client_targets()
    if path is not None:
        chosen = ClientTarget("custom", "custom path", path.expanduser().resolve())
    elif target in targets:
        chosen = targets[target]
    else:
        raise typer.BadParameter(f"unknown target {target!r}", param_hint="--target")

    if uninstall(chosen, server_name=name):
        console.print(f"[green]removed[/green] {name} from {chosen.path}")
    else:
        console.print(f"[yellow]{name} was not configured in {chosen.path}[/yellow]")


@app.command("mcp-status")
def mcp_status() -> None:
    """Show which MCP clients this server is registered with."""
    from garage_rag.mcp_server.install import client_targets, installed_in, server_command

    command, args = server_command()
    console.print(f"[dim]server command: {command} {' '.join(args)}[/dim]\n")

    table = Table()
    for col in ("target", "client", "registered", "config"):
        table.add_column(col)
    for key, chosen in client_targets().items():
        if installed_in(chosen):
            state = "[green]yes[/green]"
        elif chosen.path.is_file():
            state = "no"
        else:
            state = "[dim]no config[/dim]"
        table.add_row(key, chosen.label, state, str(chosen.path).replace(str(Path.home()), "~"))
    console.print(table)


@app.command("mcp-serve")
def mcp_serve(
    stdio: Annotated[
        bool,
        typer.Option("--stdio", help="Serve on stdin/stdout. The default."),
    ] = False,
    http: Annotated[
        bool,
        typer.Option("--http", help="Serve over HTTP (streamable-http transport)."),
    ] = False,
    sse: Annotated[
        bool,
        typer.Option("--sse", help="Serve over the legacy SSE transport."),
    ] = False,
    host: Annotated[str | None, typer.Option(help="Bind address. Default 127.0.0.1.")] = None,
    port: Annotated[int | None, typer.Option("--port", "-p")] = None,
    path: Annotated[str | None, typer.Option("--path", help="HTTP route. Default /mcp.")] = None,
    allow_origin: Annotated[
        list[str] | None,
        typer.Option("--allow-origin", help="Permit this Origin (repeatable, for browsers)."),
    ] = None,
    json_response: Annotated[
        bool, typer.Option("--json-response", help="Reply with JSON instead of an SSE stream.")
    ] = False,
    stateless: Annotated[
        bool, typer.Option("--stateless", help="No session state between requests.")
    ] = False,
    allow_remote: Annotated[
        bool,
        typer.Option(
            "--allow-remote",
            help="Required to bind a non-loopback address. Read the warning first.",
        ),
    ] = False,
) -> None:
    """Run the MCP server.

    Defaults to stdio, which is how MCP clients spawn it. Use --http to serve
    several clients from one long-running process, or to reach it from a
    container or another host.
    """
    from garage_rag.mcp_server.server import is_loopback, serve

    if sum(map(bool, (stdio, http, sse))) > 1:
        raise typer.BadParameter("choose one of --stdio, --http, or --sse")

    if not (http or sse):
        # stdio speaks JSON-RPC on stdout; nothing else may write there.
        serve("stdio")
        return

    settings = get_settings()
    bind_host = host or settings.mcp_host
    bind_port = port or settings.mcp_port
    route = path or settings.mcp_http_path

    if not is_loopback(bind_host) and not allow_remote:
        # This server answers questions about the whole corpus -- potentially
        # including private communications -- and has no authentication
        # whatsoever. Binding it where others can reach it must be deliberate.
        console.print(
            f"[red]refusing to bind {bind_host}[/red]: this server has no "
            "authentication and exposes your entire corpus, including anything "
            "indexed from private communications."
        )
        console.print(
            "  Anyone able to reach that address could read it. If that is "
            "genuinely what you want, re-run with [bold]--allow-remote[/bold], "
            "and put it behind a reverse proxy that authenticates."
        )
        raise typer.Exit(code=1)

    transport = "sse" if sse else "streamable-http"
    scheme_note = " [dim](legacy transport)[/dim]" if sse else ""
    console.print(
        f"[green]serving[/green] {transport}{scheme_note} on http://{bind_host}:{bind_port}{route}"
    )
    if not is_loopback(bind_host):
        console.print("[yellow]warning[/yellow]: reachable from other machines, unauthenticated")
    console.print("[dim]Ctrl-C to stop[/dim]")

    try:
        serve(
            transport,
            host=bind_host,
            port=bind_port,
            path=route,
            allowed_origins=allow_origin or None,
            json_response=json_response,
            stateless=stateless,
        )
    except KeyboardInterrupt:
        console.print("\n[dim]stopped[/dim]")


# ---------------------------------------------------------------------------
# search
# ---------------------------------------------------------------------------
@app.command()
def search(
    query: Annotated[str, typer.Argument(help="What to look for.")],
    limit: Annotated[int, typer.Option("--limit", "-n")] = 10,
    mode: Annotated[str, typer.Option(help="hybrid | vector | fts")] = "hybrid",
    model: Annotated[str | None, typer.Option("--model", "-m")] = None,
    corpus_class: Annotated[
        list[str] | None,
        typer.Option("--class", help="document | code | communication (repeatable)"),
    ] = None,
    trust: Annotated[
        list[str] | None,
        typer.Option("--trust", help="authored | reference | received (repeatable)"),
    ] = None,
    source: Annotated[list[str] | None, typer.Option("--source", "-s")] = None,
    author: Annotated[str | None, typer.Option("--author")] = None,
    full: Annotated[bool, typer.Option("--full", help="Print whole snippets.")] = False,
) -> None:
    """Search the corpus with hybrid vector + keyword retrieval."""
    from garage_rag.search.hybrid import SearchMode
    from garage_rag.search.hybrid import search as run_search

    with session_scope() as session:
        hits = run_search(
            session,
            query,
            limit=limit,
            mode=cast(SearchMode, mode),
            model_slug=model,
            corpus_classes=corpus_class or None,
            trust_tiers=trust or None,
            sources=source or None,
            author=author,
        )

    if not hits:
        console.print("[yellow]no results[/yellow]")
        return

    for rank, hit in enumerate(hits, start=1):
        location = hit.uri.replace(str(Path.home()), "~")
        console.print(
            f"\n[bold cyan]{rank}.[/bold cyan] [bold]{hit.title or '(untitled)'}[/bold] "
            f"[dim]({hit.corpus_class}/{hit.trust_tier}, {hit.matched_by}, "
            f"score {hit.score:.4f})[/dim]"
        )
        console.print(f"   [dim]{location}[/dim]")
        if hit.heading_path:
            console.print(f"   [dim]section: {hit.heading_path}[/dim]")
        if hit.authors:
            console.print(f"   [dim]authors: {', '.join(hit.authors[:4])}[/dim]")
        body = hit.text if full else hit.text[:300].replace("\n", " ")
        console.print(f"   {body}")


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
    from garage_rag.extract.base import ExtractionError
    from garage_rag.extract.dispatch import extract as run_extract
    from garage_rag.extract.placeholder import PlaceholderFile
    from garage_rag.ingest.chunking import chunk_text

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
    console.print(f"  extractor : [cyan]{result.extractor}[/cyan] v{result.extractor_version}")
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
