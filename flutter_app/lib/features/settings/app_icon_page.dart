import 'package:flutter/material.dart';

import '../../app/app_icon.dart';
import '../../design/tokens.dart';
import 'settings_widgets.dart';

/// Impostazioni ▸ Icona dell'app: sceglie lo stile dell'icona (anteprima di ognuno). Cambia solo l'icona, non lo stile dell'app.
class AppIconSettingsPage extends StatefulWidget {
  const AppIconSettingsPage({super.key});

  @override
  State<AppIconSettingsPage> createState() => _AppIconSettingsPageState();
}

class _AppIconSettingsPageState extends State<AppIconSettingsPage> {
  String _current = 'Default';
  String? _message;

  @override
  void initState() {
    super.initState();
    AppIconService.current().then((v) {
      if (mounted) setState(() => _current = v);
    });
  }

  Future<void> _choose(AppIconStyle s) async {
    if (s.id == _current) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Usare l\u2019icona «${s.label}»?'),
        content: const Text(
          'Su alcuni telefoni la schermata iniziale si aggiorna dopo qualche secondo e l\u2019app può chiudersi: riaprila dalla nuova icona.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Cambia'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final done = await AppIconService.set(s.id);
    if (!mounted) return;
    setState(() {
      if (done) _current = s.id;
      _message = done
          ? 'Icona cambiata: «${s.label}».'
          : 'Non sono riuscito a cambiare l\u2019icona.';
    });
  }

  @override
  Widget build(BuildContext context) => SettingsPageFrame(
    title: 'Icona dell\u2019app',
    children: [
      if (!AppIconService.supported)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Il cambio dell\u2019icona è disponibile su Android.'),
        )
      else
        SettingsGroup(
          footer: 'Cambia solo l\u2019icona sulla schermata iniziale, non lo stile dell\u2019app. Se la tua schermata iniziale non la aggiorna, togli l\u2019icona e riaggiungila dal menu delle app.',
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  for (final s in kAppIconStyles)
                    InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () => _choose(s),
                      child: SizedBox(
                        width: 88,
                        child: Column(
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: s.id == _current
                                      ? AetherTokens.success
                                      : Colors.white24,
                                  width: s.id == _current ? 3 : 1,
                                ),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(17),
                                child: Image.asset(
                                  s.asset,
                                  width: 80,
                                  height: 80,
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              s.label,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(_message!),
              ),
          ],
        ),
    ],
  );
}
