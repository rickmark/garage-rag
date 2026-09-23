"""The privacy guarantee: document content never leaves this machine.

These tests exist because "we don't send your files to the cloud" is worth
nothing as a comment. Each layer is asserted on its own, so removing any one of
them fails the suite:

1. **No cloud AI SDK.** No source file imports one (AST scan, function-local
   imports included), and the lockfile contains none. The ``openai`` SDK is the
   one exception, and only in ``embed/lmstudio.py``, which uses it as a client
   for LM Studio's OpenAI-compatible API on loopback.
2. **Loopback only.** Every model server URL (``ollama_host``, ``lmstudio_host``,
   ``llama_host``) must be loopback: the configuration refuses anything else, and
   each client re-checks the URL it is given.
3. **A short list of network clients.** Only the modules in
   :data:`NETWORK_CLIENTS` may import an HTTP/socket client, and each of them is
   covered by layer 2.
4. **Local fact extraction.** Only the local part of LangExtract is vendored; no
   module imports the upstream package, whose provider registry routes model
   ids to Google and OpenAI.

The separate guard that withholds communication chunks from an off-box
embedding provider is in ``test_embed_egress.py``.
"""

from __future__ import annotations

import ast
import tomllib
from pathlib import Path

import pytest

from garage_rag.config import ConfigError, NonLoopbackHost, Settings, is_loopback_url, load_config

TESTS = Path(__file__).resolve().parent
SRC = TESTS.parent / "src" / "garage_rag"
LOCKFILE = TESTS.parent / "uv.lock"
# The one module that hands document text to (vendored) LangExtract.
FACTS_MODULE = SRC / "enrich" / "facts.py"

# Top-level packages (or dotted prefixes) of cloud AI SDKs and of libraries whose
# purpose is calling one.
CLOUD_AI_MODULES = (
    "anthropic",
    "openai",
    "google.genai",
    "google.generativeai",
    "google.ai",
    "google.cloud",
    "vertexai",
    "cohere",
    "mistralai",
    "groq",
    "together",
    "replicate",
    "fireworks",
    "voyageai",
    "huggingface_hub",
    "boto3",
    "botocore",
    "litellm",
    "langchain_openai",
    "langchain_anthropic",
    "langchain_google_genai",
    "langchain_google_vertexai",
    "langchain_aws",
    "langextract",
)
# The same, as distribution names in uv.lock.
CLOUD_AI_DISTRIBUTIONS = frozenset(
    {
        "anthropic",
        "google-genai",
        "google-generativeai",
        "google-ai-generativelanguage",
        "google-cloud-aiplatform",
        "google-cloud-storage",
        "google-api-core",
        "vertexai",
        "cohere",
        "mistralai",
        "groq",
        "together",
        "replicate",
        "fireworks-ai",
        "voyageai",
        "huggingface-hub",
        "boto3",
        "botocore",
        "litellm",
        "langchain-openai",
        "langchain-anthropic",
        "langextract",
    }
)
# openai: the SDK is the client for LM Studio's OpenAI-compatible API, on loopback.
ALLOWED_CLOUD_SDK_IMPORTS = {"openai": {"embed/lmstudio.py"}}

# Modules allowed to import a network client, and what each one talks to. Every
# entry either enforces loopback or never carries document content.
NETWORK_MODULES = ("httpx", "httpx2", "ollama", "openai", "urllib.request", "http.client", "socket", "requests",
                   "aiohttp", "websockets", "urllib3", "grpc", "smtplib", "ftplib", "xmlrpc.client")  # fmt: skip
NETWORK_CLIENTS = {
    "embed/ollama.py": "Ollama embeddings; require_loopback on the host",
    "embed/lmstudio.py": "LM Studio embeddings; require_loopback on base_url",
    "enrich/generation.py": "rag_ask / rag_generate; require_loopback on the host",
    "enrich/ollama_provider.py": "fact distillation on Ollama; require_loopback on model_url",
    "xpc/llama_xpc.py": "the app's LlamaXPCService; refuses a non-loopback base_url",
    "service/client.py": "the app's gRPC facade; require_loopback on the address",
    "service/server.py": "the gRPC server itself (inbound)",
    "proto/garage_pb2_grpc.py": "generated gRPC stubs",
    "cli.py": "mcp-test probes the MCP endpoint only when it is loopback",
}


def _imported_modules(path: Path) -> set[str]:
    """Every absolute module name ``path`` imports, anywhere in the file.

    ``ast.walk`` reaches function-local and conditional imports as well as the
    top-level ones; string arguments to ``importlib.import_module`` and
    ``__import__`` count too.
    """
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    modules: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            modules.update(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            modules.add(node.module)
            modules.update(f"{node.module}.{alias.name}" for alias in node.names)
        elif isinstance(node, ast.Call) and node.args and isinstance(node.args[0], ast.Constant):
            func = node.func
            name = func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", None)
            if name in ("import_module", "__import__") and isinstance(node.args[0].value, str):
                modules.add(node.args[0].value)
    return modules


def _matches(module: str, prefixes: tuple[str, ...]) -> str | None:
    return next((p for p in prefixes if module == p or module.startswith(p + ".")), None)


def _sources() -> list[Path]:
    return sorted(SRC.rglob("*.py"))


class TestNoCloudAISDK:
    """Layer 1: nothing in the package can talk to a cloud AI API."""

    def test_no_module_imports_a_cloud_ai_sdk(self) -> None:
        offenders = []
        for path in _sources():
            relative = path.relative_to(SRC).as_posix()
            for module in _imported_modules(path):
                sdk = _matches(module, CLOUD_AI_MODULES)
                if sdk and relative not in ALLOWED_CLOUD_SDK_IMPORTS.get(sdk, set()):
                    offenders.append(f"{relative}: {module}")
        assert not offenders, f"cloud AI SDK imported: {offenders}"

    def test_the_scan_sees_function_local_and_dynamic_imports(self, tmp_path: Path) -> None:
        sample = tmp_path / "sample.py"
        sample.write_text(
            "import importlib\n"
            "def f():\n"
            "    import anthropic\n"
            "    from google import genai\n"
            "    return importlib.import_module('cohere')\n",
            encoding="utf-8",
        )
        found = {_matches(m, CLOUD_AI_MODULES) for m in _imported_modules(sample)} - {None}
        assert found == {"anthropic", "google.genai", "cohere"}

    def test_openai_is_only_a_loopback_client(self) -> None:
        """The one allowed SDK is constructed with a loopback-checked base_url and no env proxies."""
        body = (SRC / "embed" / "lmstudio.py").read_text(encoding="utf-8")
        assert 'require_loopback(base_url or settings.lmstudio_host, "embedding.lmstudio_host")' in body
        assert "DefaultHttpxClient(trust_env=False, follow_redirects=False)" in body

    def test_lockfile_has_no_cloud_ai_sdk(self) -> None:
        lock = tomllib.loads(LOCKFILE.read_text(encoding="utf-8"))
        names = {package["name"] for package in lock["package"]}
        assert not names & CLOUD_AI_DISTRIBUTIONS, sorted(names & CLOUD_AI_DISTRIBUTIONS)

    def test_the_egress_module_and_cloud_ocr_are_gone(self) -> None:
        assert not (SRC / "enrich" / "egress.py").exists()
        image = (SRC / "extract" / "image.py").read_text(encoding="utf-8")
        assert "base64" not in image and "egress" not in image


class TestLoopbackOnly:
    """Layer 2: model servers are on this machine, by rule."""

    @pytest.mark.parametrize(
        ("url", "expected"),
        [
            ("http://localhost:11434", True),
            ("localhost:11434", True),
            ("http://127.0.0.1:8790", True),
            ("http://127.1.2.3:1234/v1", True),
            ("http://[::1]:11434", True),
            ("http://gpu-box:11434", False),
            ("10.0.0.5:11434", False),
            ("https://lmstudio.example.com/v1", False),
            ("http://127.example.com:11434", False),
            ("http://127.0.0.1.nip.io:11434", False),
            ("http://0.0.0.0:11434", False),
            ("http://127.0.0.1@evil.example:11434", False),
        ],
    )
    def test_is_loopback_url(self, url: str, expected: bool) -> None:
        assert is_loopback_url(url) is expected

    @pytest.mark.parametrize("field", ["ollama_host", "lmstudio_host", "llama_host"])
    @pytest.mark.parametrize("url", ["http://gpu-box:11434", "https://api.openai.com/v1", "http://10.0.0.5:1234/v1"])
    def test_settings_refuse_an_off_box_host(self, field: str, url: str) -> None:
        with pytest.raises(ValueError, match="must be a loopback URL"):
            Settings(**{field: url})

    def test_config_file_with_an_off_box_host_does_not_load(self, tmp_path: Path) -> None:
        path = tmp_path / "garage.json"
        path.write_text('{"embedding": {"ollama_host": "http://gpu-box:11434"}}', encoding="utf-8")
        with pytest.raises(ConfigError, match="embedding.ollama_host must be a loopback URL"):
            load_config(path)

    def test_ollama_embedder_refuses_an_off_box_host(self) -> None:
        from garage_rag.embed.ollama import OllamaEmbedder

        with pytest.raises(NonLoopbackHost):
            OllamaEmbedder("nomic-embed-text", host="http://gpu-box:11434")

    def test_lmstudio_embedder_refuses_an_off_box_host(self) -> None:
        from garage_rag.embed.lmstudio import LMStudioEmbedder

        with pytest.raises(NonLoopbackHost):
            LMStudioEmbedder("text-embedding", base_url="https://api.openai.com/v1")

    def test_fact_provider_refuses_an_off_box_host(self) -> None:
        from garage_rag.enrich.ollama_provider import OllamaLanguageModel

        with pytest.raises(NonLoopbackHost):
            OllamaLanguageModel("gemma2:2b", "http://gpu-box:11434")

    def test_fact_extraction_refuses_an_off_box_host_before_touching_facts(self) -> None:
        from unittest.mock import MagicMock

        from garage_rag.db.models import CorpusClass, Document
        from garage_rag.enrich.facts import extract_and_store_facts

        session = MagicMock()
        document = Document(id=1, content="text", corpus_class=CorpusClass.DOCUMENT)
        with pytest.raises(NonLoopbackHost):
            extract_and_store_facts(session, document, model_url="http://gpu-box:11434")
        session.query.assert_not_called()

    def test_llama_client_refuses_an_off_box_host(self) -> None:
        from garage_rag.xpc.llama_xpc import LlamaXPCClient, LlamaXPCError

        with pytest.raises(LlamaXPCError, match="loopback"):
            LlamaXPCClient("http://gpu-box:8790")

    def test_chat_model_refuses_an_off_box_host(self) -> None:
        """Settings validation is the first line; LocalChatModel checks again."""
        from garage_rag.enrich.generation import LocalChatModel

        settings = Settings.model_construct(fact_provider="ollama", ollama_host="http://gpu-box:11434")
        with pytest.raises(NonLoopbackHost):
            LocalChatModel(settings=settings)

    def test_grpc_client_refuses_an_off_box_address(self) -> None:
        from garage_rag.service.client import GarageClient

        with pytest.raises(NonLoopbackHost):
            GarageClient(host="10.0.0.5", port=50051, in_process=False)._get_stub()


@pytest.fixture
def redirecting_server():
    """A loopback server that 307-redirects every request to a second server, which counts hits."""
    import threading
    from http.server import BaseHTTPRequestHandler, HTTPServer

    hits: list[str] = []

    class Target(BaseHTTPRequestHandler):
        def log_message(self, *args) -> None:
            pass

        def _hit(self) -> None:
            hits.append(self.path)
            self.send_response(200)
            self.send_header("content-length", "2")
            self.end_headers()
            self.wfile.write(b"{}")

        do_GET = do_POST = _hit

    target = HTTPServer(("127.0.0.1", 0), Target)

    class Redirect(BaseHTTPRequestHandler):
        def log_message(self, *args) -> None:
            pass

        def _redirect(self) -> None:
            self.rfile.read(int(self.headers.get("content-length") or 0))
            self.send_response(307)
            self.send_header("location", f"http://127.0.0.1:{target.server_port}{self.path}")
            self.send_header("content-length", "0")
            self.end_headers()

        do_GET = do_POST = _redirect

    redirect = HTTPServer(("127.0.0.1", 0), Redirect)
    servers = [target, redirect]
    for server in servers:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        yield f"http://127.0.0.1:{redirect.server_port}", hits
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()


class TestNoRedirects:
    """A model server on loopback cannot bounce document text somewhere else."""

    def test_ollama_embedder(self, redirecting_server) -> None:
        from garage_rag.embed.ollama import OllamaEmbedder

        url, hits = redirecting_server
        with pytest.raises(Exception):  # noqa: B017 - the SDK's error type is not the point
            OllamaEmbedder("m", host=url).embed(["secret text"])
        assert hits == []

    def test_lmstudio_embedder(self, redirecting_server) -> None:
        from garage_rag.embed.lmstudio import LMStudioEmbedder

        url, hits = redirecting_server
        embedder = LMStudioEmbedder("m", base_url=f"{url}/v1")
        embedder._client = embedder._client.with_options(max_retries=0)
        with pytest.raises(Exception):  # noqa: B017
            embedder.embed(["secret text"])
        assert hits == []

    def test_fact_provider(self, redirecting_server) -> None:
        from garage_rag.enrich.langextract.exceptions import InferenceRuntimeError
        from garage_rag.enrich.ollama_provider import OllamaLanguageModel

        url, hits = redirecting_server
        with pytest.raises(InferenceRuntimeError):
            list(OllamaLanguageModel("m", url).infer(["secret text"]))
        assert hits == []

    def test_llama_client(self, redirecting_server) -> None:
        from garage_rag.xpc.llama_xpc import LlamaXPCClient, LlamaXPCError

        url, hits = redirecting_server
        with pytest.raises(LlamaXPCError):
            LlamaXPCClient(url, timeout=5).chat_completion([{"role": "user", "content": "secret text"}], model="m")
        with pytest.raises(LlamaXPCError):
            LlamaXPCClient(url, timeout=5).list_models()
        assert hits == []

    def test_chat_model(self, redirecting_server) -> None:
        from garage_rag.enrich.generation import LocalChatModel

        url, hits = redirecting_server
        model = LocalChatModel(settings=Settings(fact_provider="ollama", ollama_host=url))
        with pytest.raises(Exception):  # noqa: B017
            model.chat([{"role": "user", "content": "secret text"}])
        assert hits == []


class TestNetworkClients:
    """Layer 3: a new network client cannot appear without review."""

    def test_only_listed_modules_import_a_network_client(self) -> None:
        importers = {}
        for path in _sources():
            found = sorted({p for m in _imported_modules(path) if (p := _matches(m, NETWORK_MODULES))})
            if found:
                importers[path.relative_to(SRC).as_posix()] = found
        unexpected = {path: modules for path, modules in importers.items() if path not in NETWORK_CLIENTS}
        assert not unexpected, (
            f"new network client(s): {unexpected}. Enforce loopback (garage_rag.config.require_loopback) "
            "and add the module to NETWORK_CLIENTS with what it talks to."
        )

    @pytest.mark.parametrize(
        "module", ["embed/ollama.py", "embed/lmstudio.py", "enrich/generation.py", "enrich/ollama_provider.py"]
    )
    def test_model_clients_check_loopback(self, module: str) -> None:
        assert "require_loopback(" in (SRC / module).read_text(encoding="utf-8")


class TestFactExtractionStaysLocal:
    """Layer 4. Upstream LangExtract picks a *cloud* backend by regex on
    ``model_id`` (``gemini*`` -> Google, ``gpt-*`` -> OpenAI). Only the local
    part is vendored (``enrich/langextract``); no module imports the upstream
    package, the vendored copy has no provider routing, and every extraction
    runs on a model built from one of the two local providers.
    """

    LOCAL_MODELS = {"OllamaLanguageModel", "LlamaXPCLanguageModel"}

    def test_vendored_langextract_has_no_provider_routing(self) -> None:
        vendored = SRC / "enrich" / "langextract"
        names = {p.stem for p in vendored.rglob("*.py")}
        assert not names & {"factory", "providers", "router", "gemini", "openai", "io"}
        source = "\n".join(p.read_text(encoding="utf-8") for p in vendored.rglob("*.py"))
        assert "model_id" not in source.split("def extract(")[1].split(")")[0]

    def test_every_extract_call_is_given_a_local_model(self) -> None:
        tree = ast.parse(FACTS_MODULE.read_text(encoding="utf-8"), filename=str(FACTS_MODULE))
        calls = [
            node
            for node in ast.walk(tree)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "extract"
        ]
        assert calls, "expected an lx.extract(...) call in enrich/facts.py"
        for call in calls:
            keywords = {kw.arg for kw in call.keywords}
            assert "model" in keywords, f"line {call.lineno}: lx.extract must be given model="
            assert None not in keywords, f"line {call.lineno}: **kwargs could smuggle other options in"
        constructed = {
            node.func.id
            for node in ast.walk(tree)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id.endswith("LanguageModel")
        }
        assert constructed == self.LOCAL_MODELS


def test_guards_do_not_need_a_database_driver() -> None:
    """The guards must hold wherever the code runs, libpq or not.

    Run in a fresh interpreter that refuses to import psycopg: the modules the
    guards live in must still import, so the guards' tests (and the guards)
    never depend on a database driver being installed.
    """
    import subprocess
    import sys

    script = """
import sys

class BlockPsycopg:
    def find_spec(self, name, path=None, target=None):
        if name.split(".")[0] in ("psycopg", "psycopg_c", "psycopg_binary"):
            raise ImportError(f"{name} blocked for this test")
        return None

sys.meta_path.insert(0, BlockPsycopg())
import garage_rag.config
import garage_rag.ops.sources
import garage_rag.search.hybrid
import garage_rag.enrich.facts
import garage_rag.cli
print("ok")
"""
    result = subprocess.run([sys.executable, "-c", script], capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "ok"
