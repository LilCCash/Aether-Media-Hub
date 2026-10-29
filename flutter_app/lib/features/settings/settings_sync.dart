import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../core/sync/sync_app.dart';
import '../../core/sync/trakt_client.dart';
import '../../data/prefs_ext.dart';
import '../../data/settings.dart';
import '../../data/stores.dart';
import '../../design/glass.dart';
import '../../design/tokens.dart';
import 'settings_extra.dart';

/// Trakt and Simkl, as a «tendina» in Servizi: the viewer's own application keys, the code to type on the service's page, the
/// options of what is kept in step, and «Sincronizza ora».
class SyncServiceTile extends ConsumerStatefulWidget {
  const SyncServiceTile({super.key, required this.trakt});

  /// true: Trakt (client id + secret, device code); false: Simkl (client id, PIN).
  final bool trakt;

  @override
  ConsumerState<SyncServiceTile> createState() => _SyncServiceTileState();
}

class _SyncServiceTileState extends ConsumerState<SyncServiceTile> {
  final _id = TextEditingController();
  final _secret = TextEditingController();
  bool _linked = false;
  bool _hasKeys = false;
  DeviceCode? _code;
  Timer? _poll;
  String? _message;
  bool _busy = false;

  String get _name => widget.trakt ? 'Trakt' : 'Simkl';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _id.dispose();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final sv = ref.read(servicesProvider);
    final id = await sv.secrets.serviceKey(
      widget.trakt ? ServiceKey.traktClient : ServiceKey.simklClient,
    );
    final secret = widget.trakt
        ? await sv.secrets.serviceKey(ServiceKey.traktSecret)
        : 'x';
    final linked = widget.trakt
        ? await sv.sync.trakt.linked
        : await sv.sync.simkl.linked;
    if (mounted) {
      setState(() {
        _hasKeys = widget.trakt
            ? (SyncApp.hasTrakt ||
                  ((id ?? '').isNotEmpty && (secret ?? '').isNotEmpty))
            : (SyncApp.hasSimkl ||
                  ((id ?? '').isNotEmpty && (secret ?? '').isNotEmpty));
        _linked = linked;
      });
    }
  }

  Future<void> _saveKeys() async {
    final sv = ref.read(servicesProvider);
    await sv.secrets.setServiceKey(
      widget.trakt ? ServiceKey.traktClient : ServiceKey.simklClient,
      _id.text,
    );
    if (widget.trakt) {
      await sv.secrets.setServiceKey(ServiceKey.traktSecret, _secret.text);
    }
    _id.clear();
    _secret.clear();
    setState(() => _message = 'Chiavi salvate. Ora puoi collegare $_name.');
    await _refresh();
  }

  Future<void> _connect() async {
    final sv = ref.read(servicesProvider);
    setState(() {
      _busy = true;
      _message = null;
    });
    final code = widget.trakt
        ? await sv.sync.trakt.startDevice()
        : await sv.sync.simkl.startPin();
    if (!mounted) return;
    if (code == null) {
      setState(() {
        _busy = false;
        _message = '$_name non ha risposto: controlla le chiavi e la rete.';
      });
      return;
    }
    setState(() {
      _code = code;
      _busy = false;
    });
    final until = DateTime.now().add(Duration(seconds: code.expiresIn));
    _poll?.cancel();
    _poll = Timer.periodic(Duration(seconds: code.interval.clamp(3, 15)), (
      t,
    ) async {
      if (!mounted || DateTime.now().isAfter(until)) {
        t.cancel();
        if (mounted) {
          setState(() {
            _code = null;
            _message = 'Il codice è scaduto: riprova.';
          });
        }
        return;
      }
      final r = widget.trakt
          ? await sv.sync.trakt.pollDevice(code.deviceCode)
          : await sv.sync.simkl.pollPin(code.deviceCode);
      if (!mounted) return;
      if (r == DevicePoll.linked) {
        t.cancel();
        setState(() {
          _code = null;
          _message = '$_name collegato.';
        });
        await _refresh();
      } else if (r == DevicePoll.denied || r == DevicePoll.expired) {
        t.cancel();
        setState(() {
          _code = null;
          _message = r == DevicePoll.denied
              ? 'Collegamento rifiutato.'
              : 'Il codice è scaduto: riprova.';
        });
      }
    });
  }

  Future<void> _disconnect() async {
    final sv = ref.read(servicesProvider);
    widget.trakt
        ? await sv.sync.trakt.disconnect()
        : await sv.sync.simkl.disconnect();
    setState(() => _message = '$_name scollegato.');
    await _refresh();
  }

  Future<void> _syncNow() async {
    setState(() {
      _busy = true;
      _message = 'Sincronizzo…';
    });
    final text = await ref.read(servicesProvider).sync.pullTrakt();
    ref.read(libraryVersionProvider.notifier).bump();
    if (mounted) {
      setState(() {
        _busy = false;
        _message = text;
      });
    }
  }

  InputDecoration _field(String hint) => InputDecoration(
    hintText: hint,
    filled: true,
    fillColor: Colors.white10,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final color = widget.trakt
        ? const Color(0xFFFF4D4D)
        : const Color(0xFF3FB6FF);
    final label = _linked
        ? 'Collegato'
        : (_hasKeys ? 'Chiavi salvate' : 'Non configurato');
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassSurface(
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 16),
            shape: const Border(),
            collapsedShape: const Border(),
            leading: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: _linked ? AetherTokens.success : color,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                widget.trakt
                    ? Icons.sync_alt_rounded
                    : Icons.track_changes_rounded,
                size: 19,
                color: Colors.white,
              ),
            ),
            title: Text(
              _name,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
            subtitle: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: _linked
                    ? AetherTokens.success
                    : AetherTokens.textTertiary,
              ),
            ),
            trailing: _linked
                ? const Icon(
                    Icons.check_circle_rounded,
                    color: AetherTokens.success,
                  )
                : null,
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.trakt
                    ? 'Registra gratis un’applicazione su trakt.tv/oauth/applications (come indirizzo di reindirizzamento: urn:ietf:wg:oauth:2.0:oob), poi incolla qui Client ID e Client Secret. Aether segna ciò che guardi, porta qui i tuoi visti e la tua watchlist.'
                    : 'Crea gratis un’applicazione su simkl.com/settings/developer e incolla qui il Client ID. Aether segna come visto ciò che finisci e invia la watchlist.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (!_hasKeys) ...[
                TextField(
                  controller: _id,
                  autocorrect: false,
                  decoration: _field('Client ID'),
                ),
                if (widget.trakt) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _secret,
                    obscureText: true,
                    autocorrect: false,
                    decoration: _field('Client Secret'),
                  ),
                ],
                const SizedBox(height: 10),
                GlassButton(
                  icon: Icons.save_rounded,
                  label: 'Salva le chiavi',
                  onPressed: _saveKeys,
                ),
              ] else if (!_linked) ...[
                if (_code != null) ...[
                  Text(
                    'Apri ${_code!.verificationUrl} e scrivi il codice:',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    _code!.userCode,
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 4,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      GlassButton(
                        icon: Icons.open_in_new_rounded,
                        label: 'Apri la pagina',
                        onPressed: () => launchUrl(
                          Uri.parse(_code!.verificationUrl),
                          mode: LaunchMode.externalApplication,
                        ),
                      ),
                      GlassButton(
                        icon: Icons.close_rounded,
                        label: 'Annulla',
                        onPressed: () {
                          _poll?.cancel();
                          setState(() => _code = null);
                        },
                      ),
                    ],
                  ),
                ] else
                  Wrap(
                    spacing: 8,
                    children: [
                      GlassButton(
                        icon: Icons.link_rounded,
                        label: 'Collega $_name',
                        onPressed: _busy ? null : _connect,
                      ),
                      GlassButton(
                        icon: Icons.delete_outline_rounded,
                        label: 'Cambia le chiavi',
                        onPressed: () async {
                          final sv = ref.read(servicesProvider);
                          await sv.secrets.setServiceKey(
                            widget.trakt
                                ? ServiceKey.traktClient
                                : ServiceKey.simklClient,
                            null,
                          );
                          await sv.secrets.setServiceKey(
                            ServiceKey.traktSecret,
                            null,
                          );
                          await _refresh();
                        },
                      ),
                    ],
                  ),
              ] else ...[
                if (widget.trakt) ...const [
                  PrefSwitch(
                    'traktScrobble',
                    'Segna ciò che guardo (scrobble)',
                    _scrobble,
                  ),
                  PrefSwitch(
                    'traktSyncHistory',
                    'Porta qui i titoli già visti',
                    _history,
                  ),
                  PrefSwitch(
                    'traktSyncWatchlist',
                    'Sincronizza la watchlist',
                    _watchlist,
                  ),
                ] else
                  const PrefSwitch(
                    'simklSync',
                    'Segna i titoli finiti e la watchlist',
                    _simkl,
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    if (widget.trakt)
                      GlassButton(
                        icon: Icons.sync_rounded,
                        label: 'Sincronizza ora',
                        onPressed: _busy ? null : _syncNow,
                      ),
                    GlassButton(
                      icon: Icons.link_off_rounded,
                      label: 'Scollega',
                      onPressed: _disconnect,
                    ),
                  ],
                ),
              ],
              if (_message != null) ...[
                const SizedBox(height: 10),
                Text(_message!),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static bool _scrobble(AppSettings s) => s.traktScrobble;
  static bool _history(AppSettings s) => s.traktSyncHistory;
  static bool _watchlist(AppSettings s) => s.traktSyncWatchlist;
  static bool _simkl(AppSettings s) => s.simklSync;
}
