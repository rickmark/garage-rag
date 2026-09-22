# TODO

Open work items from the pre-release review (PR #15). Each links to a GitHub issue with the
evidence, file references and proposed fix; this file is the index.

## Follow-up refactors

- [ ] [#23](https://github.com/rickmark/garage-rag/issues/23) Collapse the CLI/gRPC duplication in
      `service/server.py` and delete the 24 RPCs nothing calls.
- [ ] [#25](https://github.com/rickmark/garage-rag/issues/25) Extract shared SwiftUI components (badge,
      output box, presets, status mappings) and split `StatusView.swift`.
- [ ] [#27](https://github.com/rickmark/garage-rag/issues/27) Smaller items: binary-quantized rerank,
      proto `kind` field, unpopulated chunk offsets, `expected_items`, git scan counts, non-loopback
      embedding hosts, duplicate OSLog poller, triplicated model catalog, stray configs, CLI output
      tail, Keychain fallback.
