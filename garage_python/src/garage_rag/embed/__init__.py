"""Embedding providers package."""

from garage_rag.embed.base import Embedder
from garage_rag.embed.factory import PROVIDERS, get_embedder
from garage_rag.embed.llama_xpc import LlamaXPCEmbedder
from garage_rag.embed.lmstudio import LMStudioEmbedder
from garage_rag.embed.ollama import OllamaEmbedder

__all__ = [
    "PROVIDERS",
    "Embedder",
    "LMStudioEmbedder",
    "LlamaXPCEmbedder",
    "OllamaEmbedder",
    "get_embedder",
]
