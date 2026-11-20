import 'package:flutter/material.dart';

import '../social.dart';
import '../widgets.dart';
import 'chat.dart';
import 'home_screen.dart';

/// Little emoji row for ranking badges (tooltip = name and how it was earned).
class BadgeIcons extends StatelessWidget {
  const BadgeIcons(this.badges, {super.key, this.max = 99, this.size = 13});
  final List<Map> badges;
  final int max;
  final double size;
  @override
  Widget build(BuildContext context) => badges.isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(left: 5),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (final b in badges.take(max))
              Tooltip(message: '${b['name']} — ${b['desc']}', child: Text('${b['icon']}', style: TextStyle(fontSize: size))),
          ]),
        );
}

String fmtHours(num sec) => sec >= 3600 ? '${(sec / 3600).toStringAsFixed(sec >= 36000 ? 0 : 1)} h' : '${(sec / 60).round().clamp(1, 59)} min';

class RankingScreen extends StatefulWidget {
  const RankingScreen({super.key, required this.app});
  final AppCtx app;
  @override
  State<RankingScreen> createState() => _RankingScreenState();
}

class _RankingScreenState extends State<RankingScreen> {
  static const _periods = {'week': 'This week', 'month': 'This month', 'year': 'This year', 'all': 'All time'};
  String period = 'month';
  Map? r;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final v = await widget.app.api.ranking(period);
      if (mounted) {
        setState(() {
          r = v;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Widget _board(Social? s, List rows, bool video) {
    if (rows.isEmpty) {
      return const Padding(padding: EdgeInsets.fromLTRB(16, 4, 16, 12), child: Text('Nobody yet — press play!', style: TextStyle(color: Color(0xFF8B95A5))));
    }
    final top = ((video ? rows.first['video'] : rows.first['music']) as num? ?? 1).toDouble();
    final me = widget.app.api.settings.username;
    final badges = Map.from(r?['badges'] as Map? ?? const {});
    return Column(children: [
      for (var i = 0; i < rows.length; i++)
        Builder(builder: (context) {
          final x = rows[i] as Map;
          final v = ((video ? x['video'] : x['music']) as num? ?? 0).toDouble();
          final name = '${x['user']}';
          return ListTile(
            selected: name == me,
            leading: SizedBox(
              width: 70,
              child: Row(children: [
                SizedBox(
                    width: 28,
                    child: Text(i < 3 ? ['🥇', '🥈', '🥉'][i] : '${i + 1}',
                        textAlign: TextAlign.center, style: TextStyle(fontSize: i < 3 ? 20 : 14, fontWeight: FontWeight.w600, color: const Color(0xFF8B95A5)))),
                const SizedBox(width: 6),
                if (s != null) UserAvatar(s, name, radius: 17) else CircleAvatar(radius: 17, child: Text(name.isEmpty ? '?' : name[0].toUpperCase())),
              ]),
            ),
            title: Row(children: [
              Flexible(child: Text(name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
              BadgeIcons(List<Map>.from(badges[name] as List? ?? const [])),
            ]),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(value: top > 0 ? (v / top).clamp(0.0, 1.0) : 0, minHeight: 5)),
            ),
            trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(fmtHours(v), style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(video ? '${x['titles'] ?? 0} finished' : '${x['songs'] ?? 0} songs', style: const TextStyle(fontSize: 12, color: Color(0xFF8B95A5))),
            ]),
          );
        }),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.app.social;
    final me = widget.app.api.settings.username;
    final mine = List<Map>.from(((r?['badges'] as Map?)?[me] as List?) ?? const []);
    final my = Map.from(r?['me'] as Map? ?? const {});
    return Scaffold(
      appBar: AppBar(title: const Text('🏆 Ranking')),
      body: r == null
          ? Center(child: error != null ? Padding(padding: const EdgeInsets.all(24), child: Text(error!)) : const CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Wrap(spacing: 8, runSpacing: 6, children: [
                    for (final e in _periods.entries)
                      ChoiceChip(
                        label: Text(e.value),
                        selected: period == e.key,
                        onSelected: (_) {
                          setState(() => period = e.key);
                          _load();
                        },
                      ),
                  ]),
                ),
                const SectionTitle('🎬 Watched the most'),
                _board(s, r!['video'] as List? ?? const [], true),
                const SectionTitle('🎵 Listened the most'),
                _board(s, r!['music'] as List? ?? const [], false),
                const SectionTitle('Your badges'),
                if (r!['hidden'] == true)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text('You hide what you watch, so you are not on the ranking and get no badges. Change it in Settings.', style: TextStyle(color: Color(0xFF8B95A5))),
                  )
                else ...[
                  if (mine.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Text('No badges yet — watch or listen for an hour to get your first.', style: TextStyle(color: Color(0xFF8B95A5))),
                    ),
                  for (final b in mine)
                    ListTile(
                      leading: Text('${b['icon']}', style: const TextStyle(fontSize: 26)),
                      title: Text('${b['name']}'),
                      subtitle: Text('${b['desc']}'),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      '${_periods[r!['period']] ?? ''}: 🎬 ${fmtHours(my['video'] as num? ?? 0)} · ${my['titles'] ?? 0} finished · 🎵 ${fmtHours(my['music'] as num? ?? 0)} · ${my['songs'] ?? 0} songs'
                      '${(r!['streak'] as num? ?? 0) > 0 ? ' · 🔥 ${r!['streak']}-day streak' : ''}',
                      style: const TextStyle(fontSize: 12.5, color: Color(0xFF9AA3B2)),
                    ),
                  ),
                ],
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 18, 16, 0),
                  child: Text(
                    'Time counts while something is actually playing. A movie or episode counts as finished at 90 %. '
                    'Badges come from all-time totals (1 / 10 / 50 / 200 / 1000 hours), 25 and 100 finished titles, 1000 songs, '
                    '7+ days in a row, and the most watched / listened this month. People who hide their activity aren\'t ranked.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF7D8696)),
                  ),
                ),
              ]),
            ),
    );
  }
}
