import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/diagnostics/diagnostic_exporter.dart';

void main() {
  test('redacts sensitive log values on export', () {
    final redacted = redactLogMessage(
      'password=secret access_token: "abc" Authorization: Bearer token-value',
    );

    expect(redacted, contains('password=[REDACTED]'));
    expect(redacted, contains('access_token:[REDACTED]'));
    expect(redacted, contains('Bearer [REDACTED]'));
    expect(redacted, isNot(contains('secret')));
    expect(redacted, isNot(contains('abc')));
    expect(redacted, isNot(contains('token-value')));
  });
}
