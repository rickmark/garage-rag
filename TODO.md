# TODO

Open work items from the pre-release review (PR #15). Each links to a GitHub issue with the
evidence, file references and proposed fix; this file is the index.

## Release blockers and decisions

- [ ] [#16](https://github.com/rickmark/garage-rag/issues/16) Replace or fence off the stub `llama_xpc`
      inference engine. The app's default embedding provider returns canned text and byte-histogram
      vectors on both the Swift and Python side, and backfill persists them as real embeddings.
- [ ] [#17](https://github.com/rickmark/garage-rag/issues/17) Rotate the Postgres password that was
      committed in `.idea/dataSources.xml` (removed from the tree, still in history).
- [ ] [#18](https://github.com/rickmark/garage-rag/issues/18) Decide on the README "Dedication" section
      before the repository is public.
- [ ] [#20](https://github.com/rickmark/garage-rag/issues/20) Decide the fate of `macapp/Package.swift`:
      `swift run` cannot build the app; either update the manifest or delete it.
- [ ] [#21](https://github.com/rickmark/garage-rag/issues/21) Fill in the `PRIVACY.md` effective date and
      contact placeholders.

## Verification of PR #15

- [ ] [#19](https://github.com/rickmark/garage-rag/issues/19) Compile and test the Swift changes on macOS;
      they were made without a toolchain. The issue lists the constructs a compiler must confirm.
- [ ] [#24](https://github.com/rickmark/garage-rag/issues/24) Regenerate `MODULE.bazel.lock` and
      `gazelle_python.yaml` with the Aspect CLI, and drop the unused Python 3.14 archive.

## Follow-up refactors

- [ ] [#22](https://github.com/rickmark/garage-rag/issues/22) Move `PostgresService` psql calls off the
      main actor and collapse `fetchCorpusStats` into one query.
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
