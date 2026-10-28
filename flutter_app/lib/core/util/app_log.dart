/// A small in-memory diagnostic log (kept only on the device, shown in Settings ▸ Diagnostica). It redacts what looks like a
/// secret before anything is stored, so a copied log never carries a key.
class AppLog {
  AppLog._();
  static final AppLog instance = AppLog._();

  static const int capacity = 400;
  final List<String> _lines = [];

  List<String> get lines => List.unmodifiable(_lines);

  /// Settings ▸ Diagnostica ▸ «Conserva il registro»: when off nothing is recorded.
  bool enabled = true;

  void add(String area, String message) {
    if (!enabled) return;
    final now = DateTime.now().toIso8601String().substring(11, 19);
    _lines.add('$now [$area] ${redact(message)}');
    if (_lines.length > capacity)
      _lines.removeRange(0, _lines.length - capacity);
  }

  void clear() => _lines.clear();

  static final RegExp _query = RegExp(
    r'([?&](?:api_key|apikey|token|key|apiKey|access_token)=)[^&\s]+',
    caseSensitive: false,
  );
  static final RegExp _bearer = RegExp(
    r'(Bearer\s+)[A-Za-z0-9._\-]+',
    caseSensitive: false,
  );
  static final RegExp _userinfo = RegExp(r'(https?://)[^/\s:@]+:[^/\s@]+@');
  // Addon addresses may embed the user's configuration in the path: keep only the host.
  static final RegExp _addonPath = RegExp(
    r'(https?://[^/\s]+)/[^\s]*manifest\.json',
  );

  static String redact(String input) {
    var s = input.replaceAllMapped(_query, (m) => '${m[1]}***');
    s = s.replaceAllMapped(_bearer, (m) => '${m[1]}***');
    s = s.replaceAllMapped(_userinfo, (m) => '${m[1]}***@');
    s = s.replaceAllMapped(_addonPath, (m) => '${m[1]}/…/manifest.json');
    return s;
  }
}
