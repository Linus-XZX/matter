# matter

## Building

First generate the bindings between Rust and Flutter. This will need to be rerun on any change in Rust code or environment.

```bash
flutter_rust_bridge_codegen generate
```

A `flutter build` for a platform supported by your Flutter toolchain should generally work afterwards. The bridge component as a build product should be automatically configured for Android, iOS, Linux, macOS, and Windows. Other platforms are not tested, but should most likely only require some form of manual copying.

### macOS/iOS Specific notes

As the macOS build is tested on a Mac running the dev beta of macOS 27, whose toolchain only supports macOS 12.0 and higher, this will also be the minimum supported version for the current Xcode project as reported. This is different from the default minumum version as Flutter currently configures by default. While it is possible to change the minimum supported version by manually editing `macos/Runner.xcodeproj/project.pbxproj`, it is recommended to change it from Xcode instead. The same would apply to iOS builds (17.0 or higher).

Building for macOS (release build only) or iOS (physical or simulator) from a macOS 27 host requires Flutter 3.47.0 or higher due to [this Flutter issue](https://github.com/flutter/flutter/issues/188461).

For iOS, simulator builds (inherently Debug) are broken due to #56. Release build should work provided that you configure your own `DEVELOPMENT_TEAM` identifier.

Note that currently the Rust component is only built for the current arch while the Xcode build is universal for release. This results in a supposedly universal app but with a framework that only runs on the same arch it is built on.

### Windows specific notes

As stated in a TODO under rust/src/api/matrix.rs#2838, the login can fail due to an "Access Denied" error on Windows (reports a generic error on GUI, only visible in logs). This appears to be a race condition that can be worked around by making the `sleep` longer. The correct value (without making the wait too long) is most likely hardware dependent, and more testing is needed.
