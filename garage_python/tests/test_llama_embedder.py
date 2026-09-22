"""Tests for LlamaXPCEmbedder and factory integration.

The live tests need a running LlamaXPCService and local GGUF model files, which
only exist on the developer's machine. They are skipped -- not silently passed
-- anywhere those files are absent (CI, Linux, a fresh checkout).
"""

from pathlib import Path

import pytest

from garage_rag.embed.base import Embedder, EmbeddingError
from garage_rag.embed.factory import get_embedder
from garage_rag.embed.llama_xpc import LlamaXPCEmbedder
from garage_rag.xpc.llama_xpc import LlamaXPCClient

MXBAI_MODEL_PATH = Path("/Users/rickmark/Developer/garage/models/mxbai-embed-xsmall-v1-q8_0.gguf")
BGE_M3_MODEL_PATH = Path("/Users/rickmark/Desktop/bge-m3-Q8_0.gguf")

needs_live_xpc = pytest.mark.skipif(
    not MXBAI_MODEL_PATH.exists(),
    reason=f"requires a live LlamaXPCService and {MXBAI_MODEL_PATH}",
)


@needs_live_xpc
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


@needs_live_xpc
def test_embedder_factory_llama_xpc():
    embedder = get_embedder("llama_xpc", "default")
    assert isinstance(embedder, LlamaXPCEmbedder)
    assert embedder.model_ref == "default"

    dims = embedder.probe_dims()
    assert dims == 768


@needs_live_xpc
def test_llama_embedder_mxbai_embed_xsmall():
    client = LlamaXPCClient()
    load_res = client.load_model(str(MXBAI_MODEL_PATH), alias="mxbai-embed-xsmall")
    assert load_res["success"] is True

    embedder = LlamaXPCEmbedder(model_ref="mxbai-embed-xsmall", client=client)
    assert isinstance(embedder, Embedder)

    dims = embedder.probe_dims()
    assert dims == 384

    texts = [
        "First document for mxbai-embed-xsmall test embeddings.",
        "Second query testing semantic search indexing with 384-dimension vectors.",
    ]
    vectors = embedder.embed(texts)
    assert len(vectors) == 2
    assert len(vectors[0]) == 384
    assert len(vectors[1]) == 384


@pytest.mark.skipif(
    not BGE_M3_MODEL_PATH.exists(),
    reason=f"requires a live LlamaXPCService and {BGE_M3_MODEL_PATH}",
)
def test_llama_embedder_bge_m3():
    client = LlamaXPCClient()
    load_res = client.load_model(str(BGE_M3_MODEL_PATH), alias="bge-m3")
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


class _FailingClient:
    def embed_texts(self, texts, **kwargs):
        raise RuntimeError("XPC service crashed")


class _ShortClient:
    def embed_texts(self, texts, **kwargs):
        return [[0.1, 0.2]]  # one vector regardless of batch size


class _EmptyVectorClient:
    def embed_texts(self, texts, **kwargs):
        return [[] for _ in texts]


def test_llama_embedder_empty_batch_needs_no_client():
    embedder = LlamaXPCEmbedder(model_ref="default", client=_FailingClient())
    assert embedder.embed([]) == []
    assert isinstance(embedder, Embedder)


def test_llama_embedder_wraps_client_errors():
    failing_embedder = LlamaXPCEmbedder(model_ref="bad-model", client=_FailingClient())
    with pytest.raises(EmbeddingError, match="llama_xpc embed failed"):
        failing_embedder.embed(["hello"])


def test_llama_embedder_rejects_count_mismatch():
    embedder = LlamaXPCEmbedder(model_ref="short", client=_ShortClient())
    with pytest.raises(EmbeddingError, match="returned 1 vectors for 2 inputs"):
        embedder.embed(["a", "b"])


def test_llama_embedder_probe_rejects_empty_vector():
    embedder = LlamaXPCEmbedder(model_ref="empty", client=_EmptyVectorClient())
    with pytest.raises(EmbeddingError, match="probe returned an empty embedding"):
        embedder.probe_dims()


def test_embedding_error_is_one_class_everywhere():
    """cli.py and service/server.py catch the ollama spelling; it must be the same class."""
    from garage_rag.embed.lmstudio import EmbeddingError as lmstudio_error
    from garage_rag.embed.ollama import EmbeddingError as ollama_error

    assert ollama_error is EmbeddingError
    assert lmstudio_error is EmbeddingError
