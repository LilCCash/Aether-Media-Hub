import 'package:dio/dio.dart';

import '../model/stream.dart';
import 'debrid_resolver.dart';

/// What the player flow needs from a debrid service, whichever it is.
abstract class DebridProvider {
  String get name;

  /// Which of [hashes] the service already has ready; null when the service cannot tell (Real-Debrid disabled its
  /// availability endpoint, so there are no "in cache" pills for it).
  Future<Map<String, bool>?> cached(List<String> hashes, {CancelToken? cancel});

  Future<ResolvedLink> resolve(
    AddonStream stream, {
    bool allowDownload = false,
    int? season,
    int? episode,
    void Function(ResolveStatus)? onStatus,
    CancelToken? cancel,
  });
}
