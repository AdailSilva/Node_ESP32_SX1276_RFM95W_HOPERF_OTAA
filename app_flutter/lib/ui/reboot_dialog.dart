// "Reiniciando…": espera o dispositivo voltar (GET /status) e fecha sozinho.
import 'dart:async';

import 'package:flutter/material.dart';

import '../core/device_api.dart';
import '../core/session.dart';

/// Resultado: true = voltou; false = o usuário preferiu voltar à lista.
Future<bool> waitReboot(BuildContext context, DeviceSession session, String noun) async {
  final r = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(canPop: false, child: _RebootDialog(session: session, noun: noun)),
  );
  return r ?? true;
}

class _RebootDialog extends StatefulWidget {
  const _RebootDialog({required this.session, required this.noun});

  final DeviceSession session;
  final String noun;

  @override
  State<_RebootDialog> createState() => _RebootDialogState();
}

class _RebootDialogState extends State<_RebootDialog> {
  int _left = 15;
  int _tries = 0;
  Timer? _timer;
  String _msg = '';
  bool _inFlight = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _tick() async {
    if (!mounted) return;
    if (_left > 0) {
      setState(() => _left--);
      return;
    }
    if (_inFlight) return;
    if (_tries % 3 == 0) {
      _inFlight = true;
      try {
        await widget.session.api.getJson('/status', timeout: const Duration(seconds: 2));
        await widget.session.reloadConfig();
        if (mounted) Navigator.of(context).pop(true);
        return;
      } on ApiException catch (e) {
        if (e.unauthorized) {
          if (mounted) Navigator.of(context).pop(false);
          return;
        }
      } catch (_) {
      } finally {
        _inFlight = false;
      }
    }
    _tries++;
    if (mounted) {
      setState(() => _msg = _tries > 45
          ? 'Ainda sem resposta. Se ${widget.noun == 'gateway' ? 'o gateway' : 'o nó'} mudou de modo '
              '(Soft AP ↔ Station) ou de IP, volte à lista e procure de novo.'
          : 'Esperando ${widget.noun == 'gateway' ? 'o gateway' : 'o nó'} responder…');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Reiniciando…'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_left > 0
              ? 'O app reconecta sozinho em $_left s. Se ${widget.noun == 'gateway' ? 'o gateway' : 'o nó'} '
                  'mudou de modo (Soft AP ↔ Station) ou de IP, acesse pelo novo endereço.'
              : _msg),
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Voltar à lista')),
      ],
    );
  }
}
