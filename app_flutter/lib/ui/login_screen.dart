// Tela de login: o mesmo usuário/senha da página web (HTTP Basic).
import 'package:flutter/material.dart';

import '../core/app_host.dart';
import '../core/device_api.dart';
import '../core/flavor.dart';
import '../core/format.dart';
import '../core/session.dart';
import '../core/storage.dart';
import '../core/wifi_helper.dart';
import 'theme.dart';
import 'widgets.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.device});

  final SavedDevice device;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final TextEditingController _addr;
  late final TextEditingController _user;
  late final TextEditingController _pass;
  bool _remember = false;
  bool _busy = false;
  String? _error;

  AppFlavor get fl => appHost.flavor;

  @override
  void initState() {
    super.initState();
    final d = widget.device;
    _addr = TextEditingController(text: d.address);
    _user = TextEditingController(text: d.user.isEmpty ? AppFlavor.defaultUser : d.user);
    _pass = TextEditingController(text: d.remember ? (d.password ?? '') : '');
    _remember = d.remember;
  }

  @override
  void dispose() {
    _addr.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  (String, int)? _parseAddr() {
    var a = _addr.text.trim();
    a = a.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '');
    a = a.replaceAll(RegExp(r'/.*$'), '');
    if (a.isEmpty) return null;
    var port = 80;
    final m = RegExp(r'^(.+):(\d{1,5})$').firstMatch(a);
    if (m != null) {
      a = m.group(1)!;
      port = int.parse(m.group(2)!);
      if (port < 1 || port > 65535) return null;
    }
    if (!RegExp(r'^[A-Za-z0-9.\-]+$').hasMatch(a)) return null;
    return (a, port);
  }

  Future<void> _login() async {
    final hp = _parseAddr();
    if (hp == null) {
      setState(() => _error = 'Endereço inválido. Use o IP (ex.: 192.168.18.101) ou o nome .local.');
      return;
    }
    if (_user.text.trim().isEmpty || _pass.text.isEmpty) {
      setState(() => _error = 'Informe usuário e senha.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await WifiHelper.bindToWifi();
    final api = DeviceApi(host: hp.$1, port: hp.$2, user: _user.text.trim(), password: _pass.text);
    try {
      final cfg = await api.getJson('/config.json');
      final wrong = fl.checkConfig(cfg);
      if (wrong != null) {
        api.close();
        setState(() {
          _busy = false;
          _error = wrong;
        });
        return;
      }
      final d = widget.device
        ..host = hp.$1
        ..port = hp.$2
        ..user = _user.text.trim()
        ..password = _pass.text
        ..remember = _remember
        ..lastSeen = DateTime.now();
      _describe(d, cfg);
      final saved = await DeviceStore.instance.upsert(d);
      saved.password = _pass.text;
      if (!mounted) {
        api.close();
        return;
      }
      final session = DeviceSession(api: api, device: saved, config: cfg);
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => appHost.shellBuilder(session)),
      );
    } on ApiException catch (e) {
      api.close();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.unauthorized
            ? 'Usuário ou senha incorretos. O padrão de fábrica é '
                '${AppFlavor.defaultUser} / ${AppFlavor.defaultPassword}.'
            : e.message;
      });
    } catch (e) {
      api.close();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Resposta inesperada do dispositivo: $e';
      });
    }
  }

  /// Nome e detalhes mostrados na lista, a partir do config.json.
  void _describe(SavedDevice d, Map<String, dynamic> cfg) {
    if (fl.isGateway) {
      final id = sv(cfg['gw_id']);
      if (d.name.isEmpty || d.name.startsWith('Gateway') || d.name == d.host) {
        d.name = id.isEmpty ? 'Gateway ESP32 SX1302' : 'Gateway $id';
      }
      d.version = sv(cfg['_version']);
      d.detail = sv(cfg['_board']).isNotEmpty ? sv(cfg['_board']) : sv(cfg['_target']);
      d.apSsid = fl.defaultApSsid;
    } else {
      final n = sv(cfg['name']);
      if (n.isNotEmpty) d.name = n;
      d.version = sv(cfg['_fw']);
      d.detail = sv(cfg['_board_name']).isNotEmpty ? sv(cfg['_board_name']) : sv(cfg['_chip']);
      final ap = sv(cfg['ap_ssid']);
      d.apSsid = ap.isNotEmpty ? ap : n;
      d.mdnsHost = hostSlug(n);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Entrar · ${widget.device.name}')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Icon(fl.isGateway ? Icons.cell_tower : Icons.sensors,
                    size: 56, color: AppColors.accentOf(context)),
                const SizedBox(height: 10),
                Text(fl.appTitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text('Mesmo usuário e senha da página web ${fl.isGateway ? 'do gateway' : 'do nó'}.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                const SizedBox(height: 22),
                ErrorBox(_error == null ? const [] : [_error!]),
                TextFieldX(
                  controller: _addr,
                  label: 'Endereço',
                  hint: '192.168.18.101',
                  mono: true,
                  keyboard: TextInputType.url,
                ),
                TextFieldX(controller: _user, label: 'Usuário', maxLength: 31),
                TextFieldX(controller: _pass, label: 'Senha', password: true, maxLength: 31),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _remember,
                  onChanged: (v) => setState(() => _remember = v),
                  title: const Text('Lembrar a senha neste celular'),
                  subtitle: const Text('Guardada criptografada (Android Keystore).'),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _busy ? null : _login,
                  icon: _busy
                      ? const SizedBox(
                          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.login),
                  label: Text(_busy ? 'Conectando…' : 'Entrar'),
                ),
                const SizedBox(height: 14),
                Hint(
                  'Esqueceu a senha? No console serial: web_auth --reset '
                  '(volta para ${AppFlavor.defaultUser} / ${AppFlavor.defaultPassword}).',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
