import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/debrid/torbox_client.dart';
import '../../core/metadata/fanart_client.dart';
import '../../data/prefs_ext.dart';
import '../../data/settings.dart';
import '../../data/stores.dart';
import '../../design/glass.dart';
import '../../design/tokens.dart';
import 'settings_extra.dart';
import 'settings_widgets.dart';

typedef VerifyResult = ({bool ok, String message});

/// Settings ▸ Servizi: every service of the viewer is a «tendina» with its key, a clearly visible check, and its own options.
class ServicesPage extends ConsumerWidget {
  const ServicesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return SettingsPageFrame(
      title: 'Servizi',
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 14),
          child: Text(
            'Le chiavi sono tue: restano nel portachiavi sicuro del telefono, non vanno nei log né nei backup (a meno che tu non lo chieda), e puoi rimuoverle quando vuoi.',
          ),
        ),
        SettingsGroup(
          title: 'Servizio debrid preferito',
          icon: Icons.bolt_rounded,
          footer: 'Se il servizio scelto non ha una chiave, Aether usa l’altro (se ce l’ha). Real-Debrid non permette di sapere in anticipo se un torrent è pronto: prima di aggiungerlo chiede conferma.',
          children: [
            ChoiceRow<String>(
              title: 'Servizio',
              value: s.debridProvider,
              options: const {'torbox': 'TorBox', 'realdebrid': 'Real-Debrid'},
              onChanged: (v) => n.update((x) => x.copyWith(debridProvider: v)),
            ),
          ],
        ),
        ServiceTile(
          title: 'TorBox',
          icon: Icons.cloud_download_rounded,
          description: 'Per riprodurre i torrent degli addon con la tua cache TorBox. Aether non cancella mai nulla dal tuo account e non avvia download senza chiederti conferma.',
          service: ServiceKey.torbox,
          verify: (ref) async {
            try {
              final plan = await ref.read(servicesProvider).torbox.check();
              return (ok: true, message: 'Connesso a TorBox ($plan).');
            } on DebridException catch (e) {
              return (ok: false, message: e.message);
            }
          },
        ),
        ServiceTile(
          title: 'Real-Debrid',
          icon: Icons.flash_on_rounded,
          description: 'Token personale dal tuo account Real-Debrid (Premium). Aether non cancella nulla e non aggiunge torrent senza chiederti conferma.',
          service: ServiceKey.realdebrid,
          verify: (ref) async {
            try {
              final plan = await ref.read(servicesProvider).realDebrid.check();
              return (ok: true, message: 'Connesso a Real-Debrid ($plan).');
            } on DebridException catch (e) {
              return (ok: false, message: e.message);
            }
          },
        ),
        ServiceTile(
          title: 'TMDB',
          icon: Icons.movie_filter_rounded,
          description: 'Cast con foto, filmografie, trailer e dettagli. Chiave v3 o token v4 dal tuo account TMDB.',
          service: ServiceKey.tmdb,
          verify: (ref) async {
            final r = await ref.read(servicesProvider).tmdb.check();
            return (ok: r == null, message: r ?? 'TMDB accetta la chiave.');
          },
          options: const [
            PrefSwitch('tmdbEnabled', 'Usa i dati di TMDB', _tmdb),
            PrefSwitch('modCast', 'Cast con foto', _cast),
            PrefSwitch('modCrew', 'Troupe (regia, scrittura, musiche)', _crew),
            PrefSwitch('modTrailers', 'Trailer', _trailers),
            PrefSwitch(
              'modFacts',
              'Dettagli (slogan, voto, durata, stato, date, lingue, paesi)',
              _facts,
            ),
            PrefSwitch('modCertification', 'Classificazione per età', _cert),
            PrefSwitch('modProviders', 'Dove guardarlo (piattaforme)', _prov),
            PrefSwitch('modCompanies', 'Produzione e reti', _companies),
            PrefSwitch('modFinancials', 'Incassi e budget', _fin),
            PrefSwitch('modCollection', 'Saga / collezione', _coll),
            PrefSwitch('modKeywords', 'Parole chiave', _kw),
            PrefSwitch('modSimilar', 'Simili e consigliati', _similar),
          ],
        ),
        ServiceTile(
          title: 'MDBList',
          icon: Icons.star_rate_rounded,
          description: 'Voti di IMDb, Rotten Tomatoes, Metacritic, Trakt e altri nella scheda del titolo. Chiave dal tuo account MDBList.',
          service: ServiceKey.mdblist,
          verify: (ref) async {
            final r = await ref.read(servicesProvider).mdblist.check();
            return (ok: r == null, message: r ?? 'MDBList accetta la chiave.');
          },
          options: [
            SwitchRow(
              title: 'Mostra i voti',
              value: s.showRatings,
              onChanged: (v) => n.update((x) => x.copyWith(showRatings: v)),
            ),
            const PrefSwitch(
              'posterRatings',
              'Voto sulle locandine',
              _posterRatings,
            ),
            for (final e in _ratings.entries)
              SwitchRow(
                title: e.value,
                value: s.ratingSources.contains(e.key),
                onChanged: (v) => n.update((x) {
                  final cur = [...x.ratingSources];
                  if (v) {
                    if (!cur.contains(e.key)) cur.add(e.key);
                  } else {
                    cur.remove(e.key);
                  }
                  return x.withExt('ratingSources', cur);
                }),
              ),
          ],
        ),
        ServiceTile(
          title: 'TheTVDB',
          icon: Icons.tv_rounded,
          description: 'Titoli e trame degli episodi nella tua lingua. Chiave di progetto TheTVDB v4 (e PIN, solo se la tua chiave è di un abbonato).',
          service: ServiceKey.tvdb,
          extraKey: (ServiceKey.tvdbPin, 'PIN (facoltativo)'),
          verify: (ref) async {
            final r = await ref.read(servicesProvider).tvdb.check();
            return (ok: r == null, message: r ?? 'TheTVDB accetta la chiave.');
          },
          options: [
            SwitchRow(
              title: 'Titoli degli episodi tradotti',
              value: s.tvdbEpisodes,
              onChanged: (v) => n.update((x) => x.copyWith(tvdbEpisodes: v)),
            ),
          ],
        ),
        ServiceTile(
          title: 'fanart.tv',
          icon: Icons.image_rounded,
          description: 'Logo trasparente del titolo mostrato dal player mentre prepara la sorgente. Chiave personale dal tuo account fanart.tv.',
          service: ServiceKey.fanart,
          verify: (ref) async {
            final url = await ref
                .read(servicesProvider)
                .fanart
                .logoUrl(FanartKind.movie, 'tt0111161', 'en');
            return url == null
                ? (
                    ok: false,
                    message: 'fanart.tv non ha risposto con un logo: controlla la chiave.',
                  )
                : (ok: true, message: 'fanart.tv accetta la chiave.');
          },
        ),
        SettingsGroup(
          title: 'IntroDB (nessuna chiave)',
          icon: Icons.fast_forward_rounded,
          footer: 'Dati di volontari per «Salta intro»: possono essere di pochi secondi fuori per un’altra versione dell’episodio.',
          children: [
            SwitchRow(
              title: 'Pulsante «Salta intro»',
              value: s.skipIntro,
              onChanged: (v) => n.update((x) => x.copyWith(skipIntro: v)),
            ),
          ],
        ),
      ],
    );
  }

  static bool _tmdb(AppSettings s) => s.tmdbEnabled;
  static bool _cast(AppSettings s) => s.modCast;
  static bool _crew(AppSettings s) => s.modCrew;
  static bool _trailers(AppSettings s) => s.modTrailers;
  static bool _facts(AppSettings s) => s.modFacts;
  static bool _cert(AppSettings s) => s.modCertification;
  static bool _prov(AppSettings s) => s.modProviders;
  static bool _companies(AppSettings s) => s.modCompanies;
  static bool _fin(AppSettings s) => s.modFinancials;
  static bool _coll(AppSettings s) => s.modCollection;
  static bool _kw(AppSettings s) => s.modKeywords;
  static bool _similar(AppSettings s) => s.modSimilar;
  static const _ratings = {
    'imdb': 'IMDb',
    'tmdb': 'TMDB',
    'tomatoes': 'Rotten Tomatoes (critica)',
    'tomatoesaudience': 'Rotten Tomatoes (pubblico)',
    'metacritic': 'Metacritic',
    'metacriticuser': 'Metacritic (utenti)',
    'trakt': 'Trakt',
    'letterboxd': 'Letterboxd',
    'rogerebert': 'Roger Ebert',
    'myanimelist': 'MyAnimeList',
  };
  static bool _posterRatings(AppSettings s) => s.posterRatings;
}

/// One service as a «tendina»: header with its state, then key, check and options.
class ServiceTile extends ConsumerStatefulWidget {
  const ServiceTile({
    super.key,
    required this.title,
    required this.icon,
    required this.description,
    required this.service,
    required this.verify,
    this.options = const [],
    this.extraKey,
  });
  final String title;
  final IconData icon;
  final String description;
  final ServiceKey service;
  final (ServiceKey, String)? extraKey;
  final Future<VerifyResult> Function(WidgetRef) verify;
  final List<Widget> options;

  @override
  ConsumerState<ServiceTile> createState() => _ServiceTileState();
}

class _ServiceTileState extends ConsumerState<ServiceTile> {
  final _c = TextEditingController();
  final _c2 = TextEditingController();
  bool _saved = false;
  bool _busy = false;
  VerifyResult? _result;

  @override
  void initState() {
    super.initState();
    ref.read(servicesProvider).secrets.serviceKey(widget.service).then((v) {
      if (mounted) setState(() => _saved = (v ?? '').isNotEmpty);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    _c2.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _result = null;
    });
    final r = await widget.verify(ref);
    if (mounted) {
      setState(() {
        _result = r;
        _busy = false;
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
    final secrets = ref.read(servicesProvider).secrets;
    final ok = _result?.ok;
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
                color:
                    (_saved ? AetherTokens.success : sectionColor(widget.title))
                        .withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                widget.icon,
                size: 19,
                color: _saved
                    ? AetherTokens.success
                    : sectionColor(widget.title),
              ),
            ),
            title: Text(
              widget.title,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
            subtitle: Text(
              _saved ? 'Chiave salvata' : 'Non configurato',
              style: TextStyle(
                fontSize: 12,
                color: _saved
                    ? AetherTokens.success
                    : AetherTokens.textTertiary,
              ),
            ),
            trailing: _saved
                ? const Icon(
                    Icons.check_circle_rounded,
                    color: AetherTokens.success,
                  )
                : null,
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.description,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (!_saved) ...[
                TextField(
                  controller: _c,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  onTapOutside: (_) => FocusScope.of(context).unfocus(),
                  decoration: _field('Incolla la chiave'),
                ),
                if (widget.extraKey != null) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _c2,
                    obscureText: true,
                    autocorrect: false,
                    onTapOutside: (_) => FocusScope.of(context).unfocus(),
                    decoration: _field(widget.extraKey!.$2),
                  ),
                ],
                const SizedBox(height: 10),
                _CheckButton(
                  label: 'Salva e verifica',
                  busy: _busy,
                  onPressed: () async {
                    if (_c.text.trim().isEmpty) return;
                    await secrets.setServiceKey(widget.service, _c.text);
                    if (widget.extraKey != null) {
                      await secrets.setServiceKey(
                        widget.extraKey!.$1,
                        _c2.text,
                      );
                    }
                    _c.clear();
                    _c2.clear();
                    setState(() => _saved = true);
                    await _verify();
                  },
                ),
              ] else
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _CheckButton(
                      label: 'Verifica',
                      busy: _busy,
                      onPressed: _verify,
                    ),
                    GlassButton(
                      label: 'Rimuovi la chiave',
                      icon: Icons.delete_outline_rounded,
                      onPressed: () async {
                        await secrets.setServiceKey(widget.service, null);
                        if (widget.extraKey != null) {
                          await secrets.setServiceKey(
                            widget.extraKey!.$1,
                            null,
                          );
                        }
                        setState(() {
                          _saved = false;
                          _result = null;
                        });
                      },
                    ),
                  ],
                ),
              if (_result != null)
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: (ok! ? AetherTokens.success : AetherTokens.danger)
                        .withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: (ok ? AetherTokens.success : AetherTokens.danger)
                          .withValues(alpha: 0.6),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        ok ? Icons.check_circle_rounded : Icons.error_rounded,
                        color: ok ? AetherTokens.success : AetherTokens.danger,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _result!.message,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              if (widget.options.isNotEmpty) ...[
                const SizedBox(height: 14),
                const Divider(height: 1),
                for (final o in widget.options) o,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The verify button: green with a check, so it reads as «controlla che funzioni».
class _CheckButton extends StatelessWidget {
  const _CheckButton({
    required this.label,
    required this.busy,
    required this.onPressed,
  });
  final String label;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    style: FilledButton.styleFrom(
      backgroundColor: AetherTokens.success,
      foregroundColor: Colors.black,
      shape: const StadiumBorder(),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
    ),
    onPressed: busy ? null : onPressed,
    icon: busy
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.black,
            ),
          )
        : const Icon(Icons.verified_rounded, size: 18),
    label: Text(
      busy ? 'Verifico…' : label,
      style: const TextStyle(fontWeight: FontWeight.w800),
    ),
  );
}
