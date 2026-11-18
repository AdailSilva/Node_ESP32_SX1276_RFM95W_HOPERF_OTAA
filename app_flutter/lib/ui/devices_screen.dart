// Tela inicial: dispositivos salvos, busca na rede, IP manual e Soft AP.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_host.dart';
import '../core/device_api.dart';
import '../core/discovery.dart';
import '../core/flavor.dart';
import '../core/storage.dart';
import '../core/wifi_helper.dart';
import 'login_screen.dart';
import 'lorawan_classes_screen.dart';
import 'theme.dart';
import 'widgets.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  List<SavedDevice> _devices = [];
  bool _loading = true;

  AppFlavor get fl => appHost.flavor;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final list = await DeviceStore.instance.load();
    if (!mounted) return;
    setState(() {
      _devices = [...list];
      _loading = false;
    });
  }

  Future<void> _open(SavedDevice d) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => LoginScreen(device: d)));
    _reload();
  }

  Future<SavedDevice> _addFound(String host, int port, Map<String, dynamic>? info) async {
    final name = info == null
        ? host
        : FoundDevice(host: host, port: port, info: info, source: '').name;
    final d = SavedDevice(
      id: SavedDevice.newId(),
      name: name,
      host: host,
      port: port,
      mdnsHost: '${info?['host'] ?? ''}',
      version: '${info?['version'] ?? ''}',
      detail: '${info?['board_name'] ?? info?['target'] ?? info?['chip'] ?? ''}',
    );
    final existing = _devices.where((x) => x.host == host && x.port == port);
    if (existing.isNotEmpty) return existing.first;
    return DeviceStore.instance.upsert(d);
  }

  // ------------------------------ busca ------------------------------
  Future<void> _scan() async {
    await WifiHelper.bindToWifi();
    if (!mounted) return;
    final picked = await showModalBottomSheet<FoundDevice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ScanSheet(flavor: fl),
    );
    if (picked == null) return;
    final d = await _addFound(picked.host, picked.port, picked.info);
    await _reload();
    if (mounted) _open(d);
  }

  // ---------------------------- IP manual ----------------------------
  Future<void> _addByIp() async {
    final ctrl = TextEditingController();
    final host = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Adicionar por endereço'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.url,
              style: const TextStyle(fontFamily: monoFont),
              decoration: fieldDecoration(c, label: 'IP ou nome', hint: '192.168.18.101'),
              onSubmitted: (v) => Navigator.pop(c, v),
            ),
            Hint(fl.isGateway
                ? 'O IP aparece no display OLED, no console serial e no roteador. '
                    'No Soft AP do gateway: ${AppFlavor.apIp}.'
                : 'O IP aparece no Serial Monitor. Também funciona <nome>.local. '
                    'No Soft AP do nó: ${AppFlavor.apIp}.'),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: const Text('Adicionar')),
        ],
      ),
    );
    if (host == null) return;
    var h = host.trim().replaceFirst(RegExp(r'^https?://'), '').replaceAll(RegExp(r'/.*$'), '');
    var port = 80;
    final m = RegExp(r'^(.+):(\d{1,5})$').firstMatch(h);
    if (m != null) {
      h = m.group(1)!;
      port = int.tryParse(m.group(2)!) ?? 80;
    }
    if (h.isEmpty || !RegExp(r'^[A-Za-z0-9.\-]+$').hasMatch(h)) {
      if (mounted) snack(context, 'Endereço inválido.');
      return;
    }
    await WifiHelper.bindToWifi();
    final info = await DeviceApi.probeInfo(h, port: port, timeout: const Duration(seconds: 3));
    if (!mounted) return;
    if (info != null && !fl.acceptsInfo(info)) {
      final go = await confirmDialog(
        context,
        'Outro tipo de dispositivo',
        'Este endereço é de ${AppFlavor.describeInfo(info)}. Este app é para '
            '${fl.isGateway ? 'o gateway' : 'nós ${fl.nodeMode.toUpperCase()}'}. Adicionar mesmo assim?',
        confirm: 'Adicionar',
      );
      if (!go) return;
    }
    final d = await _addFound(h, port, info);
    await _reload();
    if (mounted) _open(d);
  }

  // ------------------------------ Soft AP -----------------------------
  Future<void> _softAp() async {
    final ssid = TextEditingController(text: fl.defaultApSsid);
    final pass = TextEditingController(text: AppFlavor.defaultPassword);
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Conectar ao Soft AP'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Hint(fl.apHint, top: 0),
              const SizedBox(height: 12),
              TextFieldX(controller: ssid, label: 'Rede (SSID)', maxLength: 32),
              TextFieldX(controller: pass, label: 'Senha do Soft AP', password: true, maxLength: 64),
              Hint('O ${fl.deviceNoun} fica em ${AppFlavor.apIp}. Essa rede não tem internet: '
                  'o app prende o tráfego dele ao Wi-Fi enquanto estiver conectado.'),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Conectar')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final s = ssid.text.trim();
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Expanded(child: Text('Conectando ao Soft AP…')),
          ]),
        ),
      ),
    );
    final ok = s.isNotEmpty && await WifiHelper.connectSoftAp(s, pass.text);
    if (!mounted) return;
    Navigator.of(context).pop();
    if (!ok) {
      final manual = await confirmDialog(
        context,
        'Conecte pelo Android',
        'Não deu para conectar automaticamente. Abra as configurações de Wi-Fi do Android, '
            'conecte na rede "$s" (senha ${pass.text.isEmpty ? '—' : pass.text}) e, se o Android '
            'avisar que a rede não tem internet, escolha manter a conexão. Depois toque em Continuar.',
        confirm: 'Continuar',
      );
      if (!manual) return;
      await WifiHelper.bindToWifi();
    }
    final existing = _devices.where((x) => x.host == AppFlavor.apIp);
    final d = existing.isNotEmpty
        ? existing.first
        : await DeviceStore.instance.upsert(SavedDevice(
            id: SavedDevice.newId(),
            name: 'Soft AP $s',
            host: AppFlavor.apIp,
            apSsid: s,
          ));
    await _reload();
    if (mounted) _open(d);
  }

  // ------------------------------ menu ------------------------------
  Future<void> _menu(SavedDevice d, String action) async {
    switch (action) {
      case 'rename':
        final c = TextEditingController(text: d.name);
        final n = await showDialog<String>(
          context: context,
          builder: (x) => AlertDialog(
            title: const Text('Renomear'),
            content: TextField(controller: c, autofocus: true, decoration: fieldDecoration(x, label: 'Nome')),
            actions: [
              TextButton(onPressed: () => Navigator.pop(x), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(x, c.text.trim()), child: const Text('Salvar')),
            ],
          ),
        );
        if (n != null && n.isNotEmpty) {
          d.name = n;
          await DeviceStore.instance.update(d);
        }
        break;
      case 'forget':
        d.password = null;
        d.remember = false;
        await DeviceStore.instance.update(d);
        if (mounted) snack(context, 'Senha esquecida.');
        break;
      case 'remove':
        final ok = await confirmDialog(context, 'Remover', 'Remover "${d.name}" da lista do app?\n'
            'Nada muda no ${fl.deviceNoun}.', confirm: 'Remover', danger: true);
        if (ok) await DeviceStore.instance.remove(d.id);
        break;
    }
    _reload();
  }

  void _about() {
    showAboutDialog(
      context: context,
      applicationName: fl.appTitle,
      applicationVersion: '1.0.0',
      applicationIcon: Icon(fl.isGateway ? Icons.cell_tower : Icons.sensors, color: AppColors.accentOf(context)),
      children: [
        const Text('Mesmas funções da página web do firmware, pela rede Wi-Fi local '
            '(HTTP com login, os mesmos endereços da página).'),
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: () => launchUrl(Uri.parse('https://k8s.adailsilva.com.br/'),
              mode: LaunchMode.externalApplication),
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('Desenvolvido por AdailSilva'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(fl.appTitle),
        actions: [
          const ClassesButton(),
          IconButton(onPressed: _about, icon: const Icon(Icons.info_outline), tooltip: 'Sobre'),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 110),
                children: [
                  if (_devices.isEmpty)
                    SectionCard(
                      title: 'Nenhum ${fl.deviceNoun} salvo',
                      subtitle: fl.isGateway
                          ? 'Toque em Procurar com o celular na mesma rede Wi-Fi do gateway. '
                              'O gateway ESP32-S3 aparece pelo mDNS; o ESP32-WROOM-32U é achado '
                              'varrendo a rede. Gateway em modo Soft AP: use "Soft AP".'
                          : 'Toque em Procurar com o celular na mesma rede Wi-Fi do nó (mDNS). '
                              'Nó em modo Soft AP (ou sem Wi-Fi configurado): use "Soft AP". '
                              'Com o Wi-Fi do nó desligado, segure o botão do Soft AP por 3 s.',
                      children: const [],
                    ),
                  for (final d in _devices)
                    Card(
                      elevation: 0,
                      margin: const EdgeInsets.only(bottom: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: cs.outlineVariant),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
                        leading: CircleAvatar(
                          backgroundColor: AppColors.accentOf(context).withAlpha(40),
                          child: Icon(fl.isGateway ? Icons.cell_tower : Icons.sensors,
                              color: AppColors.accentOf(context)),
                        ),
                        title: Text(d.name),
                        subtitle: Text(
                          [
                            d.address,
                            if (d.version.isNotEmpty) d.version,
                            if (d.detail.isNotEmpty) d.detail,
                          ].join(' · '),
                          style: const TextStyle(fontFamily: monoFont, fontSize: 12.5),
                        ),
                        onTap: () => _open(d),
                        trailing: PopupMenuButton<String>(
                          onSelected: (a) => _menu(d, a),
                          itemBuilder: (_) => [
                            const PopupMenuItem(value: 'rename', child: Text('Renomear')),
                            if (d.remember) const PopupMenuItem(value: 'forget', child: Text('Esquecer senha')),
                            const PopupMenuItem(value: 'remove', child: Text('Remover da lista')),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      OutlinedButton.icon(
                          onPressed: _addByIp, icon: const Icon(Icons.edit_location_alt), label: const Text('Adicionar por IP')),
                      OutlinedButton.icon(
                          onPressed: _softAp, icon: const Icon(Icons.wifi_tethering), label: const Text('Soft AP')),
                    ],
                  ),
                  DevFooter(fl.appTitle),
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _scan,
        icon: const Icon(Icons.radar),
        label: const Text('Procurar'),
      ),
    );
  }
}

// ------------------------------ busca ------------------------------
class _ScanSheet extends StatefulWidget {
  const _ScanSheet({required this.flavor});

  final AppFlavor flavor;

  @override
  State<_ScanSheet> createState() => _ScanSheetState();
}

class _ScanSheetState extends State<_ScanSheet> {
  late final DeviceScanner _scanner;
  final List<FoundDevice> _found = [];
  ScanProgress? _progress;
  bool _done = false;
  StreamSubscription<FoundDevice>? _s1;
  StreamSubscription<ScanProgress>? _s2;

  @override
  void initState() {
    super.initState();
    _scanner = DeviceScanner(accept: widget.flavor.acceptsInfo);
    _s1 = _scanner.found.listen((f) {
      if (mounted) setState(() => _found.add(f));
    });
    _s2 = _scanner.progress.listen((p) {
      if (mounted) setState(() => _progress = p);
    });
    _scanner.run().whenComplete(() {
      if (mounted) setState(() => _done = true);
    });
  }

  @override
  void dispose() {
    _s1?.cancel();
    _s2?.cancel();
    _scanner.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _progress;
    final frac = (p == null || p.total == 0) ? null : p.done / p.total;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_done ? 'Busca concluída' : 'Procurando na rede…',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              _done
                  ? '${_found.length} encontrado(s).'
                  : 'mDNS e varredura da sub-rede (GET /info em cada endereço)'
                      '${p == null ? '' : ' · ${p.done}/${p.total}'}',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 10),
            if (!_done) LinearProgressIndicator(value: frac),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .5),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final f in _found)
                    ListTile(
                      leading: Icon(widget.flavor.isGateway ? Icons.cell_tower : Icons.sensors),
                      title: Text(f.name),
                      subtitle: Text(
                        '${f.host}${f.mdnsHost.isNotEmpty ? ' · ${f.mdnsHost}.local' : ''} · ${f.info['version'] ?? ''} · via ${f.source}',
                        style: const TextStyle(fontFamily: monoFont, fontSize: 12),
                      ),
                      onTap: () => Navigator.pop(context, f),
                    ),
                  if (_done && _found.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Nada encontrado. Confira se o celular está na mesma rede Wi-Fi, '
                          'se o firmware tem o endereço /info (versão nova) ou use "Adicionar por IP".'),
                    ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(_done ? 'Fechar' : 'Parar'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
