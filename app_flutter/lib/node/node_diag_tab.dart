// Aba Diagnósticos: ping, traceroute e nslookup feitos PELO nó, igual à aba do
// gateway (GET /diag_run?t=ping|trace|dns&h=<host>, resultado linha a linha).
import 'package:flutter/material.dart';

import '../core/device_api.dart';
import '../core/format.dart';
import '../core/session.dart';
import '../ui/term_view.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Destino padrão dos três testes (o mesmo DIAG_DEFAULT_HOST do firmware).
const String diagDefaultHost = 'chirpstack-v4.adailsilva.com.br';

class NodeDiagTab extends StatefulWidget {
  const NodeDiagTab({super.key, required this.session});

  final DeviceSession session;

  @override
  State<NodeDiagTab> createState() => _NodeDiagTabState();
}

class _NodeDiagTabState extends State<NodeDiagTab> {
  final TextEditingController _host = TextEditingController();
  String _out = 'Escolha o destino e toque num dos testes.';
  String _status = '';
  bool _busy = false;
  CancelToken? _cancel;
  final ScrollController _scroll = ScrollController();

  static final _bad = RegExp(r'não |sem resposta|erro|\*\*\*|!\w?$|\s\*$');
  static final _good = RegExp(r' (time|tempo)=|^(Address|Endereço):');

  @override
  void initState() {
    super.initState();
    _host.text = diagDefaultHost;
  }

  @override
  void dispose() {
    _cancel?.cancel();
    _host.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Igual à página: ChirpStack (padrão), 8.8.8.8 e openwrt.org (a página também
  /// sugere o roteador Wi-Fi, que o app não conhece).
  List<String> _suggestions() {
    final out = <String>[];
    void add(String v) {
      v = v.trim();
      if (v.isNotEmpty && RegExp(r'^[A-Za-z0-9._:-]{1,63}$').hasMatch(v) && !out.contains(v)) out.add(v);
    }

    add(diagDefaultHost);
    add('8.8.8.8');
    add('openwrt.org');
    return out;
  }

  Future<void> _run(String t) async {
    final h = _host.text.trim();
    if (!RegExp(r'^[A-Za-z0-9._:-]{1,63}$').hasMatch(h)) {
      setState(() => _status = 'destino inválido');
      return;
    }
    FocusScope.of(context).unfocus();
    final cancel = CancelToken();
    final t0 = DateTime.now();
    setState(() {
      _busy = true;
      _cancel = cancel;
      _out = '';
      _status = 'executando…';
    });
    try {
      await for (final chunk
          in widget.session.api.streamText('/diag_run', query: {'t': t, 'h': h}, cancel: cancel)) {
        if (!mounted) return;
        setState(() => _out += chunk);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
        });
      }
      final secs = DateTime.now().difference(t0).inMilliseconds / 1000;
      if (mounted) setState(() => _status = 'concluído em ${dec(secs, 1)} s');
    } on ApiException catch (e) {
      if (mounted) setState(() => _status = cancel.cancelled ? 'interrompido' : 'falhou: ${e.message}');
    } catch (e) {
      if (mounted) setState(() => _status = cancel.cancelled ? 'interrompido' : 'falhou: $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _cancel = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sugg = _suggestions();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _host,
                enabled: !_busy,
                autocorrect: false,
                keyboardType: TextInputType.url,
                style: const TextStyle(fontFamily: monoFont),
                onSubmitted: (_) => _run('ping'),
                decoration: fieldDecoration(context, label: 'Endereço ou nome do host'),
              ),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 4, children: [
                for (final s in sugg)
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(s, style: const TextStyle(fontFamily: monoFont, fontSize: 12)),
                    onPressed: _busy ? null : () => setState(() => _host.text = s),
                  ),
              ]),
              const SizedBox(height: 8),
              // três botões dividindo a largura: com o padding padrão (24 px de cada lado)
              // "Traceroute" não cabia num celular de 360 px e ficava cortado
              Row(children: [
                for (final b in const [
                  ['ping', 'Ping', '5 pacotes ICMP, 1 por segundo'],
                  ['trace', 'Traceroute', 'Até 15 saltos, 1 tentativa de 1 s por salto'],
                  ['dns', 'Nslookup', 'Resolve o nome pelo DNS que o nó usa'],
                ]) ...[
                  if (b[0] != 'ping') const SizedBox(width: 6),
                  Expanded(
                    child: Tooltip(
                      message: b[2],
                      child: FilledButton.tonal(
                        style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                        onPressed: _busy ? null : () => _run(b[0]),
                        child: FittedBox(fit: BoxFit.scaleDown, child: Text(b[1], maxLines: 1)),
                      ),
                    ),
                  ),
                ],
              ]),
              if (_busy)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => _cancel?.cancel(),
                    icon: const Icon(Icons.stop),
                    label: const Text('Parar'),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Enquanto um teste roda, o nó espera ele terminar para atender o resto '
                  '(ping ~5 s, traceroute até ~15 s). ${_status.isEmpty ? '' : '· $_status'}',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(8, 6, 8, 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: AppColors.term, borderRadius: BorderRadius.circular(10)),
            // sem quebra de linha: linhas longas rolam para o lado
            child: SelectionArea(
              child: TermLines(
                lines: _out.split('\n'),
                controller: _scroll,
                colorOf: (l) => _bad.hasMatch(l)
                    ? AppColors.termErr
                    : _good.hasMatch(l)
                        ? AppColors.termOk
                        : null,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
