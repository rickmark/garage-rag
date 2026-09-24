# AGENTS.md

Guidance for coding agents working in this repository lives in [CLAUDE.md](CLAUDE.md). Read it
first: it covers the Aspect/Bazel build, running tests (including against Postgres), CI, the
architecture, and the privacy guarantee (one egress choke point, a destination allowlist, and
communications that never leave the machine) that every change must preserve.
