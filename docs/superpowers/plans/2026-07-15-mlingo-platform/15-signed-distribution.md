# Milestone 15: Signed and Notarized Distribution

**Outcome:** MLingo ships as a verifiable Developer ID application that retains MLX, audio, and model-download functionality on a clean Mac.

## Tasks

- [ ] Define Debug and Release entitlements; keep App Sandbox off and Hardened Runtime on.
- [ ] Prove Release contains only the required MLX JIT exception and excludes get-task-allow and disable-library-validation.
- [ ] Add scripts/CI for Release archive, nested-code signing, DMG/ZIP creation, checksum, dependency inventory, and SBOM.
- [ ] Verify signatures and entitlements recursively before submission.
- [ ] Submit with `notarytool`, capture log, staple ticket, and verify with `spctl` plus offline ticket assessment.
- [ ] Run clean-machine acceptance for launch, permissions, capture, MLX inference, provider Keychain access, custom storage, and model download.
- [ ] Document certificate/profile prerequisites and opt-in release commands without committing secrets.

## Acceptance

- `codesign`, `spctl`, notarization log, and stapling verification pass.
- Clean-machine MLX inference and audio permission flows pass.
- Release has no debug or broad library-validation entitlement.
- Published artifacts include checksums and dependency/SBOM inventory.
