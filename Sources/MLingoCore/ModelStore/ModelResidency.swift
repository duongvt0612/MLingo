import Foundation

/// Lets the Model Manager ask a runtime whether it has actually let go of a model's files.
///
/// A lease count of zero is not the same as "safe to delete". `BuiltInMLXRuntime` keeps weights
/// resident for an idle interval after the last lease is released, and while they are resident
/// the `.safetensors` files are still mapped. Deleting underneath that leaves the runtime holding
/// descriptors to files that no longer exist, and the next load fails somewhere far away from the
/// cause.
///
/// The runtime keeps sole authority over memory. This protocol only asks; `requestEviction`
/// returns `false` rather than forcing anything.
public protocol LocalModelResidencyReporting: Sendable {
    /// Directories the runtime currently has loaded or is loading.
    func residentModelDirectories() async -> Set<URL>

    /// How many callers are actively using the model at `directory`.
    func leaseCount(at directory: URL) async -> Int

    /// Asks the runtime to release `directory` now. Returns `false` while it is leased or still
    /// loading, in which case the files must be left alone.
    func requestEviction(at directory: URL) async -> Bool
}
