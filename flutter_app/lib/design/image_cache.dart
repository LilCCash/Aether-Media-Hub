import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// The cache of downloaded pictures. Its size limit comes from the settings (about 150 KB a picture, so 6 pictures per MB); a
/// change applies from the next launch, when the manager is created again.
class AetherImageCache {
  AetherImageCache._();

  static int _mb = 300;
  static CacheManager? _manager;

  static void configure(int mb) => _mb = mb.clamp(50, 2000);

  static CacheManager get manager => _manager ??= CacheManager(
    Config(
      'aetherImages',
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: _mb * 6,
    ),
  );
}
