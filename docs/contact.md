---
layout: default
title: Contact & Support
description: Contact the maintainers, submit bug reports, request features, and get support for Garage.
---

# Contact & Support

We welcome questions, bug reports, feature suggestions, and security vulnerability disclosures from the community.

---

## Getting Support & Submitting Inquiries

### 1. Bug Reports & Issues
If you encounter a bug, crash, or unexpected behavior in `GarageApp` or the `garage` CLI:

- **Open a GitHub Issue**: [github.com/rickmark/garage-rag/issues](https://github.com/rickmark/garage-rag/issues)
- Please include:
  - macOS version and hardware architecture (e.g., macOS 15.0 Sequoia, Apple Silicon M3)
  - Garage version / commit hash
  - Relevant sanitized log snippets (see below)
  - Exact steps to reproduce the issue

### 2. Feature Requests & Discussions
Have an idea for a new extractor, embedding provider, or MCP tool?
- Join the discussion and submit proposals under [GitHub Issues / Feature Requests](https://github.com/rickmark/garage-rag/issues).

### 3. Security Vulnerability Disclosures
If you discover a potential security issue or data leakage vulnerability:
- Please do **not** open a public issue.
- Email the maintainer directly at: [security@rickmark.com](mailto:security@rickmark.com)
- All valid security reports receive prompt attention and coordinated disclosure.

---

## How to Safely Share Diagnostic Logs

Before sharing logs on public issue trackers, protect your privacy by following these sanitization steps:

### Locating Your Logs
Logs are stored locally on your machine at:
- **PostgreSQL Service**: `~/Library/Group Containers/DWVXMLB45Y.group.me.rickmark.garage-rag/Library/Application Support/GarageApp/logs/postgres.log`
- **Ingestion & CLI Pipeline**: `~/Library/Group Containers/DWVXMLB45Y.group.me.rickmark.garage-rag/Library/Application Support/GarageApp/logs/ingest.log`
- **MCP HTTP Server**: `~/Library/Group Containers/DWVXMLB45Y.group.me.rickmark.garage-rag/Library/Application Support/GarageApp/logs/mcp.log`

### Sanitization Guidelines
1. **Redact Usernames and Paths**: Replace your home directory name (e.g., `/Users/yourname/`) with `/Users/username/`.
2. **Redact Sensitive File Names**: Check if log traces contain confidential project titles or private message sender handles.
3. **Never Share Database Dumps**: Do not attach raw `.dump` or `pgdata` files to public tickets, as they contain your indexed content and vector chunks.

---

<div class="callout callout-success">
  <div class="callout-title">Community & Open Source</div>
  <p>Garage is maintained as an open-source project by Rick Mark. Contributions and pull requests are warmly welcomed!</p>
</div>
