/// Display-only formatting. Never used on data sent to the backend.
library;

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// `LAB_REPORT` → `Lab report`. Non-strings and empty values pass through as text.
String humanizeEnum(Object? value) {
  final s = value?.toString().trim() ?? '';
  // Empty, or a short acronym such as ML / AI: show as-is.
  if (s.isEmpty || (s.length <= 3 && !s.contains('_'))) return s;
  final words = s.replaceAll('_', ' ').toLowerCase();
  return words[0].toUpperCase() + words.substring(1);
}

/// Backend timestamps are UTC but arrive without a zone suffix (Mongo returns naive datetimes);
/// a string with no `Z`/offset is read as UTC, then converted to the phone's local time.
DateTime? parseBackendTime(Object? value) {
  final raw = value?.toString() ?? '';
  final zoned = raw.isEmpty || RegExp(r'(Z|[+-]\d\d:?\d\d)$').hasMatch(raw) ? raw : '${raw}Z';
  return DateTime.tryParse(zoned)?.toLocal();
}

/// ISO-8601 timestamp → "Today, 9:28 AM" / "Yesterday, 9:28 AM" / "4 Nov, 9:28 AM" / "4 Nov 2025, 9:28 AM".
/// Anything that doesn't parse is returned unchanged.
String formatTimestamp(Object? value, {DateTime? now}) {
  final raw = value?.toString() ?? '';
  final t = parseBackendTime(raw);
  if (t == null) return raw;
  final n = now ?? DateTime.now();
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final clock = '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  final day = DateTime(t.year, t.month, t.day);
  final diff = DateTime(n.year, n.month, n.day).difference(day).inDays;
  if (diff == 0) return 'Today, $clock';
  if (diff == 1) return 'Yesterday, $clock';
  final date = '${t.day} ${_months[t.month - 1]}${t.year == n.year ? '' : ' ${t.year}'}';
  return '$date, $clock';
}
