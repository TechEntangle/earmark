import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import 'theme.dart';

/// First run: connect this phone to Earmark on the Mac.
class PairScreen extends StatefulWidget {
  final EarmarkController c;
  const PairScreen({super.key, required this.c});
  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  final _addr = TextEditingController();
  final _code = TextEditingController();
  late final _name = TextEditingController(text: Platform.isIOS ? 'iPhone' : 'Android phone');
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final p = widget.c.pairing;
    if (p != null) _addr.text = p.server.host;
    if (widget.c.linkError != null) _error = widget.c.linkError;
  }

  Future<void> _go() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.c.pair(_addr.text, _code.text, _name.text.trim().isEmpty ? 'Phone' : _name.text.trim());
    } catch (e) {
      setState(() => _error = e is FormatException ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t, tt = Theme.of(context).textTheme;
    Widget step(String n, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 22, height: 22, alignment: Alignment.center,
              decoration: BoxDecoration(color: t.liveSoft, shape: BoxShape.circle),
              child: Text(n, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.liveInk)),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: tt.bodyMedium?.copyWith(color: t.ink2))),
          ]),
        );
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(22, 36, 22, 30), children: [
          Row(children: [
            ClipRRect(borderRadius: BorderRadius.circular(9), child: Image.asset('assets/icon.png', width: 40, height: 40)),
            const SizedBox(width: 12),
            Text('Earmark', style: tt.headlineMedium),
          ]),
          const SizedBox(height: 22),
          Text('Connect to your Mac', style: tt.headlineLarge),
          const SizedBox(height: 8),
          Text('Earmark keeps everything on your own devices. This phone holds the pendant and records; '
              'your Mac transcribes and writes the notes. They talk over your private Tailscale link.',
              style: tt.bodyLarge?.copyWith(color: t.ink2)),
          const SizedBox(height: 22),
          step('1', 'Make sure Tailscale is on, on this phone and on the Mac.'),
          step('2', 'On the Mac, open Earmark, then Settings, Phone, and choose Pair a phone.'),
          step('3', 'Enter the address and the 6-digit code it shows.'),
          const SizedBox(height: 14),
          TextField(
            controller: _addr,
            keyboardType: TextInputType.url,
            autocorrect: false,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'Mac address', hintText: 'your-mac.tailnet.ts.net'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _code,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(fontSize: 24, letterSpacing: 8, fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
            decoration: const InputDecoration(labelText: '6-digit code', counterText: ''),
            onSubmitted: (_) => _go(),
          ),
          const SizedBox(height: 12),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name for this phone')),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: t.bad, fontSize: 14)),
          ],
          const SizedBox(height: 18),
          FilledButton(
            onPressed: _busy ? null : _go,
            child: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Connect'),
          ),
        ]),
      ),
    );
  }
}
