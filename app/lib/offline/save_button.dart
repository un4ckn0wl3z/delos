import 'package:flutter/material.dart';

import '../api.dart';
import 'store.dart';

/// "Save to this device" for whatever is playing: shows ⬇, progress, or ✓ (saved).
class SaveButton extends StatelessWidget {
  const SaveButton({super.key, required this.api, required this.path, required this.onSave, this.color, this.size = 24});
  final Api api;
  final String path; // server path of the file
  final Future<void> Function() onSave;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: OfflineStore.instance,
        builder: (context, _) {
          final it = OfflineStore.instance.byServer(api.settings.server, path);
          final messenger = ScaffoldMessenger.of(context);
          if (it == null || it.status == 'failed') {
            return IconButton(
              tooltip: it == null ? 'Save to this device' : 'Saving failed — try again',
              iconSize: size,
              icon: Icon(it == null ? Icons.download_for_offline_outlined : Icons.error_outline, color: it == null ? color : Colors.redAccent),
              onPressed: () async {
                if (it != null) await OfflineStore.instance.remove(it);
                await onSave();
                messenger.showSnackBar(const SnackBar(content: Text('Saving to this device — see Offline')));
              },
            );
          }
          if (!it.ready) {
            return IconButton(
              tooltip: 'Saving… ${(it.progress * 100).toStringAsFixed(0)}% — tap to cancel',
              iconSize: size,
              onPressed: () => OfflineStore.instance.remove(it),
              icon: SizedBox(
                width: size * .85,
                height: size * .85,
                child: CircularProgressIndicator(strokeWidth: 2.5, value: it.status == 'queued' ? null : it.progress, color: color),
              ),
            );
          }
          return IconButton(
            tooltip: 'Saved on this device',
            iconSize: size,
            icon: const Icon(Icons.offline_pin, color: Color(0xFF3ECF8E)),
            onPressed: () => messenger.showSnackBar(SnackBar(
              content: const Text('Saved on this device — plays without internet'),
              action: SnackBarAction(label: 'Remove', onPressed: () => OfflineStore.instance.remove(it)),
            )),
          );
        },
      );
}
