import Foundation
import Testing
@testable import MLingoCore

private let whisper = ModelID("mlx-community/whisper-base-mlx")
private let qwen = ModelID("mlx-community/Qwen3-0.6B-4bit")

@Test
func leaseRegistryCountsConcurrentAcquisitions() async {
    let registry = ModelLeaseRegistry()
    let first = await registry.acquire(whisper)
    let second = await registry.acquire(whisper)

    #expect(await registry.count(for: whisper) == 2)
    #expect(await registry.isLeased(whisper))
    #expect(first != second, "each acquisition needs its own token")

    await registry.release(first)
    #expect(await registry.count(for: whisper) == 1)
    await registry.release(second)
    #expect(await registry.count(for: whisper) == 0)
    #expect(await registry.isLeased(whisper) == false)
}

@Test
func leaseRegistryReleaseIsIdempotent() async {
    let registry = ModelLeaseRegistry()
    let token = await registry.acquire(whisper)

    await registry.release(token)
    await registry.release(token)
    await registry.release(token)

    // Releasing twice must not drive the count negative and let a live model be deleted.
    #expect(await registry.count(for: whisper) == 0)
    #expect(await registry.leasedModels.isEmpty)
}

@Test
func leaseRegistryIsolatesCountsPerModel() async {
    let registry = ModelLeaseRegistry()
    let whisperToken = await registry.acquire(whisper)
    _ = await registry.acquire(qwen)
    _ = await registry.acquire(qwen)

    #expect(await registry.count(for: whisper) == 1)
    #expect(await registry.count(for: qwen) == 2)
    #expect(await registry.leasedModels == Set([whisper, qwen]))

    await registry.release(whisperToken)
    #expect(await registry.leasedModels == Set([qwen]))
}

@Test
func leaseRegistryReportsNoLeaseForAnUnknownModel() async {
    let registry = ModelLeaseRegistry()
    #expect(await registry.count(for: whisper) == 0)
    #expect(await registry.isLeased(whisper) == false)
}

@Test
func leaseRegistrySurvivesConcurrentAcquireAndRelease() async {
    let registry = ModelLeaseRegistry()

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<64 {
            group.addTask {
                let token = await registry.acquire(whisper)
                await registry.release(token)
            }
        }
    }

    #expect(await registry.count(for: whisper) == 0)
    #expect(await registry.leasedModels.isEmpty)
}
