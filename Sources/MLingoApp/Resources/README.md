# MLingo App Metadata

`Info.plist` and `MLingo.entitlements` are included for the macOS app target when this Swift package is opened in Xcode or wrapped in an archive target.

The SwiftPM executable target is used for compile and test validation. A real Xcode project/archive target should be created later for release packaging; do not use a hand-written fake `.xcodeproj`.
