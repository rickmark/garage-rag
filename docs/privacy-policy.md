---
layout: default
title: Privacy Policy
description: Privacy Policy and local-first data guarantees for Garage and GarageApp.
---

# Privacy Policy

**Effective Date:** September 12, 2026  
**Application:** Garage & GarageApp  
**Developer:** Rick Mark

---

## 1. Overview & Local-First Philosophy

Garage is designed from the ground up as a **local-first** personal knowledge indexing and retrieval application. We respect your privacy and have designed the application so that it does not collect, track, sell, or transmit user data by default.

---

## 2. Data Collection

Garage does **not** collect personal information from users.

The application does not collect, store, transmit, or share:
- Names or identity data
- Email addresses or contact lists
- Account credentials or passwords
- Usage analytics or telemetry
- Device identifiers or hardware IDs
- Location data
- Documents, codebases, or file contents
- Personal images or scanned documents
- Search queries and retrieval results
- Application activity or runtime sessions

Garage contains **no advertising trackers, no analytics SDKs, and no background telemetry**.

---

## 3. Local Processing & Storage

All data indexed by Garage is processed and stored locally on your device in your private PostgreSQL database located in:  
`~/Library/Application Support/GarageApp/pgdata`

Your files, text, images, code, and communications never leave your device unless you explicitly enable optional third-party integrations.

---

## 4. Optional Third-Party Services

Garage may offer optional features that allow you to submit selected content to third-party providers for processing:

- **Cloud Optical Character Recognition (OCR)**: If enabled, image text extraction with low local confidence may optionally escalate to a third-party vision model (Anthropic's Claude API, the only cloud provider the application integrates).
- **Third-Party Model Providers**: If configured, local embedding requests may connect to user-specified external API endpoints.

### User Control
- Use of third-party features is strictly optional and disabled by default.
- Garage enforces structural egress blocks ensuring private communications (Messages, Mail) are never transmitted to any cloud API under any circumstances.
- When using third-party APIs, data is processed according to the respective provider's terms and privacy policies.

---

## 5. Security & Access Control

- **Keychain Security**: Database superuser passwords and optional API tokens (e.g., LM Studio API keys) are stored securely in the native **macOS Keychain**.
- **Loopback Isolation**: The embedded HTTP MCP server binds exclusively to `127.0.0.1` with DNS-rebinding guards and origin validation, preventing web pages and remote networks from accessing your corpus.
- **macOS Sandboxing & TCC**: Access to protected directories (Documents, Downloads, Desktop, Messages, Mail) requires explicit macOS user authorization under System Settings.

---

## 6. Children's Privacy

Garage does not knowingly collect information from children or any other users. Because the application does not collect personal data, it does not knowingly collect personal data from children under 13 or the equivalent minimum age in other jurisdictions.

---

## 7. Changes to This Policy

This Privacy Policy may be updated from time to time. Any material updates will be published to this website and included with subsequent application releases.

---

## 8. Contact

If you have questions about this Privacy Policy or our local-first security architecture, please reach out:

- **GitHub Issues**: [https://github.com/rickmark/garage-rag/issues](https://github.com/rickmark/garage-rag/issues)
- **Email**: [privacy@rickmark.com](mailto:privacy@rickmark.com)
