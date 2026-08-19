# matter

## Building

### macOS/iOS Specific notes

As the macOS build is tested on a Mac running the dev beta of macOS 27, whose toolchain only supports macOS 12.0 and higher, this will also be the minimum supported version for the current Xcode project as reported. This is different from the default minumum version as Flutter currently configures by default. While it is possible to change the minimum supported version by manually editing `macos/Runner.xcodeproj/project.pbxproj`, it is recommended to change it from Xcode instead.

Building for macOS (release build only) or iOS (physical or simulator) from a macOS 27 host requires Flutter 3.47.0 or higher due to [this Flutter issue](https://github.com/flutter/flutter/issues/188461).
