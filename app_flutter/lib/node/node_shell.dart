// Tela do nó depois do login: Status, Configuração, Logs, Diagnósticos e Manutenção
// (os mesmos menus da página web do nó).
import 'package:flutter/material.dart';

import '../core/flavor.dart';
import '../core/format.dart';
import '../core/session.dart';
import '../ui/logs_screen.dart';
import '../ui/lorawan_classes_screen.dart';
import '../ui/reboot_dialog.dart';
import '../ui/widgets.dart';
import 'node_config_tab.dart';
import 'node_diag_tab.dart';
import 'node_logic.dart';
import 'node_maint_tab.dart';
import 'node_status_tab.dart';

final nodeLogStyle = LogStyle(
  err: RegExp(r'FAIL|ERROR|Invalid|DEAD|inválid', caseSensitive: false),
  warn: RegExp(r'WARN|RESET|TXCANCELED|OP_TXRXPEND|Soft AP'),
  info: RegExp(r'^\[RX\]|Downlink|ACK received|EV_JOINED'),
  ok: RegExp(r'^EV_|^\[TX\]|Packet queued'),
  filterHint: 'Filtrar (ex.: [TX], [RX], Downlink, JOIN)',
  deviceDownloadLabel: 'Baixar do nó (até 16 KB em RAM)',
  sessionPrefix: 'lorawan_node_sessao',
  defaultDownloadName: 'lorawan_node.log',
);

class NodeShell extends StatefulWidget {
  const NodeShell({super.key, required this.session});

  final DeviceSession session;

  @override
  State<NodeShell> createState() => _NodeShellState();
}

class _NodeShellState extends State<NodeShell> with WidgetsBindingObserver {
  int _tab = 0;
  bool _fg = true;
  bool _authDialog = false;
  bool _rebooting = false;
  final GlobalKey<NodeConfigTabState> _cfgKey = GlobalKey<NodeConfigTabState>();

  DeviceSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    s.addListener(_onSession);
    _applyPolling();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    s.removeListener(_onSession);
    s.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _fg = state == AppLifecycleState.resumed;
    _applyPolling();
    setState(() {});
  }

  void _applyPolling() => s.setPolling(_fg && _tab == 0);

  /// Login recusado em qualquer aba (Status, Configuração, Logs...): avisa e volta
  /// para a lista. Durante o reinício quem cuida é a janela "Reiniciando…".
  void _onSession() {
    if (s.authLost && !_authDialog && !_rebooting && mounted) {
      _authDialog = true;
      // fecha o que estiver aberto por cima (diálogo de erro, menu) antes de avisar
      Navigator.of(context).popUntil((r) => r is PageRoute);
      messageDialog(context, 'Login recusado',
              'O nó não aceitou mais o usuário/senha (o login foi trocado?). Entre de novo.')
          .then((_) {
        if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
      });
    }
  }

  Future<void> _reboot({bool ask = true}) async {
    if (ask && !await confirmDialog(context, 'Reiniciar', 'Reiniciar o nó agora?', confirm: 'Reiniciar')) return;
    s.setPolling(false);
    _rebooting = true;
    try {
      await s.api.postRestart('/reboot');
    } catch (e) {
      _rebooting = false;
      if (mounted) messageDialog(context, 'Reiniciar', '$e');
      _applyPolling();
      return;
    }
    if (!mounted) return;
    final back = await waitReboot(context, s, 'nó');
    _rebooting = false;
    if (!mounted) return;
    if (!back || s.authLost) {
      Navigator.of(context).popUntil((r) => r.isFirst);
      return;
    }
    _applyPolling();
  }

  Future<void> _leave() async {
    final dirty = _cfgKey.currentState?.dirty ?? false;
    final ok = await confirmDialog(
      context,
      'Sair',
      dirty ? 'Há alterações não salvas na Configuração. Sair mesmo assim?' : 'Sair da configuração do nó?',
      confirm: 'Sair',
    );
    if (ok && mounted) Navigator.of(context).pop();
  }

  void _setTab(int i) {
    setState(() => _tab = i);
    _applyPolling();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: AnimatedBuilder(
        animation: s,
        builder: (context, _) {
          final n = s.status?['node'] as Map?;
          final l = s.status?['lw'] as Map?;
          final otaa = s.config['_mode'] == 'otaa';
          final joined = l?['joined'] == true;
          final ip = sv(n?['ip']).isNotEmpty ? sv(n?['ip']) : (sv(n?['ap_ip']).isNotEmpty ? sv(n?['ap_ip']) : s.api.host);
          final idLabel = otaa && !joined ? 'DevEUI' : 'DevAddr';
          final idValue = otaa && !joined ? sv(s.config['dev_eui']) : sv(l?['devaddr'] ?? s.config['dev_addr']);
          final list = sv(s.config['ch_list']).trim();
          final plan = '${sv(s.config['_region']).isEmpty ? 'AU915' : sv(s.config['_region'])}'
              '${list.isNotEmpty ? ' custom' : ' SB${s.config['sub_band'] ?? '-'}'}';
          return Scaffold(
            appBar: AppBar(
              title: Row(children: [
                Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(s.device.name, maxLines: 1, softWrap: false))),
                const SizedBox(width: 8),
                Tag(otaa ? 'OTAA' : 'ABP', color: const Color(0xFFE8F1EE)),
              ]),
              actions: [
                const ClassesButton(),
                IconButton(onPressed: _leave, icon: const Icon(Icons.logout), tooltip: 'Sair'),
              ],
            ),
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // chips com quebra de linha (nunca cortados nem escondidos numa rolagem lateral)
                Container(
                  color: Theme.of(context).appBarTheme.backgroundColor,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                  child: InfoChips([
                      ChipInfo(lwChip(l), '', level: lwChipLevel(l)),
                      ChipInfo('IP', ip),
                      ChipInfo(idLabel, idValue.isEmpty ? '-' : idValue, copy: true),
                      ChipInfo('Plano', plan),
                    ]),
                ),
                Expanded(
                  child: IndexedStack(
              index: _tab,
              children: [
                NodeStatusTab(session: s),
                NodeConfigTab(key: _cfgKey, session: s, onReboot: _reboot),
                LogsView(api: s.api, active: _fg && _tab == 2, style: nodeLogStyle),
                NodeDiagTab(session: s),
                NodeMaintTab(
                  session: s,
                  onReboot: _reboot,
                  onImport: (j) {
                    final c = _cfgKey.currentState?.importJson(j) ?? 0;
                    if (c > 0) _setTab(1);
                    return c;
                  },
                  onFactoryDone: () async {
                    await s.updateCredentials(AppFlavor.defaultUser, AppFlavor.defaultPassword);
                    if (mounted) Navigator.of(context).pop();
                  },
                ),
              ],
            ),
                ),
              ],
            ),
            bottomNavigationBar: NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: _setTab,
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              destinations: const [
                NavigationDestination(icon: Icon(Icons.monitor_heart_outlined), label: 'Status'),
                NavigationDestination(icon: Icon(Icons.tune), label: 'Config.'),
                NavigationDestination(icon: Icon(Icons.article_outlined), label: 'Logs'),
                NavigationDestination(icon: Icon(Icons.network_ping), label: 'Diagnóst.'),
                NavigationDestination(icon: Icon(Icons.build_outlined), label: 'Manutenção'),
              ],
            ),
          );
        },
      ),
    );
  }
}
