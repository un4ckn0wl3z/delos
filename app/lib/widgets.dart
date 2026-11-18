import 'package:flutter/material.dart';

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
    return Image.network(url, headers: headers, fit: fit, errorBuilder: (_, __, ___) => ph,
        frameBuilder: (_, child, frame, sync) => frame == null && !sync ? ph : child);
  }
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
    required this.onTap,
  });
  final String title, subtitle, image, badge;
  final Map<String, String>? headers;
  final double aspect, progress;
  final bool round;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
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
      ]),
    );
  }
}

/// Responsive grid of cards.
class CardGrid extends StatelessWidget {
  const CardGrid({super.key, required this.children, this.minWidth = 140, this.aspect = 2 / 3});
  final List<Widget> children;
  final double minWidth, aspect;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final cols = (box.maxWidth / (minWidth + 14)).floor().clamp(2, 10);
        final w = (box.maxWidth - 32 - (cols - 1) * 14) / cols;
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            crossAxisSpacing: 14,
            mainAxisSpacing: 16,
            mainAxisExtent: w / aspect + 54,
          ),
          itemCount: children.length,
          itemBuilder: (_, i) => children[i],
        );
      });
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
