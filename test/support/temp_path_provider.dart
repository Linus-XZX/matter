import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// `path_provider` replacement backed by a temp directory.
///
/// Both the support and temporary directories are implemented on purpose:
/// mixing in `MockPlatformInterfaceMixin` makes every unimplemented method
/// throw, and other suites (and `flutter_cache_manager`) resolve the temp
/// directory, so overriding only one path would break them.
class TempPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  TempPathProvider(this.root);

  final Directory root;

  @override
  Future<String?> getApplicationSupportPath() async => root.path;

  @override
  Future<String?> getTemporaryPath() async => root.path;

  @override
  Future<String?> getApplicationCachePath() async => root.path;
}

/// Install [TempPathProvider] for one test and restore the previous platform
/// afterwards, so a suite never leaks a global override into another.
TempPathProvider installTempPathProvider(Directory root) {
  final previous = PathProviderPlatform.instance;
  final provider = TempPathProvider(root);
  PathProviderPlatform.instance = provider;
  addTearDown(() => PathProviderPlatform.instance = previous);
  return provider;
}
