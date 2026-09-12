---
layout: default
title: Frequently Asked Questions (FAQ)
description: Frequently asked questions about Garage local RAG, privacy guarantees, performance, and integrations.
---

# Frequently Asked Questions (FAQ)

<div class="search-container" style="margin-bottom: 2rem;">
  <span class="search-icon">🔍</span>
  <input type="text" id="support-search" class="search-input" placeholder="Search questions (e.g. privacy, models, Claude, formats)...">
</div>

## General & Overview

<details open>
  <summary>What is Garage?</summary>
  <div class="faq-content">
    <p><strong>Garage</strong> is a local-first personal Retrieval-Augmented Generation (RAG) and knowledge indexing engine for macOS. It indexes your documents, notes, codebases, and communications locally using PostgreSQL and <code>pgvector</code>, providing hybrid semantic/keyword search via the Model Context Protocol (MCP 2.0) to local and desktop AI assistants like Claude Desktop and Claude Code.</p>
  </div>
</details>

<details>
  <summary>Is Garage completely open-source and free to use?</summary>
  <div class="faq-content">
    <p>Yes. Garage is licensed under the permissive MIT License. You have complete freedom to inspect the source code, run it locally, and adapt it to your workflow.</p>
  </div>
</details>

<details>
  <summary>How is Garage different from cloud RAG solutions?</summary>
  <div class="faq-content">
    <p>Unlike cloud solutions, Garage stores 100% of your documents, extracted chunks, and vector embeddings in a private local PostgreSQL instance on your machine. Your private communications and personal notes are never transmitted to third-party servers.</p>
  </div>
</details>

---

## Privacy & Security

<details>
  <summary>Does my data ever leave my Mac?</summary>
  <div class="faq-content">
    <p>By default, <strong>never</strong>. Garage is engineered with four structural layers of egress prevention:</p>
    <ul>
      <li><strong>Corpus Isolation:</strong> Content classified as <code>communication</code> (e.g., Messages, Mail) is blocked at the type system level from reaching any network client.</li>
      <li><strong>Single Egress Chokepoint:</strong> Validated by automated AST unit tests to guarantee no unauthorized network requests exist.</li>
      <li><strong>Opt-In Cloud OCR:</strong> Cloud-based OCR escalation (if enabled) only sends image pixels when local Tesseract confidence is low, and only for sources explicitly opted in.</li>
      <li><strong>Local Vector Processing:</strong> Embeddings are computed on your hardware using Ollama or LM Studio.</li>
    </ul>
  </div>
</details>

<details>
  <summary>Can websites or malicious browser tabs access my MCP server?</summary>
  <div class="faq-content">
    <p>No. The local HTTP MCP server on <code>127.0.0.1:8787</code> includes always-on DNS rebinding protection and Host validation. Any request originating from an unauthorized Host or browser cross-origin without explicit permission is rejected with <code>HTTP 421 Misdirected Request</code>.</p>
  </div>
</details>

<details>
  <summary>How are database passwords stored?</summary>
  <div class="faq-content">
    <p><code>GarageApp</code> automatically generates a cryptographically random SCRAM superuser password on initial launch and stores it in the secure <strong>macOS Keychain</strong> under the service name <code>garage_postgres_super</code>.</p>
  </div>
</details>

---

## Supported Formats & Ingestion

<details>
  <summary>What file formats does Garage support?</summary>
  <div class="faq-content">
    <p>Garage includes streaming, memory-efficient extractors for:</p>
    <ul>
      <li><strong>Markdown & Plain Text:</strong> <code>.md</code>, <code>.txt</code>, <code>.rst</code> (with YAML frontmatter stripping).</li>
      <li><strong>PDF Documents:</strong> Fast extraction via <code>pypdf</code>, with automatic page-level escalation to <code>pdfplumber</code> for embedded data tables.</li>
      <li><strong>Office Documents:</strong> Word (<code>.docx</code>), PowerPoint (<code>.pptx</code>), and Excel (<code>.xlsx</code>).</li>
      <li><strong>Source Code & Config:</strong> <code>.py</code>, <code>.swift</code>, <code>.ts</code>, <code>.rs</code>, <code>.go</code>, <code>.json</code>, <code>.yaml</code>, <code>.toml</code>, etc.</li>
      <li><strong>Images & Scans:</strong> Local OCR via Tesseract.</li>
      <li><strong>Communications:</strong> Apple Messages (<code>chat.db</code>) and Mailbox files.</li>
    </ul>
  </div>
</details>

<details>
  <summary>How does Authorship Attribution work?</summary>
  <div class="faq-content">
    <p>Garage automatically tags content with provenance (<code>authored</code>, <code>reference</code>, or <code>received</code>):</p>
    <ul>
      <li><strong>Git Repositories:</strong> Commits are inspected so that files you modified are attributed to you (<code>authored</code>), while upstream or vendored libraries are categorized as <code>reference</code>.</li>
      <li><strong>Document Metadata:</strong> PDF / Office author tags are extracted and cleaned against tool signatures.</li>
      <li><strong>Path Heuristics:</strong> Paths such as <code>Papers/</code>, <code>Manuals/</code>, or <code>node_modules/</code> are automatically mapped to reference material.</li>
    </ul>
  </div>
</details>

---

## Models & Search

<details>
  <summary>Can I use multiple embedding models at once?</summary>
  <div class="faq-content">
    <p>Yes. Garage decouples text chunks from embedding tables (<code>emb_&lt;model_slug&gt;</code>). You can register multiple models (e.g., <code>bge-m3</code>, <code>nomic-embed-text</code>) and run vector searches across any of them without re-extracting your original files.</p>
  </div>
</details>

<details>
  <summary>What is Hybrid Search (RRF)?</summary>
  <div class="faq-content">
    <p><strong>Reciprocal Rank Fusion (RRF)</strong> combines PostgreSQL full-text search (BM25-style keyword matching) with dense pgvector cosine similarity. This ensures that exact keyword matches (like specific function names or error codes) and semantic conceptual queries are merged into an optimal ranked result list.</p>
  </div>
</details>

---

## Model Context Protocol (MCP) & AI Clients

<details>
  <summary>Which MCP tools are available to Claude Desktop?</summary>
  <div class="faq-content">
    <p>Garage provides the following MCP tools to LLMs:</p>
    <ul>
      <li><code>rag_search</code>: Hybrid semantic and keyword search across your documents and code.</li>
      <li><code>rag_get_document</code>: Retrieve the full extracted text and metadata of a specific indexed file.</li>
      <li><code>rag_stats</code>: Overview of indexed document counts, chunk counts, and active models.</li>
      <li><code>rag_list_sources</code>: List all configured knowledge sources and their sync status.</li>
      <li><code>rag_list_models</code>: Inspect registered embedding models and vector dimensions.</li>
    </ul>
  </div>
</details>
