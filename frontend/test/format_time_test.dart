import 'package:flutter_test/flutter_test.dart';
import 'package:medilink/ui/format.dart';

void main() {
  test('zone-less backend time is read as UTC', () {
    final naive = parseBackendTime('2026-11-14T12:27:24.632000')!;
    final zoned = parseBackendTime('2026-11-14T12:27:24.632Z')!;
    expect(naive, zoned);
    expect(parseBackendTime('2026-11-14T12:27:24+05:30')!.toUtc().hour, 6);
    expect(parseBackendTime(null), isNull);
    expect(formatTimestamp('not a date'), 'not a date');
  });
}
