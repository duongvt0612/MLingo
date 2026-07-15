# Milestone 03: Remote OpenAI-Compatible Providers

**Outcome:** Remote and loopback OpenAI-compatible endpoints share one explicit, testable transport layer.

## Tasks

- [ ] Characterize the current OpenAI wire contract with `URLProtocol` fixtures.
- [ ] Add failing fixtures for Responses and Chat Completions request mapping, streamed/non-streamed responses, token usage, cancellation, malformed payloads, and HTTP errors.
- [ ] Implement API-style-specific transports for `/v1/responses` and `/v1/chat/completions`.
- [ ] Add OpenAI, Ollama, LM Studio, and custom presets without hiding endpoint or API-style choices.
- [ ] Test and implement none, bearer, and one custom secret-header authentication mode.
- [ ] Test optional model discovery, draft connection testing, timeout, TLS/HTTP policy, and typed recovery mapping.
- [ ] Add opt-in live suites for OpenAI, Ollama, and LM Studio; keep them excluded from default tests.

## Acceptance

- One translation fixture succeeds through both supported API styles.
- At least one loopback compatible server passes the opt-in integration suite.
- Logs and diagnostics redact bearer/custom secrets and user text by default.
- No network call occurs in the default suite.
