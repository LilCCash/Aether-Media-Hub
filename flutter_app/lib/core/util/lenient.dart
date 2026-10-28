import 'dart:convert';

/// Tolerant readers for JSON coming from addons and services: a malformed field never throws, it reads as "absent".
String? asString(Object? v) {
  if (v == null) return null;
  if (v is String) return v;
  if (v is num || v is bool) return v.toString();
  return null;
}

String? asNonEmptyString(Object? v) {
  final s = asString(v)?.trim();
  return (s == null || s.isEmpty) ? null : s;
}

int? asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

double? asDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

bool asBool(Object? v, {bool fallback = false}) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final s = v.toLowerCase();
    if (s == 'true' || s == '1') return true;
    if (s == 'false' || s == '0') return false;
  }
  return fallback;
}

List<Object?> asList(Object? v) => v is List ? v : const [];

Map<String, Object?>? asMap(Object? v) {
  if (v is Map) {
    return v.map((k, value) => MapEntry(k.toString(), value));
  }
  return null;
}

List<String> asStringList(Object? v) {
  if (v is List) return v.map(asNonEmptyString).whereType<String>().toList();
  final single = asNonEmptyString(v);
  return single == null ? const [] : [single];
}

DateTime? asDate(Object? v) {
  final s = asNonEmptyString(v);
  if (s == null) return null;
  return DateTime.tryParse(s);
}

/// Decodes a JSON text; throws [FormatException] when it is not JSON.
Object? asMapOrList(String text) => jsonDecode(text);
