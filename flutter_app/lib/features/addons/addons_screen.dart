import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../core/addons/addon_client.dart';
import '../../core/addons/addon_repository.dart';
import '../../core/addons/network_policy.dart';
import '../../design/glass.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';

class AddonsScreen extends ConsumerWidget {
  const AddonsScreen({super.key, this.installUrl});

  /// An address that arrived from a `stremio://` or `aether://` link: the preview opens at once, the viewer still confirms.
  final String? installUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final addons = ref.watch(addonsProvider);
    final notifier = ref.read(addonsProvider.notifier);
    return Scaffold(
      body: AetherBackdrop(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              if (installUrl != null)
                _OnceCallback(() => _add(context, ref, initial: installUrl)),
              Row(
                children: [
                  GlassButton(
                    icon: Icons.arrow_back_ios_new_rounded,
                    tooltip: 'Indietro',
                    onPressed: () => context.pop(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Addon',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                  ),
                  GlassButton(
                    icon: Icons.add_rounded,
                    label: 'Aggiungi',
                    prominent: true,
                    onPressed: () => _add(context, ref),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Gli addon sono di terze parti: Aether non li controlla. Quelli più in alto hanno la priorità.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (addons.isEmpty)
                const EmptyState(
                  icon: Icons.extension_off_rounded,
                  title: 'Nessun addon',
                  message: 'Aggiungine uno con il link del suo manifest.',
                ),
              for (var i = 0; i < addons.length; i++)
                _AddonCard(
                  addon: addons[i],
                  first: i == 0,
                  last: i == addons.length - 1,
                  notifier: notifier,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _add(
    BuildContext context,
    WidgetRef ref, {
    String? initial,
  }) async {
    final controller = TextEditingController(text: initial);
    final preview = await showDialog<AddonPreview>(
      context: context,
      builder: (c) => _AddDialog(controller: controller, ref: ref),
    );
    controller.dispose();
    if (preview == null || !context.mounted) return;
    await ref.read(addonsProvider.notifier).install(preview);
    if (context.mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Installato: ${preview.manifest.name}')),
      );
  }
}

class _AddDialog extends StatefulWidget {
  const _AddDialog({required this.controller, required this.ref});
  final TextEditingController controller;
  final WidgetRef ref;

  @override
  State<_AddDialog> createState() => _AddDialogState();
}

class _AddDialogState extends State<_AddDialog> {
  @override
  void initState() {
    super.initState();
    if (widget.controller.text.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    }
  }

  bool _busy = false;
  String? _error;
  AddonPreview? _preview;

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _error = null;
      _preview = null;
    });
    try {
      _preview = await widget.ref
          .read(addonsProvider.notifier)
          .preview(widget.controller.text);
    } on AddonException catch (e) {
      _error = e.message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _preview;
    return AlertDialog(
      title: const Text('Aggiungi un addon'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: widget.controller,
              keyboardType: TextInputType.url,
              autocorrect: false,
              maxLines: 3,
              minLines: 1,
              decoration: InputDecoration(
                hintText: 'https://…/manifest.json oppure stremio://…',
                suffixIcon: IconButton(
                  tooltip: 'Incolla',
                  icon: const Icon(Icons.paste_rounded),
                  onPressed: () async {
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    if (data?.text != null)
                      setState(
                        () => widget.controller.text = data!.text!.trim(),
                      );
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Text(
                _error!,
                style: const TextStyle(color: AetherTokens.warning),
              ),
            if (p != null) ...[
              Text(
                '${p.manifest.name} · ${p.manifest.version}',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              if (p.manifest.description != null)
                Text(
                  p.manifest.description!,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              const SizedBox(height: 6),
              Text(
                'Offre: ${p.manifest.resources.map((r) => r.name).join(', ')} · ${p.manifest.catalogs.length} cataloghi',
                style: const TextStyle(fontSize: 12),
              ),
              for (final w in p.warnings)
                Text(
                  '• $w',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AetherTokens.warning,
                  ),
                ),
              if (p.alreadyInstalled)
                const Text('Già installato.', style: TextStyle(fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annulla'),
        ),
        if (p == null || p.alreadyInstalled)
          TextButton(
            onPressed: _busy ? null : _check,
            child: const Text('Controlla'),
          )
        else
          FilledButton(
            onPressed: () => Navigator.pop(context, p),
            child: const Text('Installa'),
          ),
      ],
    );
  }
}

class _AddonCard extends StatefulWidget {
  const _AddonCard({
    required this.addon,
    required this.first,
    required this.last,
    required this.notifier,
  });
  final InstalledAddon addon;
  final bool first;
  final bool last;
  final AddonsNotifier notifier;

  @override
  State<_AddonCard> createState() => _AddonCardState();
}

class _AddonCardState extends State<_AddonCard> {
  bool _open = false;
  bool _busy = false;
  String? _message;

  @override
  Widget build(BuildContext context) {
    final a = widget.addon;
    final n = widget.notifier;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassSurface(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 44,
                  height: 44,
                  child: PosterImage(
                    url: a.manifest.logo,
                    title: a.displayName,
                    radius: 12,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        a.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        '${a.manifest.version} · ${a.manifest.resources.map((r) => r.name).join(', ')}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: a.enabled,
                  onChanged: (v) => n.setEnabled(a.id, v),
                ),
                IconButton(
                  tooltip: _open ? 'Comprimi' : 'Dettagli',
                  icon: Icon(
                    _open
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                  ),
                  onPressed: () => setState(() => _open = !_open),
                ),
              ],
            ),
            if (_open) ...[
              const Divider(height: 24),
              if (a.manifest.description != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    a.manifest.description!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  GlassButton(
                    icon: Icons.arrow_upward_rounded,
                    tooltip: 'Più priorità',
                    size: 40,
                    onPressed: widget.first ? null : () => n.move(a.id, -1),
                  ),
                  GlassButton(
                    icon: Icons.arrow_downward_rounded,
                    tooltip: 'Meno priorità',
                    size: 40,
                    onPressed: widget.last ? null : () => n.move(a.id, 1),
                  ),
                  GlassButton(
                    icon: Icons.edit_rounded,
                    label: 'Rinomina',
                    size: 40,
                    onPressed: () => _rename(context),
                  ),
                  GlassButton(
                    icon: Icons.refresh_rounded,
                    label: _busy ? '…' : 'Aggiorna',
                    size: 40,
                    onPressed: _busy
                        ? null
                        : () async {
                            setState(() {
                              _busy = true;
                              _message = null;
                            });
                            try {
                              await n.refresh(a.id);
                              _message = 'Manifest aggiornato.';
                            } on AddonException catch (e) {
                              _message = e.message;
                            } finally {
                              if (mounted) setState(() => _busy = false);
                            }
                          },
                  ),
                  if (a.manifest.behaviorHints.configurable)
                    GlassButton(
                      icon: Icons.tune_rounded,
                      label: 'Configura',
                      size: 40,
                      onPressed: () => launchUrl(
                        AddonUrl.configure(a.base),
                        mode: LaunchMode.externalApplication,
                      ),
                    ),
                  GlassButton(
                    icon: Icons.delete_outline_rounded,
                    label: 'Rimuovi',
                    size: 40,
                    onPressed: () => _remove(context),
                  ),
                ],
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _message!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (a.manifest.catalogs.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  'Cataloghi',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                for (final c in a.manifest.catalogs)
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(c.name),
                    subtitle: Text(
                      '${c.type}${c.isSearchable ? ' · ricerca' : ''}',
                    ),
                    value: a.isCatalogVisible(c),
                    onChanged: (v) => n.setCatalogVisible(a.id, c, v),
                  ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context) async {
    final c = TextEditingController(
      text: widget.addon.nameOverride ?? widget.addon.manifest.name,
    );
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Rinomina l’addon'),
        content: TextField(controller: c, maxLength: 40),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, ''),
            child: const Text('Nome originale'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, c.text),
            child: const Text('Salva'),
          ),
        ],
      ),
    );
    c.dispose();
    if (name != null) await widget.notifier.rename(widget.addon.id, name);
  }

  Future<void> _remove(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Rimuovere ${widget.addon.displayName}?'),
        content: const Text(
          'L’addon non viene più contattato. La tua libreria resta.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Annulla'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Rimuovi'),
          ),
        ],
      ),
    );
    if (ok == true) await widget.notifier.remove(widget.addon.id);
  }
}

/// Runs [run] once, after the first frame (used to open the install preview for a link).
class _OnceCallback extends StatefulWidget {
  const _OnceCallback(this.run);
  final VoidCallback run;

  @override
  State<_OnceCallback> createState() => _OnceCallbackState();
}

class _OnceCallbackState extends State<_OnceCallback> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.run());
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
