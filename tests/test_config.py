"""The single-file configuration.

The invariants that matter: the nested file and the flat model cannot drift, a
typo is reported rather than ignored, and no setting is reachable only through an
environment variable.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from garage_rag.config import (
    CONFIG_FILENAME,
    SECTIONS,
    ConfigError,
    Settings,
    SourceSpec,
    USER_CONFIG_FILENAME,
    candidate_paths,
    flatten,
    default_config_path,
    json_schema,
    load_config,
    nest,
    save_config,
)


class TestSectionMapping:
    def test_every_field_is_reachable_from_the_file(self) -> None:
        """A setting absent from SECTIONS could never be configured at all."""
        mapped = {field for mapping in SECTIONS.values() for field in mapping.values()}
        mapped |= {"sources", "config_path"}
        unreachable = set(Settings.model_fields) - mapped
        assert not unreachable, f"unreachable settings: {sorted(unreachable)}"

    def test_no_field_is_mapped_twice(self) -> None:
        seen: set[str] = set()
        for mapping in SECTIONS.values():
            for field in mapping.values():
                assert field not in seen, f"{field} mapped in two sections"
                seen.add(field)

    def test_every_mapped_field_exists(self) -> None:
        for section, mapping in SECTIONS.items():
            for key, field in mapping.items():
                assert field in Settings.model_fields, f"{section}.{key} -> {field}"


class TestRoundTrip:
    def test_defaults_round_trip(self) -> None:
        original = Settings()
        restored = Settings(**flatten(nest(original)))
        assert restored.model_dump(exclude={"config_path"}) == original.model_dump(
            exclude={"config_path"}
        )

    def test_non_defaults_round_trip(self) -> None:
        original = Settings(
            database_url="postgresql+psycopg:///other",
            chunk_size=512,
            self_identities=["git_email:a@b.c"],
            materialize_placeholders=True,
            ocr_min_confidence=42.5,
            api_key_file="~/.secret",
        )
        restored = Settings(**flatten(nest(original)))
        assert restored.chunk_size == 512
        assert restored.self_identities == ["git_email:a@b.c"]
        assert restored.materialize_placeholders is True
        assert restored.ocr_min_confidence == 42.5
        assert restored.api_key_file == "~/.secret"

    def test_diff_view_omits_defaults(self) -> None:
        settings = Settings(chunk_size=999)
        document = nest(settings, include_defaults=False)
        assert document["chunking"] == {"size": 999}
        assert "extraction" not in document


class TestLoading:
    def _write(self, path: Path, document: dict) -> Path:
        path.write_text(json.dumps(document), encoding="utf-8")
        return path

    def test_loads_nested_file(self, tmp_path: Path) -> None:
        cfg = self._write(
            tmp_path / CONFIG_FILENAME,
            {"database": {"url": "postgresql+psycopg:///x"}, "chunking": {"size": 250}},
        )
        settings = load_config(cfg)
        assert settings.database_url == "postgresql+psycopg:///x"
        assert settings.chunk_size == 250
        assert settings.config_path == cfg

    def test_unset_values_fall_back_to_defaults(self, tmp_path: Path) -> None:
        cfg = self._write(tmp_path / CONFIG_FILENAME, {"chunking": {"size": 1}})
        assert load_config(cfg).chunk_overlap == Settings().chunk_overlap

    def test_schema_key_is_ignored(self, tmp_path: Path) -> None:
        cfg = self._write(
            tmp_path / CONFIG_FILENAME, {"$schema": "./garage.schema.json", "mcp": {"port": 1}}
        )
        assert load_config(cfg).mcp_port == 1

    def test_unknown_section_is_an_error(self, tmp_path: Path) -> None:
        """A silently ignored typo is a bug found hours later."""
        cfg = self._write(tmp_path / CONFIG_FILENAME, {"chunkng": {"size": 1}})
        with pytest.raises(ConfigError, match="unknown section"):
            load_config(cfg)

    def test_unknown_key_is_an_error(self, tmp_path: Path) -> None:
        cfg = self._write(tmp_path / CONFIG_FILENAME, {"chunking": {"sizee": 1}})
        with pytest.raises(ConfigError, match="unknown key"):
            load_config(cfg)

    def test_error_names_the_valid_keys(self, tmp_path: Path) -> None:
        cfg = self._write(tmp_path / CONFIG_FILENAME, {"chunking": {"nope": 1}})
        with pytest.raises(ConfigError, match="overlap"):
            load_config(cfg)

    def test_malformed_json_is_an_error(self, tmp_path: Path) -> None:
        cfg = tmp_path / CONFIG_FILENAME
        cfg.write_text("{not json", encoding="utf-8")
        with pytest.raises(ConfigError, match="not valid JSON"):
            load_config(cfg)

    def test_wrong_type_is_an_error(self, tmp_path: Path) -> None:
        cfg = self._write(tmp_path / CONFIG_FILENAME, {"chunking": {"size": "big"}})
        with pytest.raises(ConfigError):
            load_config(cfg)

    def test_section_must_be_an_object(self, tmp_path: Path) -> None:
        cfg = self._write(tmp_path / CONFIG_FILENAME, {"chunking": [1, 2]})
        with pytest.raises(ConfigError, match="must be an object"):
            load_config(cfg)

    def test_explicit_missing_path_is_an_error(self, tmp_path: Path) -> None:
        with pytest.raises(ConfigError, match="no config file found"):
            load_config(tmp_path / "absent.json")

    def test_no_file_anywhere_yields_defaults(self, tmp_path: Path, monkeypatch) -> None:
        monkeypatch.chdir(tmp_path)
        monkeypatch.setattr(Path, "home", classmethod(lambda cls: tmp_path))
        settings = load_config()
        assert settings.chunk_size == Settings().chunk_size
        assert settings.config_path is None

    def test_search_order_prefers_project_over_user(self, tmp_path: Path, monkeypatch) -> None:
        monkeypatch.chdir(tmp_path)
        assert candidate_paths()[0] == tmp_path / CONFIG_FILENAME

    def test_default_is_a_home_dotfile(self, tmp_path: Path, monkeypatch) -> None:
        """The documented default: ~/.garage.json."""
        monkeypatch.setattr(Path, "home", classmethod(lambda cls: tmp_path))
        assert default_config_path() == tmp_path / ".garage.json"
        assert USER_CONFIG_FILENAME == ".garage.json"
        assert candidate_paths()[-1] == tmp_path / ".garage.json"

    def test_user_default_is_found_when_no_project_file(
        self, tmp_path: Path, monkeypatch
    ) -> None:
        home = tmp_path / "home"
        work = tmp_path / "work"
        home.mkdir()
        work.mkdir()
        monkeypatch.setattr(Path, "home", classmethod(lambda cls: home))
        monkeypatch.chdir(work)
        (home / ".garage.json").write_text(json.dumps({"mcp": {"port": 4242}}))
        settings = load_config()
        assert settings.mcp_port == 4242
        assert settings.config_path == home / ".garage.json"


class TestSaving:
    def test_save_then_load(self, tmp_path: Path) -> None:
        settings = Settings(chunk_size=321, self_name="Someone")
        path = tmp_path / CONFIG_FILENAME
        save_config(settings, path)
        loaded = load_config(path)
        assert loaded.chunk_size == 321
        assert loaded.self_name == "Someone"

    def test_saved_file_references_the_schema(self, tmp_path: Path) -> None:
        """JSON has no comments, so the schema is where documentation lives."""
        path = tmp_path / CONFIG_FILENAME
        save_config(Settings(), path)
        assert json.loads(path.read_text())["$schema"].endswith("garage.schema.json")

    def test_creates_parent_directories(self, tmp_path: Path) -> None:
        path = tmp_path / "a" / "b" / CONFIG_FILENAME
        save_config(Settings(), path)
        assert path.is_file()

    def test_no_temp_file_left_behind(self, tmp_path: Path) -> None:
        path = tmp_path / CONFIG_FILENAME
        save_config(Settings(), path)
        assert not list(tmp_path.glob("*.tmp"))


class TestSources:
    def test_class_uses_the_reserved_word_alias(self) -> None:
        """`class` is a Python keyword, so the field is corpus_class internally."""
        spec = SourceSpec(slug="a", root="~/x", **{"class": "code"})
        assert spec.corpus_class == "code"
        assert spec.model_dump(by_alias=True)["class"] == "code"

    def test_root_expansion(self) -> None:
        spec = SourceSpec(slug="a", root="~/Documents")
        assert spec.expanded_root.is_absolute()
        assert "~" not in str(spec.expanded_root)

    def test_defaults(self) -> None:
        spec = SourceSpec(slug="a", root="/x")
        assert spec.kind == "filesystem"
        assert spec.corpus_class == "document"
        assert spec.trust == "authored"
        assert spec.include_code is False
        assert spec.allow_cloud_enrichment is False
        assert spec.enabled is True

    def test_unknown_source_key_is_rejected(self) -> None:
        with pytest.raises(Exception, match="extra_forbidden|Extra inputs"):
            SourceSpec(slug="a", root="/x", clas="document")

    def test_sources_load_from_file(self, tmp_path: Path) -> None:
        cfg = tmp_path / CONFIG_FILENAME
        cfg.write_text(
            json.dumps(
                {
                    "sources": [
                        {"slug": "notes", "root": "~/Documents", "class": "document"},
                        {"slug": "code", "root": "~/dev", "class": "code", "include_code": True},
                    ]
                }
            )
        )
        settings = load_config(cfg)
        assert [s.slug for s in settings.sources] == ["notes", "code"]
        assert settings.source("code").include_code is True
        assert settings.source("missing") is None

    def test_sources_must_be_a_list(self, tmp_path: Path) -> None:
        cfg = tmp_path / CONFIG_FILENAME
        cfg.write_text(json.dumps({"sources": {"slug": "x"}}))
        with pytest.raises(ConfigError, match="must be a list"):
            load_config(cfg)


class TestApiKeyFile:
    def test_reads_key_from_file(self, tmp_path: Path) -> None:
        key = tmp_path / "anthropic.key"
        key.write_text("sk-ant-secret\n")
        assert Settings(api_key_file=str(key)).read_api_key() == "sk-ant-secret"

    def test_none_when_unconfigured(self) -> None:
        assert Settings().read_api_key() is None

    def test_none_when_file_missing(self, tmp_path: Path) -> None:
        """Degrade to local-only rather than failing the whole run."""
        assert Settings(api_key_file=str(tmp_path / "absent")).read_api_key() is None

    def test_none_when_file_is_empty(self, tmp_path: Path) -> None:
        blank = tmp_path / "blank"
        blank.write_text("   \n")
        assert Settings(api_key_file=str(blank)).read_api_key() is None

    def test_config_itself_holds_no_secret(self, tmp_path: Path) -> None:
        """The file names a key path; it never contains the key."""
        key = tmp_path / "k"
        key.write_text("sk-ant-secret")
        path = tmp_path / CONFIG_FILENAME
        save_config(Settings(api_key_file=str(key)), path)
        assert "sk-ant-secret" not in path.read_text()


class TestIdentityParsing:
    def test_pairs(self) -> None:
        settings = Settings(
            self_identities=["git_email:a@b.c", "handle:@me", "malformed"]
        )
        assert settings.self_identity_pairs() == [
            ("git_email", "a@b.c"),
            ("handle", "@me"),
        ]

    def test_whitespace_tolerated(self) -> None:
        assert Settings(self_identities=[" email : a@b.c "]).self_identity_pairs() == [
            ("email", "a@b.c")
        ]


class TestSchema:
    def test_covers_every_section(self) -> None:
        properties = json_schema()["properties"]
        for section in SECTIONS:
            assert section in properties

    def test_forbids_unknown_keys(self) -> None:
        schema = json_schema()
        assert schema["additionalProperties"] is False
        for section in SECTIONS:
            assert schema["properties"][section]["additionalProperties"] is False

    def test_descriptions_present_where_documented(self) -> None:
        """The schema is where documentation lives, since JSON has no comments."""
        props = json_schema()["properties"]
        assert props["identity"]["properties"]["identities"]["description"]
        assert props["placeholders"]["properties"]["materialize"]["description"]

    def test_list_field_typed_as_array(self) -> None:
        """Regression: `annotation is list[str]` never matched, so this was untyped."""
        entry = json_schema()["properties"]["identity"]["properties"]["identities"]
        assert entry["type"] == "array"
        assert entry["items"] == {"type": "string"}

    def test_sources_schema_requires_slug_and_root(self) -> None:
        sources = json_schema()["properties"]["sources"]
        assert sources["items"]["required"] == ["slug", "root"]
        assert "class" in sources["items"]["properties"]


class TestNoEnvironmentDependence:
    def test_settings_ignore_garage_env_vars(self, monkeypatch, tmp_path: Path) -> None:
        """Env vars were deliberately removed; a stale one must not leak back in."""
        monkeypatch.setenv("GARAGE_CHUNK_SIZE", "7")
        monkeypatch.setenv("GARAGE_DATABASE_URL", "postgresql:///wrong")
        cfg = tmp_path / CONFIG_FILENAME
        cfg.write_text(json.dumps({"chunking": {"size": 123}}))
        settings = load_config(cfg)
        assert settings.chunk_size == 123
        assert settings.database_url == Settings().database_url


class TestSchemaCompleteness:
    def test_every_field_is_documented(self) -> None:
        """The schema is the only documentation, since JSON has no comments.

        An undocumented field is a setting nobody can discover the meaning of.
        """
        schema = json_schema()
        undocumented = [
            f"{section}.{key}"
            for section, body in schema["properties"].items()
            if body.get("type") == "object"
            for key, spec in body.get("properties", {}).items()
            if not spec.get("description")
        ]
        assert not undocumented, f"undocumented settings: {undocumented}"

    def test_every_source_field_is_documented(self) -> None:
        props = json_schema()["properties"]["sources"]["items"]["properties"]
        undocumented = [k for k, v in props.items() if not v.get("description")]
        assert not undocumented, f"undocumented source fields: {undocumented}"


class TestSchemaSibling:
    def test_dotted_config_gets_a_dotted_schema(self, tmp_path: Path) -> None:
        """~/.garage.json must not drop a visible garage.schema.json into $HOME."""
        from garage_rag.config import schema_path_for

        assert schema_path_for(tmp_path / ".garage.json") == tmp_path / ".garage.schema.json"

    def test_plain_config_gets_a_plain_schema(self, tmp_path: Path) -> None:
        from garage_rag.config import schema_path_for

        assert schema_path_for(tmp_path / "garage.json") == tmp_path / "garage.schema.json"

    def test_saved_schema_ref_matches_the_sibling(self, tmp_path: Path) -> None:
        from garage_rag.config import schema_path_for

        for name in ("garage.json", ".garage.json"):
            path = tmp_path / name
            save_config(Settings(), path)
            ref = json.loads(path.read_text())["$schema"]
            assert ref == f"./{schema_path_for(path).name}"
