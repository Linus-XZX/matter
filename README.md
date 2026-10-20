# matter

## Push notifications

Push settings distinguish browser Web Push/VAPID from Android FCM. Matter provides no default gateway or Firebase project. Android users can import their own `google-services.json` in settings without rebuilding the APK; builders may also prefill public client configuration. See [push setup and testing](docs/fcm-push.md), including the current Rust WASM limitation for the complete Web client.

## UI conventions

Matter draws the same widgets in a new-skeuomorphic skin and a Material one. Type scale, surface levels, list structure, row semantics and navigation rules are recorded in [UI conventions](docs/ui-conventions.md).

## Building

First generate the bindings between Rust and Flutter. This will need to be rerun on any change in Rust code or environment.

```bash
flutter_rust_bridge_codegen generate
```

A `flutter build` for a platform supported by your Flutter toolchain should generally work afterwards. The bridge component as a build product should be automatically configured for Android, iOS, Linux, macOS, and Windows. Web is untested.

### macOS/iOS Specific notes

If you are building on a macOS 27 host:
- <del>Flutter 3.47.0 or higher is required due to [this Flutter issue](https://github.com/flutter/flutter/issues/188461).</del> No longer an extra requirement since the project's own Flutter dependency is now higher.
- Rust 1.98.0 or higher might be required due to [this Rust issue](https://github.com/rust-lang/rust/issues/157750). The primary indicator is if you run into Rust errors on `*_derive` libraries, and a second build reports errors involving `LINKEDIT` misalignments.

#### macOS

While the app's main executable is universal by default for release builds (unless you have `--enable-macos-arm64-only` in your Flutter config), the Rust component is only built for the current arch. For a proper universal build, you will need to cross-compile and `lipo` the builds manually.

#### iOS

When building for iOS, you most likely need to set up your own provisioning for any form of deployment beyond a simulator. A free Developer ID would suffice for deploying to your physical device, but requires rebuilding once a week.
