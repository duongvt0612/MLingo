# Milestone 07: Built-in MLX Runtime

**Outcome:** Installed MLX models provide offline translation, chat, and embeddings through the same capability contracts.

## Tasks

- [ ] Add direct package products for MLXLLM, MLXLMCommon, MLXEmbedders, Hugging Face, and tokenizer support while preserving one resolved MLX graph.
- [ ] Pin MLX Swift LM 3.31.4, swift-huggingface 0.9.0, and swift-transformers 1.3.3; validate native Release linkage.
- [ ] Add failing actor-isolation tests for local translation, chat streaming/cancellation, and embedding shapes.
- [ ] Implement built-in actor-based providers and provider-specific prompt/wire mapping.
- [ ] Add a shared runtime lease so only one in-process MLX model residency policy controls load/unload.
- [ ] Implement idle unload, cancellation, unified-memory preflight, and typed insufficient-memory recovery.
- [ ] Add a network spy and prove installed-model inference makes no network request.

## Acceptance

- One already-installed model translates and chats offline.
- Local embeddings are deterministic within documented numeric tolerances.
- Cancellation releases generation work and leases.
- No duplicate MLX runtime graph is linked or loaded.
