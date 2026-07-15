# MLingo app resources

`Info.plist`, `MLingo.entitlements`, and `Assets.xcassets` belong to the native `MLingo` application target in `MLingo.xcodeproj`.

The SwiftPM executable target remains available for compile and test compatibility. It is not the release bundle; use the shared Xcode scheme or `scripts/build-local-rc.sh` when MLX Metal resources must be packaged.
