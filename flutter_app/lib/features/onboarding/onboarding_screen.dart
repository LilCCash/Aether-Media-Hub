import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/addons/addon_client.dart';
import '../../core/addons/addon_repository.dart';
import '../../design/glass.dart';
import '../../design/tokens.dart';

const cinemetaUrl = 'https://v3-cinemeta.strem.io/manifest.json';

/// First launch: what Aether is (and is not), the first addon, done. Every step can be skipped.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _page = PageController();
  final _url = TextEditingController(text: cinemetaUrl);
  int _index = 0;
  bool _busy = false;
  String? _error;
  AddonPreview? _preview;

  Future<void> _finish() async {
    await ref
        .read(settingsProvider.notifier)
        .update((s) => s.copyWith(onboardingDone: true));
    if (mounted) context.go('/home');
  }

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _error = null;
      _preview = null;
    });
    try {
      final p = await ref.read(addonsProvider.notifier).preview(_url.text);
      setState(() => _preview = p);
    } on AddonException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _install() async {
    await ref.read(addonsProvider.notifier).install(_preview!);
    _next();
  }

  void _next() =>
      _page.nextPage(duration: AetherTokens.medium, curve: AetherTokens.ease);

  @override
  void dispose() {
    _page.dispose();
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AetherBackdrop(
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: TextButton(
                    onPressed: _finish,
                    child: const Text('Salta'),
                  ),
                ),
              ),
              Expanded(
                child: PageView(
                  controller: _page,
                  physics: const NeverScrollableScrollPhysics(),
                  onPageChanged: (i) => setState(() => _index = i),
                  children: [
                    _Step(
                      icon: Icons.blur_on_rounded,
                      title: 'Benvenuto in Aether',
                      body: 'Un media hub per i tuoi addon Stremio. Aether non fornisce nessun contenuto: sei tu a scegliere e installare gli addon, e a risponderne.',
                      action: GlassButton(
                        label: 'Inizia',
                        prominent: true,
                        onPressed: _next,
                      ),
                    ),
                    _Step(
                      icon: Icons.extension_rounded,
                      title: 'Il tuo primo addon',
                      body: 'Incolla il link di un addon. Come punto di partenza ti proponiamo Cinemeta, il catalogo ufficiale di Stremio (solo cataloghi e schede, nessun video).',
                      action: Column(
                        children: [
                          GlassSurface(
                            radius: 18,
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            child: TextField(
                              controller: _url,
                              keyboardType: TextInputType.url,
                              autocorrect: false,
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                hintText: 'https://…/manifest.json',
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          if (_busy) const CircularProgressIndicator(),
                          if (_error != null)
                            Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: AetherTokens.warning,
                              ),
                            ),
                          if (_preview != null) ...[
                            Text(
                              '${_preview!.manifest.name} ${_preview!.manifest.version}',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            for (final w in _preview!.warnings)
                              Text(
                                '• $w',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AetherTokens.warning,
                                ),
                              ),
                            const SizedBox(height: 10),
                            GlassButton(
                              label: 'Installa',
                              icon: Icons.download_done_rounded,
                              prominent: true,
                              onPressed: _install,
                            ),
                          ] else if (!_busy)
                            GlassButton(
                              label: 'Controlla l’addon',
                              icon: Icons.search_rounded,
                              prominent: true,
                              onPressed: _check,
                            ),
                        ],
                      ),
                    ),
                    _Step(
                      icon: Icons.check_circle_rounded,
                      title: 'Tutto pronto',
                      body: 'Altri addon, le chiavi TorBox e TMDB e l’aspetto si trovano in Altro ▸ Impostazioni. Il player di prova (anche senza internet) è in Altro ▸ Diagnostica.',
                      action: GlassButton(
                        label: 'Apri Aether',
                        prominent: true,
                        onPressed: _finish,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < 3; i++)
                      AnimatedContainer(
                        duration: AetherTokens.medium,
                        margin: const EdgeInsets.all(3),
                        width: i == _index ? 20 : 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(
                            alpha: i == _index ? 0.9 : 0.3,
                          ),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.icon,
    required this.title,
    required this.body,
    required this.action,
  });
  final IconData icon;
  final String title;
  final String body;
  final Widget action;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GlassSurface(
              radius: 36,
              padding: const EdgeInsets.all(22),
              child: icon == Icons.blur_on_rounded
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: Image.asset(
                        'assets/brand/icon.png',
                        width: 88,
                        height: 88,
                        semanticLabel: 'Logo di Aether',
                      ),
                    )
                  : Icon(icon, size: 52, color: AetherLook.of(context).accent),
            ),
            const SizedBox(height: 26),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.displaySmall,
            ),
            const SizedBox(height: 12),
            Text(
              body,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge
                  ?.copyWith(color: AetherTokens.textSecondary),
            ),
            const SizedBox(height: 28),
            action,
          ],
        ),
      ),
    ),
  );
}
