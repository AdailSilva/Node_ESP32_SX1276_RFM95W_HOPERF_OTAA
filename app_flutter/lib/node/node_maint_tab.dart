// Aba Manutenção do nó: exportar/importar, padrão de fábrica, reinício e firmware.
import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/device_api.dart';
import '../core/file_io.dart';
import '../core/format.dart';
import '../core/html_text.dart';
import '../core/session.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

class NodeMaintTab extends StatelessWidget {
  const NodeMaintTab({
    super.key,
    required this.session,
    required this.onImport,
    required this.onReboot,
    required this.onFactoryDone,
  });

  final DeviceSession session;
  final int Function(Map<String, dynamic> json) onImport;
  final Future<void> Function({bool ask}) onReboot;
  final VoidCallback onFactoryDone;

  DeviceApi get api => session.api;
  String get mode => '${session.config['_mode'] ?? ''}';

  Future<void> _export(BuildContext context) async {
    try {
      final j = await api.getJson('/config.json');
      j.remove('wifi_pswd_set');
      j.remove('ap_pswd_set');
      final name = '${hostSlug(sv(j['name']))}_${dateStamp()}.json';
      final path = await FileIO.saveText(name, const JsonEncoder.withIndent('  ').convert(j));
      if (context.mounted && path != null) snack(context, 'Salvo: $name');
    } on ApiException catch (e) {
      if (context.mounted && !e.unauthorized) messageDialog(context, 'Exportar', 'Não foi possível ler a configuração do nó.\n${e.message}');
    } catch (e) {
      if (context.mounted) snack(context, 'Não foi possível salvar: $e');
    }
  }

  Future<void> _import(BuildContext context) async {
    String? text;
    try {
      text = await FileIO.pickText(extensions: const ['json']);
    } catch (e) {
      if (context.mounted) snack(context, 'Não foi possível abrir o arquivo: $e');
      return;
    }
    if (text == null || !context.mounted) return;
    Map<String, dynamic> j;
    try {
      final v = jsonDecode(text);
      if (v is! Map<String, dynamic>) throw const FormatException();
      j = v;
    } catch (_) {
      messageDialog(context, 'Importar', 'Arquivo JSON inválido.');
      return;
    }
    if (j['_type'] == 'esp32_sx1302') {
      messageDialog(context, 'Importar', 'Este arquivo é do gateway ESP32_SX1302, não de um nó.');
      return;
    }
    final m = j['_mode'];
    if (m is String && m != mode) {
      final go = await confirmDialog(
        context,
        'Importar',
        'Este arquivo é de um nó ${m.toUpperCase()} e este firmware é ${mode.toUpperCase()}. Importar mesmo assim?',
        confirm: 'Importar',
      );
      if (!go || !context.mounted) return;
    }
    final n = onImport(j);
    if (!context.mounted) return;
    snack(context, n == 0
        ? 'Nenhum campo do nó encontrado no arquivo.'
        : 'Configuração carregada no formulário. Revise e toque em Salvar.');
  }

  Future<void> _factory(BuildContext context) async {
    final ok = await confirmDialog(
      context,
      'Restaurar padrão de fábrica',
      'Apagar toda a configuração salva e voltar aos valores de fábrica?\n'
          'O nó reinicia e o login volta para admin / lorawan101.',
      confirm: 'Restaurar',
      danger: true,
    );
    if (!ok || !context.mounted) return;
    String? html;
    try {
      html = await api.postRestart('/factory');
    } on ApiException catch (e) {
      if (context.mounted && !e.unauthorized) messageDialog(context, 'Padrão de fábrica', e.message);
      return;
    }
    if (!context.mounted) return;
    final page = html == null ? null : parseSimplePage(html);
    await messageDialog(
      context,
      (page != null && page.title.isNotEmpty) ? page.title : 'Padrão de fábrica restaurado',
      (page != null && page.body.isNotEmpty)
          ? page.body
          : 'O nó está reiniciando com os valores do node_build.h. Login da página: admin / lorawan101. '
              'O contador de frames (FCnt) foi mantido.',
    );
    onFactoryDone();
  }

  @override
  Widget build(BuildContext context) {
    final c = session.config;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        SectionCard(
          title: 'Manutenção',
          subtitle: 'Cópia de segurança da configuração e volta ao padrão de fábrica.',
          children: [
            Wrap(spacing: 10, runSpacing: 10, children: [
              FilledButton.tonalIcon(
                onPressed: () => _export(context),
                icon: const Icon(Icons.download),
                label: const Text('Exportar configuração'),
              ),
              OutlinedButton.icon(
                onPressed: () => _import(context),
                icon: const Icon(Icons.upload_file),
                label: const Text('Importar…'),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: AppColors.errOf(context)),
                onPressed: () => _factory(context),
                icon: const Icon(Icons.restore),
                label: const Text('Restaurar padrão de fábrica'),
              ),
            ]),
            const Hint(
                'A exportação gera um JSON com tudo, menos as senhas (Wi-Fi, Soft AP e página). Importar preenche o '
                'formulário da aba Configuração; revise e toque em Salvar. O padrão de fábrica usa os valores do '
                'node_build.h e mantém o FCnt.',
                top: 10),
          ],
        ),
        SectionCard(
          title: 'Reiniciar',
          subtitle: 'Reinicia o ESP32. Wi-Fi, inicialização e hardware passam a valer.',
          children: [
            FilledButton.icon(
              onPressed: () => onReboot(ask: true),
              icon: const Icon(Icons.restart_alt),
              label: const Text('Reiniciar nó'),
            ),
          ],
        ),
        SectionCard(
          title: 'Firmware',
          children: [
            KvGrid([
              KvItem('Firmware', sv(c['_fw']).isEmpty ? '-' : sv(c['_fw'])),
              KvItem('LMiC', sv(c['_lmic']).isEmpty ? '-' : sv(c['_lmic'])),
              KvItem('Região', sv(c['_region']).isEmpty ? '-' : sv(c['_region'])),
              KvItem('Placa', sv(c['_board_name']).isEmpty ? (sv(c['_chip']).isEmpty ? '-' : sv(c['_chip'])) : sv(c['_board_name']),
                  sv(c['_board']).isEmpty ? '' : '${sv(c['_board'])} · ${sv(c['_chip'])}'),
              KvItem.copyable('MAC', sv(c['_mac']).isEmpty ? '-' : sv(c['_mac'])),
              KvItem('Endereço', api.port == 80 ? api.host : '${api.host}:${api.port}',
                  '${hostSlug(sv(c['name']))}.local'),
            ]),
          ],
        ),
        DevFooter(sv(c['name']).isEmpty ? 'LoRaWAN Node' : sv(c['name'])),
      ],
    );
  }
}
