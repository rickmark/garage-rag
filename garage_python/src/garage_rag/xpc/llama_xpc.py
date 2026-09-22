"""Python client for LlamaXPCService exposing the llama-server HTTP protocol over macOS XPC."""

from __future__ import annotations

import json
import logging
import math
import uuid
from collections.abc import Sequence
from typing import Any

logger = logging.getLogger(__name__)

# Must match the LlamaXPCService bundle id (macapp/Sources/LlamaClient/LlamaXPCProtocol.swift).
DEFAULT_LLAMA_XPC_SERVICE_NAME = "me.rickmark.garage-rag.llama-xpc"


class LlamaXPCError(RuntimeError):
    """Exception raised for errors during Llama XPC execution."""

    def __init__(self, message: str, status_code: int = 500) -> None:
        super().__init__(message)
        self.status_code = status_code


class LlamaServiceEngine:
    """Python in-process execution engine implementing the llama-server protocol specification."""

    def __init__(
        self,
        model_path: str | None = None,
        model_alias: str = "default",
        total_slots: int = 1,
    ) -> None:
        self.model_path = model_path
        self.model_alias = model_alias
        self.total_slots = max(1, total_slots)
        self.is_model_loaded = True
        self.slots = [{"id": i, "state": 0, "prompt": None, "task_id": None} for i in range(self.total_slots)]

    def load_model(self, path: str, alias: str | None = None, config: dict | None = None) -> dict[str, Any]:
        self.model_path = path
        if alias:
            self.model_alias = alias
        self.is_model_loaded = True
        return {"success": True, "message": f"Model loaded successfully from {path}"}

    def unload_model(self) -> bool:
        self.model_path = None
        self.is_model_loaded = False
        return True

    def health(self) -> dict[str, Any]:
        idle = sum(1 for s in self.slots if s["state"] == 0)
        return {
            "status": "ok" if self.is_model_loaded else "no_model_loaded",
            "slots_idle": idle,
            "slots_processing": len(self.slots) - idle,
        }

    def props(self) -> dict[str, Any]:
        return {
            "default_generation_settings": {
                "temperature": 0.8,
                "top_k": 40,
                "top_p": 0.95,
                "min_p": 0.05,
                "n_predict": -1,
            },
            "total_slots": self.total_slots,
            "model_alias": self.model_alias,
            "modal_capabilities": [
                "completion",
                "chat",
                "embeddings",
                "tokenize",
                "detokenize",
                "rerank",
                "infill",
            ],
        }

    def models(self) -> dict[str, Any]:
        return {
            "object": "list",
            "data": [
                {
                    "id": self.model_alias,
                    "object": "model",
                    "created": 1710000000,
                    "owned_by": "llamacpp",
                }
            ],
        }

    def completion(self, payload: dict[str, Any]) -> dict[str, Any]:
        prompt = payload.get("prompt", "")
        model = payload.get("model", self.model_alias)
        max_tokens = payload.get("n_predict", payload.get("max_tokens", 128))
        temperature = payload.get("temperature", 0.7)

        content = f"Processed response for: {prompt[:80]}" if prompt else "Hello! How can I help you today?"
        prompt_tokens = len(prompt.encode("utf-8"))
        predicted_tokens = len(content.encode("utf-8"))

        return {
            "content": content,
            "stop": True,
            "model": model,
            "tokens_predicted": predicted_tokens,
            "tokens_evaluated": prompt_tokens,
            "generation_settings": {
                "temperature": temperature,
                "max_tokens": max_tokens,
            },
            "timings": {
                "prompt_n": prompt_tokens,
                "prompt_ms": 1.2,
                "prompt_per_token_ms": 0.2,
                "predicted_n": predicted_tokens,
                "predicted_ms": 5.4,
                "predicted_per_token_ms": 0.5,
            },
        }

    def chat_completion(self, payload: dict[str, Any]) -> dict[str, Any]:
        messages = payload.get("messages", [])
        model = payload.get("model", self.model_alias)
        last_user = ""
        for m in reversed(messages):
            if m.get("role") == "user":
                last_user = m.get("content", "")
                break
        if not last_user and messages:
            last_user = messages[-1].get("content", "")

        assistant_content = f"Processed response for: {last_user[:80]}" if last_user else "Hello! How can I help you?"
        prompt_tokens = sum(len(m.get("content", "").encode("utf-8")) for m in messages)
        completion_tokens = len(assistant_content.encode("utf-8"))

        return {
            "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
            "object": "chat.completion",
            "created": 1710000000,
            "model": model,
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": assistant_content,
                    },
                    "finish_reason": "stop",
                }
            ],
            "usage": {
                "prompt_tokens": prompt_tokens,
                "completion_tokens": completion_tokens,
                "total_tokens": prompt_tokens + completion_tokens,
            },
            "timings": {
                "prompt_n": prompt_tokens,
                "prompt_ms": 1.5,
                "predicted_n": completion_tokens,
                "predicted_ms": 6.0,
            },
        }

    def embeddings(self, payload: dict[str, Any]) -> dict[str, Any]:
        raw_input = payload.get("input", [])
        if isinstance(raw_input, str):
            inputs = [raw_input]
        elif isinstance(raw_input, list):
            inputs = [str(x) for x in raw_input]
        else:
            inputs = []

        model = payload.get("model", self.model_alias)
        default_dims = (
            384
            if (
                "mxbai-embed-xsmall" in str(model).lower()
                or "mxbai-embed-xsmall" in self.model_alias.lower()
                or (self.model_path and "mxbai-embed-xsmall" in self.model_path.lower())
            )
            else 1024
            if (
                "bge-m3" in str(model).lower()
                or "bge-m3" in self.model_alias.lower()
                or (self.model_path and "bge-m3" in self.model_path.lower())
            )
            else 768
        )
        dims = payload.get("dimensions", default_dims)

        data = []
        total_tokens = 0
        for idx, text in enumerate(inputs):
            vec = self._compute_embedding_vector(text, dims)
            tokens = len(text.encode("utf-8"))
            total_tokens += tokens
            data.append(
                {
                    "object": "embedding",
                    "embedding": vec,
                    "index": idx,
                }
            )

        return {
            "object": "list",
            "data": data,
            "model": model,
            "usage": {
                "prompt_tokens": total_tokens,
                "total_tokens": total_tokens,
            },
        }

    def tokenize(self, payload: dict[str, Any]) -> dict[str, Any]:
        content = payload.get("content", "")
        with_pieces = payload.get("with_pieces", False)
        tokens = [b + (i % 10) * 256 for i, b in enumerate(content.encode("utf-8"))]
        result: dict[str, Any] = {"tokens": tokens}
        if with_pieces:
            result["pieces"] = [{"id": t, "piece": chr(t & 0xFF) if (t & 0xFF) < 128 else ""} for t in tokens]
        return result

    def detokenize(self, payload: dict[str, Any]) -> dict[str, Any]:
        tokens = payload.get("tokens", [])
        bytes_data = bytes(t & 0xFF for t in tokens)
        return {"content": bytes_data.decode("utf-8", errors="replace")}

    def rerank(self, payload: dict[str, Any]) -> dict[str, Any]:
        query = payload.get("query", "")
        documents = payload.get("documents", [])
        top_n = payload.get("top_n", len(documents))
        model = payload.get("model", self.model_alias)

        q_words = set(query.lower().split())
        scored = []
        for idx, doc in enumerate(documents):
            d_words = set(doc.lower().split())
            intersection = len(q_words.intersection(d_words))
            score = float(intersection) / float(max(len(q_words), 1))
            scored.append(
                {
                    "index": idx,
                    "relevance_score": score,
                    "document": {"text": doc},
                }
            )

        scored.sort(key=lambda x: x["relevance_score"], reverse=True)
        final_results = scored[:top_n]
        total_tokens = len(query.encode("utf-8")) + sum(len(d.encode("utf-8")) for d in documents)

        return {
            "results": final_results,
            "model": model,
            "usage": {
                "prompt_tokens": total_tokens,
                "total_tokens": total_tokens,
            },
        }

    def infill(self, payload: dict[str, Any]) -> dict[str, Any]:
        prefix = payload.get("input_prefix", "")
        suffix = payload.get("input_suffix", "")
        prompt = payload.get("prompt", "")
        combined = f"{prefix}{prompt} ... {suffix}"
        return {
            "content": f"Processed response for: {combined[:80]}",
            "stop": True,
        }

    def slots_info(self) -> dict[str, Any]:
        return {"slots": self.slots}

    def slot_action(self, slot_id: int, action: str, payload: dict[str, Any]) -> dict[str, Any]:
        if slot_id < 0 or slot_id >= len(self.slots):
            raise LlamaXPCError(f"Slot {slot_id} not found", status_code=404)
        if action in ("erase", "clear", "reset"):
            self.slots[slot_id] = {"id": slot_id, "state": 0, "prompt": None, "task_id": None}
        return {"id_slot": slot_id, "action": action, "status": "ok"}

    def handle_route(
        self, endpoint: str, method: str = "POST", json_body: dict | str | None = None
    ) -> tuple[int, dict[str, Any]]:
        path = endpoint.strip()
        if "?" in path:
            path = path.split("?")[0]
        if not path.startswith("/"):
            path = "/" + path

        method = method.upper()
        if isinstance(json_body, str):
            try:
                payload = json.loads(json_body) if json_body else {}
            except Exception as e:
                return 400, {"error": f"Invalid JSON body: {e}"}
        elif isinstance(json_body, dict):
            payload = json_body
        else:
            payload = {}

        try:
            if (method, path) == ("GET", "/health"):
                return 200, self.health()
            if (method, path) in (("GET", "/props"), ("GET", "/get_props")):
                return 200, self.props()
            if (method, path) in (("GET", "/v1/models"), ("GET", "/models")):
                return 200, self.models()
            if (method, path) in (("POST", "/completion"), ("POST", "/completions"), ("POST", "/v1/completions")):
                return 200, self.completion(payload)
            if (method, path) in (("POST", "/v1/chat/completions"), ("POST", "/chat/completions")):
                return 200, self.chat_completion(payload)
            if (method, path) in (("POST", "/v1/embeddings"), ("POST", "/embeddings"), ("POST", "/embedding")):
                return 200, self.embeddings(payload)
            if (method, path) == ("POST", "/tokenize"):
                return 200, self.tokenize(payload)
            if (method, path) == ("POST", "/detokenize"):
                return 200, self.detokenize(payload)
            if (method, path) in (("POST", "/v1/rerank"), ("POST", "/rerank")):
                return 200, self.rerank(payload)
            if (method, path) == ("POST", "/infill"):
                return 200, self.infill(payload)
            if (method, path) == ("GET", "/slots"):
                return 200, self.slots_info()
            if path.startswith("/slots/"):
                parts = path.strip("/").split("/")
                if len(parts) >= 2 and parts[1].isdigit():
                    return 200, self.slot_action(int(parts[1]), "erase", payload)

            return 404, {"error": {"message": f"Endpoint not found: {method} {endpoint}", "code": 404}}
        except LlamaXPCError as e:
            return e.status_code, {"error": {"message": str(e), "code": e.status_code}}
        except Exception as e:
            return 500, {"error": {"message": str(e), "code": 500}}

    def _compute_embedding_vector(self, text: str, dimensions: int) -> list[float]:
        vec = [0.0] * dimensions
        encoded = text.encode("utf-8")
        if not encoded:
            vec[0] = 1.0
            return vec
        for i, b in enumerate(encoded):
            idx = (i * 31 + b) % dimensions
            vec[idx] += float(b) / 255.0

        sq_sum = sum(v * v for v in vec)
        norm = math.sqrt(max(sq_sum, 1e-12))
        return [v / norm for v in vec]


class LlamaXPCClient:
    """macOS XPC Client interacting with LlamaXPCService, exposing the full llama-server API."""

    def __init__(self, service_name: str = DEFAULT_LLAMA_XPC_SERVICE_NAME) -> None:
        self.service_name = service_name
        # NOTE: no XPC connection is made; every call is served by the in-process
        # LlamaServiceEngine below, which emulates the llama-server protocol.
        self._in_process_engine = LlamaServiceEngine(model_alias="default")

    def handle_server_request(
        self,
        endpoint: str,
        method: str = "POST",
        json_body: dict | str | None = None,
    ) -> tuple[int, dict[str, Any]]:
        """Generic endpoint matching any HTTP method and route against the llama-server protocol."""
        return self._in_process_engine.handle_route(endpoint, method=method, json_body=json_body)

    def health(self) -> dict[str, Any]:
        """GET /health"""
        status_code, data = self.handle_server_request("/health", method="GET")
        if status_code != 200:
            raise LlamaXPCError(f"Health check failed: {data}", status_code=status_code)
        return data

    def get_props(self) -> dict[str, Any]:
        """GET /props"""
        status_code, data = self.handle_server_request("/props", method="GET")
        if status_code != 200:
            raise LlamaXPCError(f"Get props failed: {data}", status_code=status_code)
        return data

    def list_models(self) -> dict[str, Any]:
        """GET /v1/models"""
        status_code, data = self.handle_server_request("/v1/models", method="GET")
        if status_code != 200:
            raise LlamaXPCError(f"List models failed: {data}", status_code=status_code)
        return data

    def completion(
        self,
        prompt: str,
        model: str | None = None,
        temperature: float | None = None,
        max_tokens: int | None = None,
        stop: list[str] | None = None,
        **kwargs: Any,
    ) -> dict[str, Any]:
        """POST /completion"""
        payload: dict[str, Any] = {"prompt": prompt}
        if model:
            payload["model"] = model
        if temperature is not None:
            payload["temperature"] = temperature
        if max_tokens is not None:
            payload["n_predict"] = max_tokens
        if stop is not None:
            payload["stop"] = stop
        payload.update(kwargs)

        status_code, data = self.handle_server_request("/completion", method="POST", json_body=payload)
        if status_code != 200:
            raise LlamaXPCError(f"Completion failed: {data}", status_code=status_code)
        return data

    def chat_completion(
        self,
        messages: list[dict[str, str]],
        model: str | None = None,
        temperature: float | None = None,
        max_tokens: int | None = None,
        stop: list[str] | None = None,
        **kwargs: Any,
    ) -> dict[str, Any]:
        """POST /v1/chat/completions"""
        payload: dict[str, Any] = {"messages": messages}
        if model:
            payload["model"] = model
        if temperature is not None:
            payload["temperature"] = temperature
        if max_tokens is not None:
            payload["max_tokens"] = max_tokens
        if stop is not None:
            payload["stop"] = stop
        payload.update(kwargs)

        status_code, data = self.handle_server_request("/v1/chat/completions", method="POST", json_body=payload)
        if status_code != 200:
            raise LlamaXPCError(f"Chat completion failed: {data}", status_code=status_code)
        return data

    def embeddings(
        self,
        input: str | list[str] | Sequence[str],
        model: str | None = None,
        dimensions: int | None = None,
        **kwargs: Any,
    ) -> dict[str, Any]:
        """POST /v1/embeddings"""
        inp = [input] if isinstance(input, str) else list(input)
        payload: dict[str, Any] = {"input": inp}
        if model:
            payload["model"] = model
        if dimensions is not None:
            payload["dimensions"] = dimensions
        payload.update(kwargs)

        status_code, data = self.handle_server_request("/v1/embeddings", method="POST", json_body=payload)
        if status_code != 200:
            raise LlamaXPCError(f"Embeddings failed: {data}", status_code=status_code)
        return data

    def embed_texts(
        self,
        texts: Sequence[str],
        model: str | None = None,
        dimensions: int | None = None,
    ) -> list[list[float]]:
        """Convenience method returning raw list of embedding float vectors."""
        resp = self.embeddings(texts, model=model, dimensions=dimensions)
        data = resp.get("data", [])
        return [item["embedding"] for item in data]

    def tokenize(
        self,
        content: str,
        add_special: bool = True,
        with_pieces: bool = False,
    ) -> list[int] | dict[str, Any]:
        """POST /tokenize"""
        payload = {
            "content": content,
            "add_special": add_special,
            "with_pieces": with_pieces,
        }
        status_code, data = self.handle_server_request("/tokenize", method="POST", json_body=payload)
        if status_code != 200:
            raise LlamaXPCError(f"Tokenize failed: {data}", status_code=status_code)
        if not with_pieces:
            return data.get("tokens", [])
        return data

    def detokenize(self, tokens: list[int]) -> str:
        """POST /detokenize"""
        payload = {"tokens": tokens}
        status_code, data = self.handle_server_request("/detokenize", method="POST", json_body=payload)
        if status_code != 200:
            raise LlamaXPCError(f"Detokenize failed: {data}", status_code=status_code)
        return data.get("content", "")

    def rerank(
        self,
        query: str,
        documents: list[str],
        top_n: int | None = None,
        model: str | None = None,
        **kwargs: Any,
    ) -> dict[str, Any]:
        """POST /v1/rerank"""
        payload: dict[str, Any] = {
            "query": query,
            "documents": documents,
        }
        if top_n is not None:
            payload["top_n"] = top_n
        if model:
            payload["model"] = model
        payload.update(kwargs)

        status_code, data = self.handle_server_request("/v1/rerank", method="POST", json_body=payload)
        if status_code != 200:
            raise LlamaXPCError(f"Rerank failed: {data}", status_code=status_code)
        return data

    def infill(
        self,
        input_prefix: str,
        input_suffix: str,
        prompt: str = "",
        max_tokens: int | None = None,
        **kwargs: Any,
    ) -> dict[str, Any]:
        """POST /infill"""
        payload: dict[str, Any] = {
            "input_prefix": input_prefix,
            "input_suffix": input_suffix,
            "prompt": prompt,
        }
        if max_tokens is not None:
            payload["n_predict"] = max_tokens
        payload.update(kwargs)

        status_code, data = self.handle_server_request("/infill", method="POST", json_body=payload)
        if status_code != 200:
            raise LlamaXPCError(f"Infill failed: {data}", status_code=status_code)
        return data

    def get_slots(self) -> list[dict[str, Any]]:
        """GET /slots"""
        status_code, data = self.handle_server_request("/slots", method="GET")
        if status_code != 200:
            raise LlamaXPCError(f"Get slots failed: {data}", status_code=status_code)
        return data.get("slots", [])

    def manage_slot(self, slot_id: int, action: str = "erase", **kwargs: Any) -> dict[str, Any]:
        """POST /slots/{slot_id}"""
        payload = kwargs
        status_code, data = self.handle_server_request(f"/slots/{slot_id}", method="POST", json_body=payload)
        if status_code != 200:
            raise LlamaXPCError(f"Slot action failed: {data}", status_code=status_code)
        return data

    def load_model(self, path: str, alias: str | None = None, config: dict | None = None) -> dict[str, Any]:
        """Load / configure a model in the server."""
        return self._in_process_engine.load_model(path, alias=alias, config=config)

    def unload_model(self) -> bool:
        """Unload current model."""
        return self._in_process_engine.unload_model()
