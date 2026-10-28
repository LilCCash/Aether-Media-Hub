import 'dart:convert';
import 'dart:io';

import 'package:aether_flutter/app/services.dart';
import 'package:aether_flutter/core/model/meta.dart';
import 'package:aether_flutter/data/backup.dart';
import 'package:aether_flutter/data/settings.dart';
import 'package:aether_flutter/data/stores.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_adapter.dart';

const _manifest =
    '{"id":"org.b","name":"B","resources":["catalog"],"catalogs":[{"type":"movie","id":"x","name":"X"}]}';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('aether_bk'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<AppServices> make() => AppServices.build(
    store: MemoryStore(),
    secrets: MemorySecretStore(),
    downloadsDir: dir,
    dio: fakeDio((o) => (status: 200, body: _manifest)),
  );

  test('keys and addon addresses are exported only when asked, and restore brings everything back', () async {
    final a = await make();
    await a.library.toggleFavorite(
      const MetaItem(id: 'tt1', type: 'movie', name: 'F'),
    );
    await a.secrets.setServiceKey(ServiceKey.torbox, 'TB-SECRET');
    await a.addons.install(
      await a.addons.preview('https://x.example/cfgSECRET'),
    );
    final plain = await BackupService(a)
        .export(settings: const AppSettings(amoled: true));
    expect(plain, isNot(contains('TB-SECRET')));
    expect(plain, isNot(contains('cfgSECRET')));
    final full = await BackupService(a).export(
      settings: const AppSettings(amoled: true),
      includeKeys: true,
      includeAddonAddresses: true,
    );
    expect(jsonDecode(full)['serviceKeys']['torbox'], 'TB-SECRET');

    final b = await make();
    AppSettings? applied;
    final summary = await BackupService(b)
        .restore(full, applySettings: (s) async => applied = s);
    expect(applied!.amoled, isTrue);
    expect(summary.libraryItems, 1);
    expect(summary.keys, 1);
    expect(summary.addons, 1);
    expect(await b.secrets.serviceKey(ServiceKey.torbox), 'TB-SECRET');
    expect(b.library.isFavorite('tt1'), isTrue);
  });

  test(
    'anything that is not a backup is refused with a clear message',
    () async {
      final a = await make();
      await expectLater(
        BackupService(a).restore('ciao', applySettings: (_) async {}),
        throwsFormatException,
      );
      await expectLater(
        BackupService(a)
            .restore('{"format":"altro"}', applySettings: (_) async {}),
        throwsFormatException,
      );
    },
  );
}
