import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../offline/offline_home.dart';
import '../settings.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.settings});
  final Settings settings;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final _server = TextEditingController(text: widget.settings.server);
  late final _user = TextEditingController(text: widget.settings.username);
  final _pass = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    final s = widget.settings;
    if (_server.text.trim().isEmpty || _user.text.trim().isEmpty) {
      setState(() => _error = 'Enter the server URL and username');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    s.server = _server.text;
    s.username = _user.text.trim();
    s.password = _pass.text;
    s.token = null;
    final api = Api(s);
    try {
      await api.login();
      s.offlineMode = false;
      // let the system password manager offer to save the login (Google, Samsung Pass, iCloud…)
      TextInput.finishAutofillContext();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => HomeScreen(api: api)));
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.movie_filter_rounded, size: 56, color: Color(0xFF4A9EFF)),
                    const SizedBox(height: 12),
                    Text('StreamMKV', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 28),
                    TextField(
                      controller: _server,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      autofillHints: const [AutofillHints.url],
                      decoration: const InputDecoration(
                        labelText: 'Server URL',
                        hintText: 'http://seedbox.example.com:8090/',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _user,
                      autocorrect: false,
                      autofillHints: const [AutofillHints.username],
                      decoration: const InputDecoration(labelText: 'Username', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _pass,
                      obscureText: true,
                      autofillHints: const [AutofillHints.password],
                      onSubmitted: (_) => _submit(),
                      decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 22,
                      child: _error == null
                          ? null
                          : Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: _busy
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Text('Sign in'),
                      ),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () {
                              widget.settings.offlineMode = true;
                              Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => OfflineHome(settings: widget.settings)));
                            },
                      icon: const Icon(Icons.offline_pin_outlined),
                      label: const Text('Use offline — without a server'),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text('Watch what you downloaded and your own video folders on this device.',
                          textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Color(0xFF8B95A5))),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
