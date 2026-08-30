from pathlib import Path

from garage_rag.db.migrate import migration_files


def test_migration_files_uses_supplied_schema_directory(tmp_path: Path) -> None:
    (tmp_path / "001_schema.sql").write_text("-- schema", encoding="utf-8")
    (tmp_path / "notes.sql").write_text("-- ignored", encoding="utf-8")

    assert migration_files(tmp_path) == [tmp_path / "001_schema.sql"]
