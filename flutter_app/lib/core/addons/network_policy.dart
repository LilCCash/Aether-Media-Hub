/// Which addresses Aether is willing to contact for an addon or a subtitle file. Addons are third-party: their addresses are
/// validated before any request, and an addon can never point Aether at the user's own machine.
class NetworkPolicy {
  const NetworkPolicy({this.allowLocalNetwork = false});

  /// Addons on the user's own network (a NAS, a Raspberry Pi) are legitimate but must be switched on explicitly.
  final bool allowLocalNetwork;

  /// Returns a reason in Italian when the address must not be used, or null when it is acceptable.
  String? reject(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return 'L’indirizzo deve iniziare con http:// o https://.';
    }
    if (uri.host.isEmpty) return 'L’indirizzo non contiene un host.';
    if (uri.userInfo.isNotEmpty) {
      return 'Gli indirizzi con nome utente e password non sono ammessi.';
    }
    final host = uri.host.toLowerCase();
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        host == '0.0.0.0' ||
        host == '::1' ||
        host == '[::1]') {
      return 'Gli indirizzi sul dispositivo stesso (localhost) non sono ammessi.';
    }
    final v4 = _parseV4(host);
    if (v4 != null) {
      if (v4[0] == 127) {
        return 'Gli indirizzi sul dispositivo stesso (127.x) non sono ammessi.';
      }
      if (v4[0] == 0) return 'Indirizzo non valido.';
      if (_isPrivateV4(v4) && !allowLocalNetwork) {
        return 'Gli indirizzi della rete locale sono bloccati: attivali in Impostazioni ▸ Contenuti se l’addon è tuo.';
      }
    } else if ((host.endsWith('.local') ||
            host.endsWith('.lan') ||
            host.endsWith('.internal') ||
            !host.contains('.')) &&
        !allowLocalNetwork) {
      return 'Gli indirizzi della rete locale sono bloccati: attivali in Impostazioni ▸ Contenuti se l’addon è tuo.';
    }
    return null;
  }

  static List<int>? _parseV4(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return null;
    final nums = parts.map(int.tryParse).toList();
    if (nums.any((n) => n == null || n < 0 || n > 255)) return null;
    return nums.cast<int>();
  }

  static bool _isPrivateV4(List<int> a) =>
      a[0] == 10 ||
      (a[0] == 172 && a[1] >= 16 && a[1] <= 31) ||
      (a[0] == 192 && a[1] == 168) ||
      (a[0] == 169 && a[1] == 254) ||
      (a[0] == 100 && a[1] >= 64 && a[1] <= 127);
}

/// Turns what the user pastes (or a deep link) into the base address of an addon.
class AddonUrl {
  const AddonUrl._();

  /// `stremio://host/path/manifest.json`, `https://host/path/manifest.json`, `https://host/path` → `https://host/path`.
  /// Returns null when nothing usable is found.
  static Uri? parseBase(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;
    if (text.toLowerCase().startsWith('aether://')) {
      final link = Uri.tryParse(text);
      final target = link?.queryParameters['url'];
      if (target == null) return null;
      text = target;
    }
    if (text.toLowerCase().startsWith('stremio://')) {
      text = 'https://${text.substring('stremio://'.length)}';
    }
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    var path = uri.path;
    if (path.endsWith('/manifest.json')) {
      path = path.substring(0, path.length - '/manifest.json'.length);
    }
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return Uri(
      scheme: uri.scheme.toLowerCase(),
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: path,
      query: uri.hasQuery ? uri.query : null,
    );
  }

  static Uri manifest(Uri base) =>
      base.replace(path: '${base.path}/manifest.json');

  /// The page where an addon is configured (`/configure`), when the manifest says it has one.
  static Uri configure(Uri base) =>
      base.replace(path: '${base.path}/configure');
}
