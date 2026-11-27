import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'screens/home_screen.dart';

/// A "Trailer" button for a film or a series: opens the trailer in the YouTube
/// app (or the browser). With several trailers, a list to pick from.
/// Shows nothing when the title has none or the admin turned trailers off.
class TrailerButton extends StatefulWidget {
  const TrailerButton({super.key, required this.app, required this.lib, this.movie, this.show});
  final AppCtx app;
  final String lib;
  final String? movie, show;
  @override
  State<TrailerButton> createState() => _TrailerButtonState();
}

final _cache = <String, List<Map>>{};

class _TrailerButtonState extends State<TrailerButton> {
  List<Map>? list;

  String get _key => '${widget.lib}|${widget.movie}|${widget.show}';

  @override
  void initState() {
    super.initState();
    list = _cache[_key];
    if (list == null && widget.app.features['trailers'] != false && widget.lib != '_legacy') _load();
  }

  Future<void> _load() async {
    try {
      final l = await widget.app.api.trailers(widget.lib, movie: widget.movie, show: widget.show);
      _cache[_key] = l;
      if (mounted) setState(() => list = l);
    } catch (_) {
      // no trailers (offline, turned off, older server)
    }
  }

  Future<void> _open(Map t) async {
    final ok = await launchUrl(Uri.parse('https://www.youtube.com/watch?v=${Uri.encodeComponent('${t['key']}')}'), mode: LaunchMode.externalApplication);
    if (!ok && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't open YouTube")));
  }

  void _pick() {
    final l = list!;
    if (l.length == 1) {
      _open(l.first);
      return;
    }
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('Trailers', style: TextStyle(fontWeight: FontWeight.w600))),
          for (final t in l)
            ListTile(
              leading: const Icon(Icons.smart_display_outlined),
              title: Text('${t['name']}'),
              subtitle: Text([t['type'], if ('${t['lang'] ?? ''}'.isNotEmpty) '${t['lang']}'.toUpperCase(), if (t['official'] == true) 'Official'].join(' · ')),
              onTap: () {
                Navigator.pop(ctx);
                _open(t);
              },
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = list;
    if (l == null || l.isEmpty || widget.app.features['trailers'] == false) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: OutlinedButton.icon(
        icon: const Icon(Icons.movie_filter_outlined, size: 18),
        label: Text(l.length > 1 ? 'Trailer · ${l.length}' : 'Trailer'),
        onPressed: _pick,
      ),
    );
  }
}
