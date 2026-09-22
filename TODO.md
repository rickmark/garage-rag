# TODO

Open work items from the pre-release review (PR #15). Each links to a GitHub issue with the
evidence, file references and proposed fix; this file is the index.

## Release blockers and decisions

- [ ] [#16](https://github.com/rickmark/garage-rag/issues/16) Replace or fence off the stub `llama_xpc`
      inference engine. The app's default embedding provider returns canned text and byte-histogram
      vectors on both the Swift and Python side, and backfill persists them as real embeddings.

## Follow-up refactors

- [ ] [#23](https://github.com/rickmark/garage-rag/issues/23) Collapse the CLI/gRPC duplication in
      `service/server.py` and delete the 24 RPCs nothing calls.
- [ ] [#25](https://github.com/rickmark/garage-rag/issues/25) Extract shared SwiftUI components (badge,
      output box, presets, status mappings) and split `StatusView.swift`.
- [ ] [#26](https://github.com/rickmark/garage-rag/issues/26) Remove the remaining `LlamaClient`
      in-process fallbacks so a dead helper no longer looks healthy.
- [ ] [#27](https://github.com/rickmark/garage-rag/issues/27) Smaller items: binary-quantized rerank,
      proto `kind` field, unpopulated chunk offsets, `expected_items`, git scan counts, non-loopback
      embedding hosts, duplicate OSLog poller, triplicated model catalog, stray configs, CLI output
      tail, Keychain fallback.
