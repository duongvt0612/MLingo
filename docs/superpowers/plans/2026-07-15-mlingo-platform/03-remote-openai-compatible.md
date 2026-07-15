# Milestone 03: Remote OpenAI-Compatible Providers

**Outcome:** Remote and loopback OpenAI-compatible endpoints share one explicit, testable transport layer.

## Tasks

- [x] Characterize the current OpenAI wire contract with offline HTTP fixtures (`HTTPClientProtocol` script harness; not `URLProtocol`).
- [x] Add fixtures for Responses and Chat Completions request mapping, streamed/non-streamed responses, token usage, cancellation, malformed payloads, and HTTP errors.
- [x] Implement API-style-specific transports for `/v1/responses` and `/v1/chat/completions`.
- [x] Add OpenAI, Ollama, LM Studio, and custom presets without hiding endpoint or API-style choices.
- [x] Test and implement none, bearer, and one custom secret-header authentication mode.
- [x] Test optional model discovery, draft connection testing, timeout, TLS/HTTP policy, and typed recovery mapping.
- [x] Add opt-in live suites for OpenAI, Ollama, and LM Studio; keep them excluded from default tests (`MLINGO_RUN_LIVE_PROVIDER_TESTS=1` required).

## Acceptance

- [x] One translation fixture succeeds through both supported API styles.
- [ ] At least one loopback compatible server passes the opt-in integration suite.
  **Not yet proven in CI/default runs.** Live Ollama/LM Studio tests only execute when
  `MLINGO_RUN_LIVE_PROVIDER_TESTS=1` **and** the corresponding base URL is set. Mark this
  when those tests have been run successfully against a real loopback server.
- [x] Logs and diagnostics redact bearer/custom secrets and user text by default.
  Production transport never logs request bodies, credentials, or user text; server-controlled
  `x-request-id` values are sanitized before logging. The production logging audit and
  `ProviderDiagnosticRedactor` coverage were accepted on 2026-07-16.
- [x] No network call occurs in the default suite.
