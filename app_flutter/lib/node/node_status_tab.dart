// Aba Status do nó: sessão LoRaWAN, chaves de sessão, contadores e as ações
// (Enviar agora, Refazer JOIN / Reprovisionar sessão, Alterar FCnt).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/device_api.dart';
import '../core/format.dart';
import '../core/session.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'node_logic.dart';

class NodeStatusTab extends StatefulWidget {
  const NodeStatusTab({super.key, required this.session});

  final DeviceSession session;

  @override
  State<NodeStatusTab> createState() => _NodeStatusTabState();
}

class _NodeStatusTabState extends State<NodeStatusTab> {
  String _msg = '';
  bool _busy = false;
  bool _showKeys = false;

  DeviceSession get s => widget.session;

  Future<void> _act(String a, {String? confirm, String? value}) async {
    if (confirm != null && !await confirmDialog(context, 'Confirmar', confirm, confirm: 'Sim')) return;
    setState(() {
      _busy = true;
      _msg = '…';
    });
    try {
      final r = await s.api.postForm('/action', {'a': a, if (value != null) 'v': value});
      if (!mounted) return;
      Map<String, dynamic>? j;
      try {
        j = r.json;
      } catch (_) {}
      setState(() => _msg = j == null
          ? 'Resposta inesperada (HTTP ${r.status}).'
          : j['ok'] == true
              ? '${j['msg'] ?? 'OK'}'
              : '${j['error'] ?? 'Falha'}');
      Future<void>.delayed(const Duration(milliseconds: 800), s.refreshStatus);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _msg = e.unauthorized ? e.message : 'Sem resposta do nó');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fcnt() async {
    final lw = s.status?['lw'] as Map?;
    final c = TextEditingController(text: '${lw?['fcnt_up'] ?? 0}');
    final v = await showDialog<String>(
      context: context,
      builder: (x) => AlertDialog(
        title: const Text('Alterar FCnt'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Próximo FCnt de uplink (0 a 4294967295).\nNo ChirpStack, o contador precisa ser maior '
                'que o último recebido — ou zere os contadores do dispositivo lá também.'),
            const SizedBox(height: 12),
            TextField(
              controller: c,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: fieldDecoration(x, label: 'FCnt'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(x), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(x, c.text.trim()), child: const Text('Alterar')),
        ],
      ),
    );
    if (v == null) return;
    final n = int.tryParse(v);
    if (n == null || n < 0 || n > 4294967295) {
      if (mounted) snack(context, 'Número inválido.');
      return;
    }
    _act('fcnt', value: '$n');
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: s,
      builder: (context, _) {
        final st = s.status;
        final n = st?['node'] as Map?;
        final l = st?['lw'] as Map?;
        final otaa = (l?['mode'] ?? s.config['_mode']) == 'otaa';
        final children = <Widget>[];
        if (s.statusError != null) {
          children.add(const StatusBanner('Sem resposta do nó. Tentando de novo…', level: Level.warn));
          children.add(Hint(s.statusError!, top: 0));
          children.add(const SizedBox(height: 10));
        }
        if (n == null || l == null) {
          if (s.statusError == null) children.add(const StatusBanner('Carregando status…'));
        } else {
          final line = nodeLine(l);
          final reboot = '${n['reboot'] ?? ''}';
          children.add(SectionCard(
            title: 'Status',
            subtitle: 'Funcionamento do nó desde que ligou. Atualiza a cada 5 s enquanto esta aba estiver '
                'aberta${s.statusAt == null ? '' : ' · ${clock(s.statusAt)}'}.',
            children: [
              StatusBanner(line.text, level: line.level),
              if (reboot.isNotEmpty)
                StatusBanner('Configuração salva que só vale após reiniciar: $reboot.', level: Level.warn),
              KvGrid(nodeKv(n, l, confirmed: s.config['confirmed'] == 'on')),
              if (l['skeys'] is Map)
                _SessionKeys(
                  keys: l['skeys'] as Map,
                  devAddr: sv(l['devaddr']),
                  otaa: otaa,
                  visible: _showKeys,
                  onToggle: () => setState(() => _showKeys = !_showKeys),
                ),
            ],
          ));
        }
        children.add(SectionCard(
          title: 'Ações',
          subtitle: 'Valem na hora, sem reiniciar o ESP32.',
          children: [
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                onPressed: _busy ? null : () => _act('send'),
                icon: const Icon(Icons.send),
                label: const Text('Enviar agora'),
              ),
              if (otaa)
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _act('restart',
                          confirm: 'Refazer o JOIN agora? O nó deixa de transmitir até o servidor responder.'),
                  icon: const Icon(Icons.sync),
                  label: const Text('Refazer JOIN'),
                )
              else ...[
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _act('restart'),
                  icon: const Icon(Icons.sync),
                  label: const Text('Reprovisionar sessão'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _fcnt,
                  icon: const Icon(Icons.pin),
                  label: const Text('Alterar FCnt…'),
                ),
              ],
            ]),
            Hint(
              otaa
                  ? 'Enviar agora agenda um uplink (respeitando o duty cycle do LMiC).'
                  : 'Enviar agora agenda um uplink. Reprovisionar reaplica DevAddr e chaves sem reiniciar '
                      '(o FCnt é mantido). Alterar FCnt define o próximo contador (também gravado na NVS).',
            ),
            if (_msg.isNotEmpty) Hint(_msg, color: Theme.of(context).colorScheme.primary),
          ],
        ));
        children.add(DevFooter(sv(s.config['name']).isEmpty ? 'LoRaWAN Node' : sv(s.config['name'])));
        return RefreshIndicator(
          onRefresh: s.refreshStatus,
          child: ListView(
            padding: const EdgeInsets.all(12),
            physics: const AlwaysScrollableScrollPhysics(),
            children: children,
          ),
        );
      },
    );
  }
}

/// Sessão em uso, sempre nesta ordem: DevAddr, NwkSKey, AppSKey
/// (hexadecimal, MSB, como no ChirpStack).
/// OTAA: derivadas a cada JOIN aceito. ABP: as configuradas na Ativação ABP.
/// As chaves ficam ocultas até tocar em Mostrar (o DevAddr não é segredo e
/// fica sempre visível); Copiar funciona mesmo ocultas.
class _SessionKeys extends StatelessWidget {
  const _SessionKeys({
    required this.keys,
    this.devAddr = '',
    required this.otaa,
    required this.visible,
    required this.onToggle,
  });

  final Map keys;
  final String devAddr; // fallback p/ firmware antigo sem skeys.devaddr
  final bool otaa;
  final bool visible;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final valid = keys['valid'] == true;
    final age = (keys['age'] as num?) ?? -1;
    final sub = otaa
        ? (valid
            ? 'Derivadas da AppKey no JOIN aceito há ${dur(age < 0 ? 0 : age)} · renovadas a cada novo JOIN'
            : 'Sem sessão: são derivadas quando o JOIN for aceito (e renovadas a cada novo JOIN)')
        : (valid ? 'Configuradas manualmente em Ativação ABP · fixas até você alterá-las' : 'Sessão ABP ainda não provisionada');

    Widget row(String label, String key, {bool secret = true, String fallback = ''}) {
      var v = sv(keys[key]);
      if (v.isEmpty || v == '-') v = fallback;
      final has = valid && v.isNotEmpty;
      return Padding(
        padding: const EdgeInsets.only(top: 6, right: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(label, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant))),
                IconButton(
                  tooltip: 'Copiar $label',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: !has
                      ? null
                      : () async {
                          await Clipboard.setData(ClipboardData(text: v));
                          if (context.mounted) snack(context, '$label ${secret ? 'copiada' : 'copiado'}.');
                        },
                ),
              ],
            ),
            // chave inteira (32 hex) numa linha só: diminui a fonte em telas estreitas
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                !has
                    ? '-'
                    : (visible || !secret)
                        ? v
                        : '${'•' * 16} (oculta)',
                maxLines: 1,
                softWrap: false,
                style: const TextStyle(
                    fontFamily: monoFont, fontSize: 14.5, fontWeight: FontWeight.w600, letterSpacing: .3),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withAlpha(90),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Chaves de sessão', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 1),
                    Text(sub, style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant, height: 1.3)),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: valid ? onToggle : null,
                icon: Icon(visible ? Icons.visibility_off : Icons.visibility, size: 18),
                label: Text(visible ? 'Ocultar' : 'Mostrar'),
              ),
            ],
          ),
          row('DevAddr', 'devaddr', secret: false, fallback: devAddr),
          row('NwkSKey', 'nwk'),
          row('AppSKey', 'app'),
        ],
      ),
    );
  }
}
