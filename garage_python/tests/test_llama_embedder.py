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
