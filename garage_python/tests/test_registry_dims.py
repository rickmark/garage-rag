"""The dimension -> storage mapping.

These are the rules that keep an unindexable model from being registered as
indexed. pgvector's HNSW ceilings are 2000 dims for `vector` and 4000 for
`halfvec`; getting this wrong surfaces as a CREATE INDEX failure thousands of
documents into an ingest, so it is tested directly and without a database.
"""

from __future__ import annotations

import math

import pytest

from garage_rag.db.registry import (
    HNSW_MAX_HALFVEC_DIMS,
    HNSW_MAX_VECTOR_DIMS,
    KNOWN_MODELS,
    column_type_sql,
    index_ddl,
    plan_storage,
    table_name_for,
    truncate_vector,
)


class TestPlanStorage:
    @pytest.mark.parametrize("dims", [64, 384, 768, 1024, 1536, 2000])
    def test_narrow_models_use_indexed_vector(self, dims: int) -> None:
        plan = plan_storage(dims)
        assert plan.storage_kind == "vector"
        assert plan.index_kind == "hnsw"
        assert plan.stored_dims == dims
        assert not plan.is_truncated

    @pytest.mark.parametrize("dims", [2001, 2560, 3072, 4000])
    def test_mid_width_models_use_halfvec(self, dims: int) -> None:
        """Above vector's 2000 ceiling, halfvec's 4000 ceiling still covers it."""
        plan = plan_storage(dims)
        assert plan.storage_kind == "halfvec"
        assert plan.index_kind == "hnsw"
        assert plan.stored_dims == dims
        assert not plan.is_truncated

    def test_mrl_model_above_ceiling_is_truncated_not_quantized(self) -> None:
        """Qwen3-8B at 4096 exceeds every HNSW ceiling; MRL makes truncation safe."""
        plan = plan_storage(4096, supports_mrl=True)
        assert plan.storage_kind == "halfvec"
        assert plan.index_kind == "hnsw"
        assert plan.stored_dims == HNSW_MAX_HALFVEC_DIMS
        assert plan.truncated_from == 4096

    def test_non_mrl_model_above_ceiling_falls_back_to_quantization(self) -> None:
        """Truncating a non-MRL model destroys quality, so quantize instead."""
        plan = plan_storage(4096, supports_mrl=False)
        assert plan.storage_kind == "vector"
        assert plan.index_kind == "hnsw_bq"
        assert plan.stored_dims == 4096
        assert not plan.is_truncated

    @pytest.mark.parametrize("dims", [0, -1])
    def test_rejects_nonpositive_dims(self, dims: int) -> None:
        with pytest.raises(ValueError):
            plan_storage(dims)

    def test_indexed_plans_never_exceed_pgvector_ceilings(self) -> None:
        """The invariant the whole module exists to maintain."""
        for dims in (1, 768, 2000, 2001, 4000, 4096, 8192, 16000):
            for mrl in (True, False):
                plan = plan_storage(dims, supports_mrl=mrl)
                if plan.index_kind != "hnsw":
                    continue
                ceiling = (
                    HNSW_MAX_VECTOR_DIMS if plan.storage_kind == "vector" else HNSW_MAX_HALFVEC_DIMS
                )
                assert plan.stored_dims <= ceiling, (
                    f"{dims=} mrl={mrl} produced an unindexable "
                    f"{plan.storage_kind}({plan.stored_dims})"
                )


class TestDDLGeneration:
    def test_column_type(self) -> None:
        assert column_type_sql(plan_storage(1024)) == "vector(1024)"
        assert column_type_sql(plan_storage(2560)) == "halfvec(2560)"

    def test_hnsw_index_uses_matching_ops_class(self) -> None:
        ddl_a = index_ddl("emb_a", plan_storage(1024))
        assert ddl_a is not None and "vector_cosine_ops" in ddl_a
        ddl_b = index_ddl("emb_b", plan_storage(2560))
        assert ddl_b is not None and "halfvec_cosine_ops" in ddl_b

    def test_quantized_index_uses_hamming_ops(self) -> None:
        ddl = index_ddl("emb_c", plan_storage(4096, supports_mrl=False))
        assert ddl is not None
        assert "binary_quantize" in ddl
        assert "bit_hamming_ops" in ddl


class TestTableNaming:
    @pytest.mark.parametrize(
        ("slug", "expected"),
        [
            ("bge-m3", "emb_bge_m3"),
            ("nomic-embed-text", "emb_nomic_embed_text"),
            ("qwen3-embedding-0.6b", "emb_qwen3_embedding_0_6b"),
            ("Mixed.Case-Name", "emb_mixed_case_name"),
        ],
    )
    def test_slug_normalization(self, slug: str, expected: str) -> None:
        assert table_name_for(slug) == expected

    def test_result_matches_schema_check_constraint(self) -> None:
        """sql/003_registry.sql enforces ^emb_[a-z0-9_]+$."""
        import re

        pattern = re.compile(r"^emb_[a-z0-9_]+$")
        for slug in [*KNOWN_MODELS, "weird!!name", "UPPER", "dots.and-dashes"]:
            assert pattern.match(table_name_for(slug)), slug

    def test_respects_postgres_identifier_limit(self) -> None:
        assert len(table_name_for("x" * 200)) <= 63

    @pytest.mark.parametrize("slug", ["", "---", "!!!"])
    def test_rejects_slugs_with_no_usable_characters(self, slug: str) -> None:
        with pytest.raises(ValueError):
            table_name_for(slug)


class TestTruncation:
    def test_untruncated_plan_passes_values_through(self) -> None:
        values = [0.1, 0.2, 0.3]
        assert truncate_vector(values, plan_storage(3)) == values

    def test_truncation_renormalizes(self) -> None:
        """A prefix of a unit vector is not unit length, and pgvector's cosine
        distance does not normalize for you."""
        plan = plan_storage(4096, supports_mrl=True)
        raw = [1.0] * 4096
        out = truncate_vector(raw, plan)
        assert len(out) == HNSW_MAX_HALFVEC_DIMS
        assert math.isclose(math.sqrt(sum(v * v for v in out)), 1.0, rel_tol=1e-9)

    def test_rejects_short_vectors(self) -> None:
        with pytest.raises(ValueError, match="expected at least"):
            truncate_vector([1.0, 2.0], plan_storage(4096, supports_mrl=True))

    def test_all_zero_vector_does_not_divide_by_zero(self) -> None:
        plan = plan_storage(4096, supports_mrl=True)
        out = truncate_vector([0.0] * 4096, plan)
        assert out == [0.0] * HNSW_MAX_HALFVEC_DIMS


class TestKnownModels:
    def test_every_known_model_is_registrable(self) -> None:
        for slug, spec in KNOWN_MODELS.items():
            assert spec.slug == slug
            plan = plan_storage(spec.dims, supports_mrl=spec.supports_mrl)
            assert plan.stored_dims > 0
            assert table_name_for(slug).startswith("emb_")

    def test_qwen3_family_declares_mrl(self) -> None:
        """Truncation is only sound for MRL-trained models, so the flag matters."""
        for slug, spec in KNOWN_MODELS.items():
            if slug.startswith("qwen3-embedding"):
                assert spec.supports_mrl, f"{slug} must declare MRL support"

    def test_pulled_models_have_expected_widths(self) -> None:
        assert KNOWN_MODELS["bge-m3"].dims == 1024
        assert KNOWN_MODELS["nomic-embed-text"].dims == 768
