# Milestone 07: Built-in MLX Runtime

**Outcome:** Installed MLX models provide offline translation, chat, and embeddings through the same capability contracts.

**Status:** Complete. The real installed-model acceptance ran on 2026-07-28 with
`mlx-community/Qwen3-0.6B-4bit` and `intfloat/multilingual-e5-small`; both opt-in suites
passed, including the network-spy assertion.

## Tasks

- [x] Add direct package products for MLXLLM, MLXLMCommon, MLXEmbedders, Hugging Face, and tokenizer support while preserving one resolved MLX graph.
- [x] Pin MLX Swift LM 3.31.4, swift-huggingface 0.9.0, and swift-transformers 1.3.3; validate native Release linkage.
- [x] Add failing actor-isolation tests for local translation, chat streaming/cancellation, and embedding shapes.
- [x] Implement built-in actor-based providers and provider-specific prompt/wire mapping.
- [x] Add a shared runtime lease so only one in-process MLX model residency policy controls load/unload.
- [x] Implement idle unload, cancellation, unified-memory preflight, and typed insufficient-memory recovery.
- [x] Add a network spy and prove installed-model inference makes no network request.

## Acceptance

- [x] One already-installed model translates and chats offline.
- [x] Local embeddings are deterministic within documented numeric tolerances.
- [x] Cancellation releases generation work and leases.
- [x] No duplicate MLX runtime graph is linked or loaded.

## Deep-review close-out (2026-07-21)

The comparison against `dev` found and fixed shared-residency, concurrency, cancellation,
memory-accounting, routing, and embedding-validation defects:

- Default providers now share one runtime, while each independent chat request receives its
  own non-thread-safe `ChatSession` over a shared thread-safe model container.
- Coalesced model loads now have per-waiter cancellation. The underlying load is cancelled
  only after the final waiter leaves, and cancellation is preserved instead of being wrapped
  as a model-load failure.
- Built-in profiles cannot fall through to the HTTP provider even when persisted configuration
  contains an invalid API style. Live composition routes them by provider kind.
- Unified-memory preflight uses host available pages instead of subtracting only this process's
  resident size from physical RAM. Model size uses logical file sizes.
- Embeddings reject count, empty-vector, dimension, and non-finite shape violations before
  stable normalization.
- The opt-in local integration suite installs a network spy around real model translation and
  chat. It remains intentionally skipped unless all required environment variables are present.

Validated in this checkout:

- `rtk swift test --filter BuiltInMLX`: 12 tests pass.
- `rtk swift test --filter openAICompatibleFactory`: 2 tests pass.
- `rtk swift test --no-parallel`: 310 tests pass.
- `rtk swift build -c release`: passes with the classified upstream MLXAudioVAD README warning.
- `rtk ./scripts/build-local-rc.sh`: native Release archive, arm64/signature checks, and app export pass at `.build/release/MLingo.app`.
- The resolved graph contains one package identity for each MLX dependency at the locked versions.

## Real-model acceptance recorded 2026-07-28

Both opt-in local suites passed against installed models:

- `builtInMLXLocalLLMRespondsAndTranslatesWhenEnabled` — 7.624s. Chat and translation both
  produced non-empty output, subtitle timing was preserved, and the registered
  `URLProtocol` spy recorded `requestCount == 0`, proving inference made no network request.
- `builtInMLXLocalEmbeddingModelEmbedsWhenEnabled` — 1.425s. Two successive calls returned
  matching vector dimensions, every vector was L2-normalised to within 0.001, and each element
  matched its counterpart from the other call to within 1e-5. The element-wise comparison is what
  makes the determinism claim real: shapes and norms alone would still agree if the values drifted.

Models used: `mlx-community/Qwen3-0.6B-4bit` at commit
`73e3e38d981303bc594367cd910ea6eb48349da8` and `intfloat/multilingual-e5-small` at commit
`614241f622f53c4eeff9890bdc4f31cfecc418b3`.

```bash
MLINGO_RUN_LOCAL_MLX_TESTS=1 \
MLINGO_LOCAL_LLM_DIR=/absolute/path/to/language-model \
MLINGO_LOCAL_EMBEDDING_DIR=/absolute/path/to/embedding-model \
rtk swift test --filter BuiltInMLXLocal --no-parallel
```

**Environment prerequisite.** SwiftPM does not package mlx-swift Metal resources into the
test bundle, so the run first aborts with `Failed to load the default metallib`. This is the
same packaging limitation already reported by `MLXWhisperEngine.loadModel(named:)`, not a
product defect. Copy the metallib produced by a native Release build next to the test binary
before running:

```bash
cp .build/xcode-derived/Build/Products/Release/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib \
   .build/arm64-apple-macosx/debug/MLingoPackageTests.xctest/Contents/MacOS/mlx.metallib
```

MLX searches for a colocated `mlx.metallib` before falling back to a SwiftPM bundle, so this
satisfies the first lookup. The copy lives entirely inside `.build` and is discarded by a
clean.
