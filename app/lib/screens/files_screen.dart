import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../util.dart';
import 'login_screen.dart';
import 'player_screen.dart';
import 'settings_screen.dart';
import '../update.dart';

class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key, required this.api});
  final Api api;

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  List<MediaFile> _files = [];
  bool _loading = true;
  ApiException? _error;
  bool _searching = false;
  final _search = TextEditingController();

  static bool _updateChecked = false;

  @override
  void initState() {
    super.initState();
    _load();
    if (!_updateChecked) {
      _updateChecked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => checkForUpdate(context, widget.api.settings));
    }
  }

  Future<void> _load() async {
    setState(() => _loading = _files.isEmpty);
    try {
      final files = await widget.api.list();
      if (!mounted) return;
      setState(() {
        _files = files;
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(MediaFile f) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlayerScreen(api: widget.api, file: f)));
    _load();
  }

  void _signOut() async {
    await widget.api.settings.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => LoginScreen(settings: widget.api.settings)),
      (_) => false,
    );
  }

  List<Widget> _items() {
    final words = _search.text.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final files = _files.where((f) => words.every((w) => f.path.toLowerCase().contains(w))).toList();
    final out = <Widget>[];
    final inProgress = files.where((f) => f.pos > 0).toList();
    if (inProgress.isNotEmpty && words.isEmpty) {
      out.add(_header('Continue watching'));
      out.addAll(inProgress.map(_tile));
    }
    String? lastDir;
    for (final f in files) {
      if (f.dir != lastDir) {
        lastDir = f.dir;
        out.add(_header(f.dir.isEmpty ? '/' : f.dir));
      }
      out.add(_tile(f));
    }
    if (files.isEmpty) {
      out.add(const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No files'))));
    }
    return out;
  }

  Widget _header(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
        child: Text(t.toUpperCase(),
            style: const TextStyle(fontSize: 11, letterSpacing: .6, color: Color(0xFF7D8696))),
      );

  Widget _tile(MediaFile f) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      onTap: () => _open(f),
      leading: Icon(f.pos > 0 ? Icons.play_circle_fill_rounded : Icons.movie_outlined,
          color: f.pos > 0 ? cs.primary : null),
      title: Text(f.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(f.pos > 0 ? '${fmtSize(f.size)} · ${fmtTime(f.pos)} / ${fmtTime(f.duration)}' : fmtSize(f.size)),
          if (f.pos > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: LinearProgressIndicator(value: f.progress, minHeight: 3, borderRadius: BorderRadius.circular(2)),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _search,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Search…', border: InputBorder.none),
                onChanged: (_) => setState(() {}),
              )
            : const Text('StreamMKV'),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            onPressed: () => setState(() {
              _searching = !_searching;
              if (!_searching) _search.clear();
            }),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () async {
              final signOut = await Navigator.of(context)
                  .push<bool>(MaterialPageRoute(builder: (_) => SettingsScreen(api: widget.api)));
              if (signOut == true) _signOut();
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _files.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_error!.message, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      Wrap(spacing: 12, children: [
                        FilledButton(onPressed: _load, child: const Text('Retry')),
                        if (_error!.unauthorized)
                          OutlinedButton(onPressed: _signOut, child: const Text('Sign in again')),
                      ]),
                    ]),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 24),
                    children: _items(),
                  ),
                ),
    );
  }
}
