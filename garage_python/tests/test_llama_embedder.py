"""Tests for LlamaXPCEmbedder and factory integration."""

import pytest

from garage_rag.embed.base import Embedder
from garage_rag.embed.factory import get_embedder
from garage_rag.embed.llama_xpc import LlamaXPCEmbedder
from garage_rag.service.llama_xpc import LlamaXPCClient


def test_llama_embedder_protocol():
    client = LlamaXPCClient()
    embedder = LlamaXPCEmbedder(model_ref="default", client=client)
    assert isinstance(embedder, Embedder)

    texts = ["First test document", "Second document for embeddings"]
    vectors = embedder.embed(texts)
    assert len(vectors) == 2
    assert len(vectors[0]) == 768
    assert len(vectors[1]) == 768

    dims = embedder.probe_dims()
    assert dims == 768


def test_embedder_factory_llama_xpc():
    embedder = get_embedder("llama_xpc", "default")
    assert isinstance(embedder, LlamaXPCEmbedder)
    assert embedder.model_ref == "default"

    dims = embedder.probe_dims()
    assert dims == 768


def test_llama_embedder_bge_m3():
    model_path = "/Users/rickmark/Desktop/bge-m3-Q8_0.gguf"
    client = LlamaXPCClient()
    load_res = client.load_model(model_path, alias="bge-m3")
    assert load_res["success"] is True

    embedder = LlamaXPCEmbedder(model_ref="bge-m3", client=client)
    assert isinstance(embedder, Embedder)

    dims = embedder.probe_dims()
    assert dims == 1024

    texts = [
        "First document for BGE-M3 dense multilingual embeddings.",
        "Second query testing semantic search indexing with 1024-dimension vectors.",
    ]
    vectors = embedder.embed(texts)
    assert len(vectors) == 2
    assert len(vectors[0]) == 1024
    assert len(vectors[1]) == 1024


def test_llama_embedder_empty_and_error():
    client = LlamaXPCClient()
    embedder = LlamaXPCEmbedder(model_ref="default", client=client)
    assert embedder.embed([]) == []

    # Test error handling when client raises
    class FailingClient:
        def embed_texts(self, texts, **kwargs):
            raise RuntimeError("XPC service crashed")

    failing_embedder = LlamaXPCEmbedder(model_ref="bad-model", client=FailingClient())
    from garage_rag.embed.ollama import EmbeddingError
    with pytest.raises(EmbeddingError, match="llama_xpc embed failed"):
        failing_embedder.embed(["hello"])
