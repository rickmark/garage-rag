"""Tests for Python Llama XPC client, in-process engine, and HTTP protocol emulation."""

import math

import pytest

from garage_rag.service.llama_xpc import (
    DEFAULT_LLAMA_XPC_SERVICE_NAME,
    LlamaXPCClient,
)


@pytest.fixture
def client() -> LlamaXPCClient:
    return LlamaXPCClient(service_name=DEFAULT_LLAMA_XPC_SERVICE_NAME)


def test_health(client: LlamaXPCClient):
    health = client.health()
    assert health["status"] == "ok"
    assert health["slots_idle"] >= 1
    assert health["slots_processing"] == 0


def test_get_props(client: LlamaXPCClient):
    props = client.get_props()
    assert props["model_alias"] == "default"
    assert props["total_slots"] >= 1
    assert "completion" in props["modal_capabilities"]
    assert "chat" in props["modal_capabilities"]
    assert "embeddings" in props["modal_capabilities"]


def test_list_models(client: LlamaXPCClient):
    models = client.list_models()
    assert models["object"] == "list"
    assert len(models["data"]) == 1
    assert models["data"][0]["id"] == "default"


def test_completion(client: LlamaXPCClient):
    resp = client.completion("Why is the sky blue?", max_tokens=32, temperature=0.7)
    assert resp["stop"] is True
    assert "Processed response" in resp["content"]
    assert resp["tokens_predicted"] > 0
    assert resp["tokens_evaluated"] > 0


def test_chat_completion(client: LlamaXPCClient):
    messages = [
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": "Hello!"},
    ]
    resp = client.chat_completion(messages, max_tokens=64)
    assert resp["object"] == "chat.completion"
    assert len(resp["choices"]) == 1
    assert resp["choices"][0]["message"]["role"] == "assistant"
    assert "Processed response" in resp["choices"][0]["message"]["content"]
    assert resp["usage"]["total_tokens"] > 0


def test_embeddings(client: LlamaXPCClient):
    texts = ["Hello world", "Python client for llama-server over XPC"]
    resp = client.embeddings(texts, dimensions=128)
    assert resp["object"] == "list"
    assert len(resp["data"]) == 2
    assert len(resp["data"][0]["embedding"]) == 128
    assert len(resp["data"][1]["embedding"]) == 128

    # Verify L2 normalization
    v0 = resp["data"][0]["embedding"]
    norm0 = math.sqrt(sum(x * x for x in v0))
    assert math.isclose(norm0, 1.0, rel_tol=1e-4)

    # Convenience method
    vectors = client.embed_texts(texts, dimensions=128)
    assert len(vectors) == 2
    assert len(vectors[0]) == 128


def test_tokenize_and_detokenize(client: LlamaXPCClient):
    content = "Hello, world!"
    tokens = client.tokenize(content, with_pieces=False)
    assert isinstance(tokens, list)
    assert len(tokens) > 0

    detok = client.detokenize(tokens)
    assert detok == content

    # Tokenize with pieces
    tok_dict = client.tokenize(content, with_pieces=True)
    assert isinstance(tok_dict, dict)
    assert len(tok_dict["tokens"]) == len(tok_dict["pieces"])


def test_rerank(client: LlamaXPCClient):
    documents = [
        "Apple macOS development with Swift and XPC",
        "How to bake chocolate chip cookies",
        "Python client library for llama-server",
    ]
    resp = client.rerank(query="Python and llama-server", documents=documents, top_n=2)
    assert len(resp["results"]) == 2
    assert resp["results"][0]["relevance_score"] >= resp["results"][1]["relevance_score"]


def test_infill(client: LlamaXPCClient):
    resp = client.infill(input_prefix="def add(a, b):", input_suffix="return a + b", prompt="")
    assert resp["stop"] is True
    assert "Processed response" in resp["content"]


def test_slots(client: LlamaXPCClient):
    slots = client.get_slots()
    assert isinstance(slots, list)
    assert len(slots) >= 1

    action_res = client.manage_slot(0, action="erase")
    assert action_res["status"] == "ok"


def test_generic_server_request(client: LlamaXPCClient):
    # Test GET /health
    code, data = client.handle_server_request("/health", method="GET")
    assert code == 200
    assert data["status"] == "ok"

    # Test POST /v1/chat/completions
    code, data = client.handle_server_request(
        "/v1/chat/completions",
        method="POST",
        json_body={"messages": [{"role": "user", "content": "test"}]},
    )
    assert code == 200
    assert data["object"] == "chat.completion"

    # Test 404
    code, data = client.handle_server_request("/non_existent_route", method="GET")
    assert code == 404


def test_model_load_and_unload(client: LlamaXPCClient):
    load_res = client.load_model("/path/to/custom-model.gguf", alias="custom-model")
    assert load_res["success"] is True

    models = client.list_models()
    assert models["data"][0]["id"] == "custom-model"

    assert client.unload_model() is True
    health = client.health()
    assert health["status"] == "no_model_loaded"


def test_load_bge_m3_model_and_embeddings(client: LlamaXPCClient):
    model_path = "/Users/rickmark/Desktop/bge-m3-Q8_0.gguf"
    load_res = client.load_model(model_path, alias="bge-m3")
    assert load_res["success"] is True

    models = client.list_models()
    assert models["data"][0]["id"] == "bge-m3"

    texts = [
        "First document for BGE-M3 dense multilingual vector representation.",
        "Second query testing semantic embeddings on Apple Silicon via Llama XPC service.",
    ]

    # Test embeddings endpoint with 1024 dimensions
    resp = client.embeddings(texts, dimensions=1024)
    assert resp["object"] == "list"
    assert len(resp["data"]) == 2
    assert len(resp["data"][0]["embedding"]) == 1024
    assert len(resp["data"][1]["embedding"]) == 1024
    assert resp["usage"]["total_tokens"] > 0

    # Verify L2 normalization
    for item in resp["data"]:
        vec = item["embedding"]
        norm = math.sqrt(sum(x * x for x in vec))
        assert math.isclose(norm, 1.0, rel_tol=1e-4)

    # Test embed_texts convenience method
    vectors = client.embed_texts(texts, dimensions=1024)
    assert len(vectors) == 2
    assert len(vectors[0]) == 1024
    assert len(vectors[1]) == 1024
    assert vectors[0] != vectors[1]
