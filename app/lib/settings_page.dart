import 'package:flutter/material.dart';

import 'api.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.serverUrl});

  final String serverUrl;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.serverUrl);
  bool _testing = false;
  String? _result;
  bool _ok = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    final url = _controller.text.trim();
    setState(() {
      _testing = true;
      _result = null;
    });
    try {
      final info = await GrabberApi(url).health();
      if (!mounted) return;
      setState(() {
        _ok = true;
        _result = 'Connected. ${info['providers']} · '
            '${info['format']} ${info['bitrate']} · '
            '${info['downloaded']} file(s) indexed'
            '${info['deno'] == null ? ' · Deno missing!' : ''}';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _ok = false;
        _result = error.toString();
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Server')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'The downloader runs on your PC. This address is how the phone '
              'reaches it over Wi-Fi.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Server address',
                hintText: 'http://192.168.1.20:8787',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _testing ? null : _test,
                  icon: _testing
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering),
                  label: const Text('Test'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      final url = _controller.text.trim();
                      Navigator.of(context).pop(url);
                    },
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
            if (_result != null) ...[
              const SizedBox(height: 16),
              Card(
                color: _ok
                    ? theme.colorScheme.secondaryContainer
                    : theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_result!),
                ),
              ),
            ],
            const SizedBox(height: 24),
            Text(
              'Start the server on the PC with server/run.sh, then use the '
              'address it prints.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
