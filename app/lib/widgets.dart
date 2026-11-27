import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "📄 File names": the original file name under every title, to check what TMDB / the tags matched.
class RawNames {
  static final on = ValueNotifier<bool>(false);
  static Future<void> init() async {
    try {
      on.value = (await SharedPreferences.getInstance()).getBool('rawNames') ?? false;
    } catch (_) {}
  }

  static Future<void> toggle() async {
    on.value = !on.value;
    try {
      await (await SharedPreferences.getInstance()).setBool('rawNames', on.value);
    } catch (_) {}
  }

  static String tmdb(int id) => id > 0 ? 'TMDB #$id' : 'not matched on TMDB';
}

class RawNamesButton extends StatelessWidget {
  const RawNamesButton({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: RawNames.on,
        builder: (context, on, _) => IconButton(
          tooltip: on ? 'Hide file names' : 'Show the original file names (and the TMDB match)',
          isSelected: on,
          icon: const Icon(Icons.description_outlined),
          selectedIcon: Icon(Icons.description, color: Theme.of(context).colorScheme.primary),
          onPressed: RawNames.toggle,
        ),
      );
}

/// Small monospace file name(s), only while "File names" is on.
class RawText extends StatelessWidget {
  const RawText(this.text, {super.key, this.maxLines = 3});
  final String text;
  final int maxLines;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: RawNames.on,
        builder: (context, on, _) => on && text.isNotEmpty
            ? Text(text, maxLines: maxLines, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, fontFamily: 'monospace', color: Color(0xFF7D8696), height: 1.3))
            : const SizedBox.shrink(),
      );
}

/// "first.name.mkv +2 more"
String rawOf(Iterable<String> names, [String extra = '']) {
  final l = names.toSet().toList();
  final s = l.isEmpty ? '' : '${l.first}${l.length > 1 ? ' +${l.length - 1} more' : ''}';
  return extra.isEmpty ? s : '$s\n$extra';
}

/// Network image with optional auth headers and a text placeholder.
class NetImage extends StatelessWidget {
  const NetImage(this.url, {super.key, this.headers, this.placeholder = '', this.fit = BoxFit.cover});
  final String url;
  final Map<String, String>? headers;
  final String placeholder;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final ph = Container(
      color: const Color(0xFF1A2029),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(8),
      child: Text(placeholder,
          textAlign: TextAlign.center, maxLines: 4, overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Color(0xFF8B95A5), fontSize: 12)),
    );
    if (url.isEmpty) return ph;
    if (!url.startsWith('http')) {
      // artwork cached on this device (offline library)
      return Image.file(File(url), fit: fit, errorBuilder: (_, __, ___) => ph);
    }
    return Image.network(url, headers: headers, fit: fit, errorBuilder: (_, __, ___) => ph,
        frameBuilder: (_, child, frame, sync) => frame == null && !sync ? ph : child);
  }
}

/// Where a video plays from: green LOCAL (this device) or blue STREAM (server).
class SourceBadge extends StatelessWidget {
  const SourceBadge({super.key, required this.local, required this.text});
  final bool local;
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: (local ? const Color(0xFF1F9D63) : const Color(0xFF2B6FD6)).withValues(alpha: .9),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(local ? Icons.offline_pin : Icons.cloud_outlined, size: 13, color: Colors.white),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: .3)),
        ]),
      );
}

class ProgressStrip extends StatelessWidget {
  const ProgressStrip(this.value, {super.key});
  final double value;
  @override
  Widget build(BuildContext context) => value <= 0
      ? const SizedBox.shrink()
      : Align(
          alignment: Alignment.bottomCenter,
          child: LinearProgressIndicator(value: value, minHeight: 4, backgroundColor: Colors.black45),
        );
}

/// Poster (2:3), square (album) or wide (16:9) card with title and subtitle.
class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.title,
    this.subtitle = '',
    this.image = '',
    this.headers,
    this.aspect = 2 / 3,
    this.progress = 0,
    this.badge = '',
    this.round = false,
    this.raw = '',
    required this.onTap,
    this.onLongPress,
  });
  final String title, subtitle, image, badge;
  /// original file name(s), shown while "File names" is on
  final String raw;
  final Map<String, String>? headers;
  final double aspect, progress;
  final bool round;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress, // right-click on desktop
      borderRadius: BorderRadius.circular(8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        AspectRatio(
          aspectRatio: aspect,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(round ? 999 : 8),
            child: Stack(fit: StackFit.expand, children: [
              NetImage(image, headers: headers, placeholder: title),
              ProgressStrip(progress),
              if (badge.isNotEmpty)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(6)),
                    child: Text(badge, style: const TextStyle(fontSize: 11, color: Colors.white)),
                  ),
                ),
            ]),
          ),
        ),
        const SizedBox(height: 6),
        Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, height: 1.25)),
        if (subtitle.isNotEmpty)
          Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Color(0xFF7D8696))),
        if (raw.isNotEmpty) RawText(raw, maxLines: 2),
      ]),
    );
  }
}

/// Responsive grid of cards.
class CardGrid extends StatelessWidget {
  const CardGrid({super.key, required this.children, this.minWidth = 140, this.aspect = 2 / 3, this.shrink = false});
  final List<Widget> children;
  final double minWidth, aspect;
  /// Inside another scroll view (sized to its content, not scrollable itself).
  final bool shrink;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
      valueListenable: RawNames.on,
      builder: (context, raw, _) => LayoutBuilder(builder: (context, box) {
        final cols = (box.maxWidth / (minWidth + 14)).floor().clamp(2, 10);
        final w = (box.maxWidth - 32 - (cols - 1) * 14) / cols;
        return GridView.builder(
          shrinkWrap: shrink,
          physics: shrink ? const NeverScrollableScrollPhysics() : null,
          padding: EdgeInsets.fromLTRB(16, 12, 16, shrink ? 16 : 96),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            crossAxisSpacing: 14,
            mainAxisSpacing: 16,
            mainAxisExtent: w / aspect + 54 + (raw ? 28 : 0), // room for two lines of file name
          ),
          itemCount: children.length,
          itemBuilder: (_, i) => children[i],
        );
      }));
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.onMore});
  final String text;
  final VoidCallback? onMore;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 8, 8),
        child: Row(children: [
          Expanded(child: Text(text, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600))),
          if (onMore != null) TextButton(onPressed: onMore, child: const Text('See all')),
        ]),
      );
}

class HRow extends StatelessWidget {
  const HRow({super.key, required this.children, this.itemWidth = 130, this.aspect = 2 / 3});
  final List<Widget> children;
  final double itemWidth, aspect;
  @override
  Widget build(BuildContext context) => SizedBox(
        height: itemWidth / aspect + 56,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: children.length,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (_, i) => SizedBox(width: itemWidth, child: children[i]),
        ),
      );
}

class Chips extends StatelessWidget {
  const Chips(this.labels, {super.key, this.onTap});
  final List<String> labels;
  final void Function(String)? onTap;
  @override
  Widget build(BuildContext context) => Wrap(spacing: 6, runSpacing: 6, children: [
        for (final g in labels)
          ActionChip(
            label: Text(g, style: const TextStyle(fontSize: 12)),
            visualDensity: VisualDensity.compact,
            onPressed: onTap == null ? null : () => onTap!(g),
          ),
      ]);
}

String fmtDur(double secs) {
  final t = secs.isNaN || secs < 0 ? 0 : secs.floor();
  final h = t ~/ 3600, m = (t % 3600) ~/ 60, s = t % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}


enum RolePillKind { role, guest, admin }

/// "🏷 Family" / "Guest" / "Admin": the user's role (it decides which libraries they see).
class RolePill extends StatelessWidget {
  const RolePill(this.name, {super.key, this.kind = RolePillKind.role});
  final String name;
  final RolePillKind kind;
  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (kind) {
      RolePillKind.admin => (const Color(0xFF4A3A1C), const Color(0xFFFFCF7A)),
      RolePillKind.guest => (const Color(0x17FFFFFF), const Color(0xFFAAB3C0)),
      RolePillKind.role => (const Color(0x2EA078FF), const Color(0xFFCDB6FF)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
      child: Text(kind == RolePillKind.role ? '🏷 $name' : name, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
    );
  }
}
