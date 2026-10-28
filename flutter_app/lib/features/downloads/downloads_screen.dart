import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../design/glass.dart';
import 'downloads_view.dart';

/// The downloads as a page of its own (reached from «Altro»); the same list also lives in the Library, under «Download».
class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: AetherBackdrop(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  GlassButton(
                    icon: Icons.arrow_back_ios_new_rounded,
                    tooltip: 'Indietro',
                    onPressed: () => context.pop(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Download',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                  ),
                ],
              ),
            ),
            const Expanded(child: DownloadsBody()),
          ],
        ),
      ),
    ),
  );
}
