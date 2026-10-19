import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../security/app_lock.dart';

/// Puts the PIN screen over the app while it is locked. The app underneath
/// keeps its place (open task, scroll) but cannot be seen or reached.
class LockGate extends StatelessWidget {
  const LockGate({super.key, required this.lock, required this.child});
  final AppLock? lock;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final lock = this.lock;
    if (lock == null) return child;
    return ListenableBuilder(
      listenable: lock,
      builder: (context, _) => Stack(children: [
        Positioned.fill(child: ExcludeSemantics(excluding: lock.locked, child: TickerMode(enabled: !lock.locked, child: child))),
        if (lock.locked) Positioned.fill(child: LockScreen(lock: lock)),
      ]),
    );
  }
}

class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.lock});
  final AppLock lock;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String _pin = '';
  String? _message;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.lock.waitSeconds > 0) setState(() {});
    });
    if (widget.lock.biometricEnabled) WidgetsBinding.instance.addPostFrameCallback((_) => _biometric());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _biometric() async {
    await widget.lock.unlockWithBiometric();
  }

  Future<void> _press(String d) async {
    if (widget.lock.waitSeconds > 0 || _pin.length >= 12) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin += d;
      _message = null;
    });
  }

  Future<void> _submit() async {
    if (_pin.length < 4) return;
    final r = await widget.lock.unlock(_pin);
    if (!mounted) return;
    setState(() {
      _pin = '';
      _message = switch (r) {
        UnlockResult.ok => null,
        UnlockResult.wrong => 'Wrong PIN',
        UnlockResult.waiting => null,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final wait = widget.lock.waitSeconds;
    return Material(
      color: cs.surface,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.lock_outline, size: 40, color: cs.primary),
              const SizedBox(height: 12),
              Text('NoteDo is locked', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 20),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (var i = 0; i < (_pin.length < 4 ? 4 : _pin.length); i++)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i < _pin.length ? cs.primary : Colors.transparent,
                      border: Border.all(color: cs.outline),
                    ),
                  ),
              ]),
              SizedBox(
                height: 36,
                child: Center(
                  child: Text(
                    wait > 0 ? 'Too many tries. Wait $wait s.' : (_message ?? ''),
                    style: TextStyle(color: cs.error),
                  ),
                ),
              ),
              for (final row in const [['1', '2', '3'], ['4', '5', '6'], ['7', '8', '9']])
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [for (final d in row) _Key(label: d, onTap: () => _press(d))]),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                widget.lock.biometricEnabled
                    ? _Key(icon: Icons.fingerprint, tooltip: 'Use fingerprint or face', onTap: _biometric)
                    : const SizedBox(width: 88, height: 72),
                _Key(label: '0', onTap: () => _press('0')),
                _Key(
                  icon: Icons.backspace_outlined,
                  tooltip: 'Delete',
                  onTap: () => setState(() => _pin = _pin.isEmpty ? '' : _pin.substring(0, _pin.length - 1)),
                ),
              ]),
              const SizedBox(height: 12),
              FilledButton(onPressed: _pin.length >= 4 && wait == 0 ? _submit : null, child: const Text('Unlock')),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({this.label, this.icon, this.tooltip, required this.onTap});
  final String? label;
  final IconData? icon;
  final String? tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 88,
        height: 72,
        child: Center(
          child: Tooltip(
            message: tooltip ?? label ?? '',
            child: InkResponse(
              onTap: onTap,
              radius: 36,
              child: SizedBox(
                width: 64,
                height: 64,
                child: Center(child: icon != null ? Icon(icon, size: 28) : Text(label!, style: Theme.of(context).textTheme.headlineSmall)),
              ),
            ),
          ),
        ),
      );
}

/// Asks for a new PIN twice. Returns it, or null if cancelled.
Future<String?> askNewPin(BuildContext context, {String title = 'Choose a PIN'}) {
  final a = TextEditingController();
  final b = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        final ok = AppLock.validPin(a.text) && a.text == b.text;
        return AlertDialog(
          title: Text(title),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('4 to 12 digits. If you forget it, the only way back in is to reinstall the app, which removes the tasks on this device (they stay on the server if you use sync).'),
            const SizedBox(height: 12),
            TextField(
              controller: a,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(12)],
              decoration: const InputDecoration(labelText: 'PIN'),
              onChanged: (_) => set(() {}),
            ),
            TextField(
              controller: b,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(12)],
              decoration: const InputDecoration(labelText: 'Repeat the PIN'),
              onChanged: (_) => set(() {}),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: ok ? () => Navigator.pop(ctx, a.text) : null, child: const Text('Save')),
          ],
        );
      },
    ),
  );
}

/// Asks for the current PIN. Returns it, or null if cancelled.
Future<String?> askPin(BuildContext context, {String title = 'Enter your PIN'}) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        obscureText: true,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(12)],
        decoration: const InputDecoration(labelText: 'PIN'),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('OK')),
      ],
    ),
  );
}
