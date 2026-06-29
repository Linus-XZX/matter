import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matter/features/app_update/app_update_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SemanticVersion', () {
    test('parses release tags and compares numeric components', () {
      final current = SemanticVersion.tryParse('0.1.9')!;
      final latest = SemanticVersion.tryParse('v0.2.0')!;

      expect(latest.compareTo(current), greaterThan(0));
      expect(latest.normalized, '0.2.0');
    });

    test('orders stable releases after prereleases', () {
      final prerelease = SemanticVersion.tryParse('v1.0.0-beta.2')!;
      final stable = SemanticVersion.tryParse('1.0.0')!;

      expect(stable.compareTo(prerelease), greaterThan(0));
    });

    test('rejects incomplete version numbers', () {
      expect(SemanticVersion.tryParse('v1.2'), isNull);
    });
  });

  group('AppUpdateService', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
    });
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('returns the exact Android arm64 asset for a newer release', () async {
      final service = _serviceWithResponse(
        tag: 'v0.2.0',
        assets: [
          _asset('matter-linux-x64.tar.gz'),
          _asset('matter-android-arm64.apk'),
        ],
      );

      final result = await service.checkForUpdate(force: true);

      expect(result.status, UpdateCheckStatus.available);
      expect(result.update?.version, '0.2.0');
      expect(
        result.update?.downloadUrl.path,
        endsWith('/matter-android-arm64.apk'),
      );
      expect(result.update?.digest, startsWith('sha256:'));
    });

    test('reports up to date when the release tag matches', () async {
      final service = _serviceWithResponse(tag: 'v0.1.2');

      final result = await service.checkForUpdate(force: true);

      expect(result.status, UpdateCheckStatus.upToDate);
      expect(result.update, isNull);
    });

    test('automatic checks are throttled for 24 hours', () async {
      var requests = 0;
      var now = DateTime(2026, 6, 29, 8);
      final service = _serviceWithResponse(
        tag: 'v0.2.0',
        now: () => now,
        onRequest: () => requests++,
      );

      expect(
        (await service.checkForUpdate()).status,
        UpdateCheckStatus.available,
      );
      now = now.add(const Duration(hours: 23));
      expect(
        (await service.checkForUpdate()).status,
        UpdateCheckStatus.skipped,
      );
      expect(requests, 1);

      now = now.add(const Duration(hours: 1));
      expect(
        (await service.checkForUpdate()).status,
        UpdateCheckStatus.available,
      );
      expect(requests, 2);
    });

    test('manual checks bypass the automatic throttle', () async {
      var requests = 0;
      final service = _serviceWithResponse(
        tag: 'v0.2.0',
        onRequest: () => requests++,
      );

      await service.checkForUpdate();
      await service.checkForUpdate(force: true);

      expect(requests, 2);
    });
  });
}

AppUpdateService _serviceWithResponse({
  required String tag,
  List<Map<String, Object?>>? assets,
  DateTime Function()? now,
  void Function()? onRequest,
}) {
  final client = MockClient((request) async {
    onRequest?.call();
    return http.Response(
      jsonEncode({
        'tag_name': tag,
        'name': tag,
        'body': 'Release notes',
        'html_url': 'https://github.com/slopwerks/matter/releases/tag/$tag',
        'assets': assets ?? [_asset('matter-android-arm64.apk')],
      }),
      200,
    );
  });
  return AppUpdateService(
    client: client,
    packageInfoLoader: () async => PackageInfo(
      appName: 'Matter',
      packageName: 'moe.aks.matter',
      version: '0.1.2',
      buildNumber: '1',
    ),
    now: now,
  );
}

Map<String, Object?> _asset(String name) => {
  'name': name,
  'browser_download_url':
      'https://github.com/slopwerks/matter/releases/download/v0.2.0/$name',
  'size': 36 * 1024 * 1024,
  'digest': 'sha256:${'a' * 64}',
};
