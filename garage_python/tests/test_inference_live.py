"""``InferenceClient`` against real LM Studio and Ollama servers, when a Mac has them.

Everything here skips unless its environment variable names a model, so CI
and web sessions skip it all. On a Mac with the servers running:

    # Ollama: /api/embed vs /v1/embeddings parity (needs an embedding model pulled)
    GARAGE_TEST_OLLAMA_EMBED_MODEL=nomic-embed-text pytest tests/test_inference_live.py -s

    # LM Studio: the probe's findings, re-checked against this client
    GARAGE_TEST_LMSTUDIO_EMBED_MODEL=text-embedding-nomic-embed-text-v1.5 \\
    GARAGE_TEST_LMSTUDIO_CHAT_MODEL=google/gemma-3-4b pytest tests/test_inference_live.py -s

``GARAGE_TEST_OLLAMA_URL`` / ``GARAGE_TEST_LMSTUDIO_URL`` override the default
ports, and ``GARAGE_LMSTUDIO_API_TOKEN`` is sent when set. With LM Studio's
token auth switched on, ``GARAGE_TEST_LMSTUDIO_AUTH_ON=1`` also checks what an
unauthenticated call gets (unverified so far). Each test prints what it
measured, so ``-s`` gives the numbers for validation notes.

The parity test is the gate for switching Ollama embeddings to ``/v1``
(``Backend.ollama_embed_route = "openai"``): it passes only when both routes
return the same vectors for the same model.
"""

from __future__ import annotations

import math
import os

import pytest

from garage_rag.inference import (
    Backend,
    BackendKind,
    InferenceAuthError,
    InferenceClient,
    InferenceErrorBody,
    InferenceHTTPError,
)

TEXTS = [
    "Garage stores its index in PostgreSQL with pgvector.",
    "Messages and Mail are communications and never leave the machine.",
    "Reciprocal Rank Fusion combines keyword and vector rankings.",
    "The quick brown fox jumps over the lazy dog.",
    "東京は日本の首都です。",
]

OLLAMA_MODEL = os.environ.get("GARAGE_TEST_OLLAMA_EMBED_MODEL")
OLLAMA_URL = os.environ.get("GARAGE_TEST_OLLAMA_URL", "http://127.0.0.1:11434")
LMSTUDIO_EMBED = os.environ.get("GARAGE_TEST_LMSTUDIO_EMBED_MODEL")
LMSTUDIO_CHAT = os.environ.get("GARAGE_TEST_LMSTUDIO_CHAT_MODEL")
LMSTUDIO_URL = os.environ.get("GARAGE_TEST_LMSTUDIO_URL", "http://127.0.0.1:1234")
LMSTUDIO_TOKEN = os.environ.get("GARAGE_LMSTUDIO_API_TOKEN")

needs_ollama = pytest.mark.skipif(not OLLAMA_MODEL, reason="GARAGE_TEST_OLLAMA_EMBED_MODEL not set")
needs_lmstudio = pytest.mark.skipif(
    not (LMSTUDIO_EMBED or LMSTUDIO_CHAT), reason="GARAGE_TEST_LMSTUDIO_*_MODEL not set"
)


def _cosine(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b, strict=True))
    return dot / (math.sqrt(sum(x * x for x in a)) * math.sqrt(sum(y * y for y in b)))


def _max_abs(a: list[float], b: list[float]) -> float:
    return max(abs(x - y) for x, y in zip(a, b, strict=True))


def _norm(a: list[float]) -> float:
    return math.sqrt(sum(x * x for x in a))


def _lmstudio() -> InferenceClient:
    return InferenceClient(Backend(BackendKind.LMSTUDIO, LMSTUDIO_URL, token=LMSTUDIO_TOKEN))


# ---- Ollama ----------------------------------------------------------------


@needs_ollama
def test_ollama_native_and_openai_embeddings_agree() -> None:
    assert OLLAMA_MODEL
    native = InferenceClient(Backend(BackendKind.OLLAMA, OLLAMA_URL, ollama_embed_route="native"))
    openai = InferenceClient(Backend(BackendKind.OLLAMA, OLLAMA_URL, ollama_embed_route="openai"))

    a = native.embed(TEXTS, OLLAMA_MODEL)
    b = openai.embed(TEXTS, OLLAMA_MODEL)

    assert len(a) == len(b) == len(TEXTS)
    assert {len(v) for v in a} == {len(v) for v in b}, "the two routes return different widths"
    cosines = [_cosine(x, y) for x, y in zip(a, b, strict=True)]
    diffs = [_max_abs(x, y) for x, y in zip(a, b, strict=True)]
    print(
        f"\nollama {OLLAMA_MODEL}: dims={len(a[0])} "
        f"min cosine={min(cosines):.9f} max |diff|={max(diffs):.3g} "
        f"norms native={[round(_norm(v), 6) for v in a]} openai={[round(_norm(v), 6) for v in b]}"
    )
    assert min(cosines) >= 0.99999, "Ollama's /v1/embeddings does not reproduce /api/embed"
    assert max(diffs) <= 1e-4


@needs_ollama
def test_ollama_native_batched_equals_single() -> None:
    assert OLLAMA_MODEL
    client = InferenceClient(Backend(BackendKind.OLLAMA, OLLAMA_URL))
    batch = client.embed(TEXTS, OLLAMA_MODEL)
    single = client.embed([TEXTS[1]], OLLAMA_MODEL)[0]
    print(f"\nollama batched vs single: max |diff|={_max_abs(batch[1], single):.3g}")
    assert _cosine(batch[1], single) >= 0.99999


# ---- LM Studio ---------------------------------------------------------------


@needs_lmstudio
def test_lmstudio_answers_unknown_routes_with_an_error_body() -> None:
    with pytest.raises(InferenceErrorBody):
        _lmstudio()._call("GET", "/api/tags")


@needs_lmstudio
def test_lmstudio_catalog_lists_the_models() -> None:
    client = _lmstudio()
    catalog = {m.key: m for m in client.lmstudio_models()}
    served = set(client.list_models())
    for model in filter(None, (LMSTUDIO_EMBED, LMSTUDIO_CHAT)):
        assert model in catalog, f"{model} not downloaded in LM Studio"
        assert model in served
    print(f"\nlmstudio catalog: {[(m.key, m.type, m.is_loaded) for m in catalog.values()]}")


@needs_lmstudio
def test_lmstudio_embeddings_are_normalised_and_batch_invariant() -> None:
    if not LMSTUDIO_EMBED:
        pytest.skip("GARAGE_TEST_LMSTUDIO_EMBED_MODEL not set")
    client = _lmstudio()
    vectors = client.embed(TEXTS, LMSTUDIO_EMBED)
    single = client.embed([TEXTS[2]], LMSTUDIO_EMBED)[0]
    print(f"\nlmstudio {LMSTUDIO_EMBED}: dims={len(vectors[0])} norms={[round(_norm(v), 6) for v in vectors]}")
    assert all(abs(_norm(v) - 1.0) < 1e-3 for v in vectors)
    assert _max_abs(vectors[2], single) <= 1e-5


@needs_lmstudio
def test_lmstudio_chat_json_object_is_refused_and_json_schema_is_not() -> None:
    if not LMSTUDIO_CHAT:
        pytest.skip("GARAGE_TEST_LMSTUDIO_CHAT_MODEL not set")
    from garage_rag.inference import json_schema_format

    client = _lmstudio()
    messages = [{"role": "user", "content": "List two colours as JSON."}]
    with pytest.raises(InferenceHTTPError) as info:
        client.chat(messages, LMSTUDIO_CHAT, max_tokens=64, response_format={"type": "json_object"})
    assert info.value.status_code == 400
    schema = {
        "type": "object",
        "properties": {"colours": {"type": "array", "items": {"type": "string"}}},
        "required": ["colours"],
    }
    result = client.chat(messages, LMSTUDIO_CHAT, max_tokens=64, response_format=json_schema_format("c", schema))
    print(f"\nlmstudio json_schema reply: {result.text!r}")
    assert result.text


@needs_lmstudio
def test_lmstudio_load_and_unload() -> None:
    if not LMSTUDIO_CHAT:
        pytest.skip("GARAGE_TEST_LMSTUDIO_CHAT_MODEL not set")
    client = _lmstudio()
    loaded = client.load_model(LMSTUDIO_CHAT, context_length=8192)
    try:
        print(f"\nlmstudio load: {loaded}")
        assert loaded.status == "loaded"
        assert "context_length" in loaded.load_config
    finally:
        assert client.unload_model(loaded.instance_id) == loaded.instance_id
    with pytest.raises(InferenceHTTPError) as info:
        client.unload_model("garage-no-such-instance")
    assert (info.value.status_code, info.value.error_type) == (404, "model_not_found")


@pytest.mark.skipif(not os.environ.get("GARAGE_TEST_LMSTUDIO_AUTH_ON"), reason="LM Studio token auth not on")
def test_lmstudio_without_a_token_when_auth_is_on() -> None:
    client = InferenceClient(Backend(BackendKind.LMSTUDIO, LMSTUDIO_URL))
    for call in (client.list_models, client.lmstudio_models):
        with pytest.raises(InferenceAuthError) as info:
            call()
        print(f"\nlmstudio unauthenticated: HTTP {info.value.status_code}: {info.value}")
