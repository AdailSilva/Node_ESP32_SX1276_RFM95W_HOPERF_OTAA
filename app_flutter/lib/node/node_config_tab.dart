// Aba Configuração do nó: o mesmo formulário da página (POST /save).
// LoRaWAN, rádio, uplink, reset remoto e login valem ao salvar;
// Wi-Fi, inicialização e hardware depois de reiniciar.
import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/device_api.dart';
import '../core/format.dart';
import '../core/html_text.dart';
import '../core/session.dart';
import '../ui/widgets.dart';
import 'node_logic.dart';

class NodeConfigTab extends StatefulWidget {
  const NodeConfigTab({super.key, required this.session, required this.onReboot});

  final DeviceSession session;
  final Future<void> Function({bool ask}) onReboot;

  @override
  State<NodeConfigTab> createState() => NodeConfigTabState();
}

class NodeConfigTabState extends State<NodeConfigTab> {
  static const _textNames = [
    'name', 'wifi_ssid', 'wifi_pswd', 'ip_addr', 'ip_mask', 'ip_gw', 'ip_dns1', 'ip_dns2',
    'ap_ssid', 'ap_pswd', 'sta_to', 'boot_pin', 'web_user', 'web_pswd',
    'dev_eui', 'join_eui', 'app_key', 'dev_addr', 'net_id', 'nwk_skey', 'app_skey', 'rx1_delay',
    'ch_list', 'rx2_freq', 'tx_int', 'fport', 'payload', 'rst_port', 'rst_delay', 'rst_cmd',
    'pin_sclk', 'pin_miso', 'pin_mosi', 'pin_nss', 'pin_rst', 'pin_dio0', 'pin_dio1', 'pin_dio2',
    'spi_freq',
  ];
  static const _radioValues = {
    'wifi_mode': ['sta', 'ap', 'off'],
    'ip_mode': ['dhcp', 'static'],
    'eui_rev': ['off', 'on'],
    'ch500': ['on', 'off'],
    'adr': ['off', 'on'],
    'link_chk': ['off', 'on'],
    'confirmed': ['off', 'on'],
    'pl_fmt': ['text', 'hex'],
    'rst_en': ['on', 'off'],
    'verbose': ['on', 'off'],
  };
  static const _selectNames = ['sub_band', 'dr', 'tx_pow', 'rx2_dr', 'clk_err', 'ap_ch', 'baud'];
  static const _secret = {'wifi_pswd', 'ap_pswd', 'web_pswd'};

  final Map<String, TextEditingController> _c = {};
  final TextEditingController _webPass2 = TextEditingController();
  final Map<String, String?> _r = {};
  final Map<String, int?> _sel = {};
  final Map<String, GlobalKey> _sec = {
    for (final k in ['act', 'radio', 'upl', 'rst', 'wifi', 'boot', 'hw', 'acc']) k: GlobalKey(),
  };
  bool _wifiPassSet = false;
  bool _apPassSet = false;
  bool _dirty = false;
  bool _saving = false;
  bool _filling = false;
  bool _customCh = false;
  List<String> _errors = [];
  Set<String> _bad = {};
  final ScrollController _scroll = ScrollController();

  DeviceSession get s => widget.session;
  DeviceApi get api => s.api;
  Map<String, dynamic> get cfg => s.config;
  bool get otaa => cfg['_mode'] == 'otaa';
  bool get dirty => _dirty;

  @override
  void initState() {
    super.initState();
    for (final n in _textNames) {
      _c[n] = TextEditingController()..addListener(_onText);
    }
    _webPass2.addListener(_onText);
    _fill(cfg, fromImport: false);
    _dirty = false;
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    _webPass2.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onText() {
    if (_filling) return;
    setState(() => _dirty = true);
  }

  String t(String n) => _c[n]!.text;

  /// fill() da página: rádio/select/texto conforme o nome; senhas nunca vêm.
  int _fill(Map<String, dynamic> j, {required bool fromImport}) {
    var n = 0;
    _filling = true;
    j.forEach((k, v) {
      if (k.startsWith('_')) return;
      final val = v == null ? '' : '$v';
      if (_radioValues.containsKey(k)) {
        if (_radioValues[k]!.contains(val)) {
          _r[k] = val;
          n++;
        }
      } else if (_selectNames.contains(k)) {
        final x = int.tryParse(val);
        if (x != null) {
          _sel[k] = x;
          n++;
        }
      } else if (_c.containsKey(k) && !_secret.contains(k)) {
        _c[k]!.text = val;
        n++;
      }
    });
    if (!fromImport) {
      for (final p in _secret) {
        _c[p]!.text = '';
      }
      _webPass2.text = '';
      _wifiPassSet = j['wifi_pswd_set'] == true;
      _apPassSet = j['ap_pswd_set'] == true;
    }
    if (t('ch_list').trim().isNotEmpty) _customCh = true;
    _filling = false;
    return n;
  }

  /// "Importar…" da Manutenção.
  int importJson(Map<String, dynamic> j) {
    final n = _fill(j, fromImport: true);
    setState(() => _dirty = true);
    return n;
  }

  void _radio(String k, String v) => setState(() {
        _r[k] = v;
        _dirty = true;
      });

  void _select(String k, int v) => setState(() {
        _sel[k] = v;
        _dirty = true;
      });

  // ------------------------------- auxiliares -------------------------------
  int _plBytes() {
    final v = t('payload');
    if (_r['pl_fmt'] == 'hex') {
      final b = hexb(v);
      return b == null ? -1 : b.length;
    }
    return utf8Len(v);
  }

  Set<int>? get _chans => channels(t('ch_list'), _sel['sub_band'] ?? 0, _r['ch500'] == 'on');

  void _rev(String name) {
    final b = hexb(t(name));
    if (b == null) {
      snack(context, 'Valor hexadecimal inválido.');
      return;
    }
    _c[name]!.text = hx(b.reversed.toList());
  }

  void _macEui() {
    final m = '${cfg['_mac'] ?? ''}'.split(':');
    if (m.length != 6) return;
    _c['dev_eui']!.text = '${m.sublist(0, 3).join()}FFFE${m.sublist(3).join()}'.toUpperCase();
  }

  // ------------------------------ validação ------------------------------
  List<String> _check() {
    final e = <String>[];
    final bad = <String>{};
    void key(String n, int len, String label) {
      final b = hexb(t(n));
      if (b == null || b.length != len) {
        e.add('$label: exatamente $len bytes (${len * 2} caracteres hexadecimais).');
        bad.add(n);
      } else {
        _c[n]!.text = hx(b);
      }
    }

    void numChk(String n, int lo, int hi, String label, {bool opt = false}) {
      final v = t(n).trim();
      _c[n]!.text = v;
      if (v.isEmpty && opt) return;
      final x = int.tryParse(v);
      if (!RegExp(r'^-?\d+$').hasMatch(v) || x == null || x < lo || x > hi) {
        e.add('$label: número entre $lo e $hi.');
        bad.add(n);
      }
    }

    if (t('name').trim().isEmpty) e.add('Nome do nó: obrigatório.');
    if (otaa) {
      key('dev_eui', 8, 'DevEUI');
      key('join_eui', 8, 'JoinEUI');
      key('app_key', 16, 'AppKey');
    } else {
      key('dev_addr', 4, 'DevAddr');
      key('nwk_skey', 16, 'NwkSKey');
      key('app_skey', 16, 'AppSKey');
      key('net_id', 3, 'NetID');
      numChk('rx1_delay', 1, 15, 'Atraso RX1');
      if (t('dev_eui').trim().isNotEmpty) key('dev_eui', 8, 'DevEUI (referência)');
    }
    if (_chans == null) e.add('Canais personalizados: use números de 0 a 71, ex.: 8-15,65.');
    numChk('rx2_freq', 100000000, 999999999, 'Frequência RX2', opt: true);
    numChk('tx_int', 5, 86400, 'Intervalo');
    numChk('fport', 1, 223, 'FPort do uplink');
    final pl = _plBytes();
    if (pl < 1) {
      e.add('Payload: ${pl < 0 ? 'hexadecimal inválido.' : 'não pode ficar vazio.'}');
    } else if (pl > 222) {
      e.add('Payload: máximo de 222 bytes.');
    }
    numChk('rst_port', 1, 223, 'FPort do reset');
    numChk('rst_delay', 0, 60000, 'Espera antes do reset');
    final rc = hexb(t('rst_cmd'));
    if (rc == null || rc.isEmpty || rc.length > 16) e.add('Comando de reset: 1 a 16 bytes em hexadecimal.');
    var v = t('wifi_pswd');
    if (v.isNotEmpty && v.length < 8) e.add('Senha do Wi-Fi: mínimo de 8 caracteres.');
    v = t('ap_pswd');
    if (v.isNotEmpty && v.length < 8) e.add('Senha do Soft AP: mínimo de 8 caracteres.');
    if (_r['ip_mode'] == 'static') {
      e.addAll(validateStaticIp(t, (n, val) => _c[n]!.text = val));
    }
    if (_r['wifi_mode'] == 'sta' && t('wifi_ssid').trim().isEmpty) {
      e.add('Modo Station: informe o nome da rede Wi-Fi (ou escolha Soft AP).');
    }
    numChk('sta_to', 5, 3600, 'Espera pelo Wi-Fi');
    numChk('boot_pin', -1, 48, 'Botão de configuração');
    final used = <int, String>{};
    final classic = classicEsp32('${cfg['_chip'] ?? ''}');
    // Pin rules of the board, sent by the firmware (main/node_board.h):
    // _pins_rsv = {GPIO: reason}, _pins_in = input-only GPIOs, _pin_max.
    // Older firmware without them -> the classic ESP32 rules below.
    final rsv = cfg['_pins_rsv'] is Map ? Map<String, dynamic>.from(cfg['_pins_rsv'] as Map) : null;
    final inOnly = cfg['_pins_in'] is List ? (cfg['_pins_in'] as List).map((x) => '$x').toSet() : <String>{};
    final pinMax = cfg['_pin_max'] is int ? cfg['_pin_max'] as int : 48;
    final boardName = '${cfg['_board_name'] ?? cfg['_chip'] ?? 'ESP32'}';
    const pins = [
      ['pin_sclk', 'SCLK', false, true],
      ['pin_miso', 'MISO', false, false],
      ['pin_mosi', 'MOSI', false, true],
      ['pin_nss', 'NSS', false, true],
      ['pin_rst', 'RESET', true, true],
      ['pin_dio0', 'DIO0', false, false],
      ['pin_dio1', 'DIO1', true, false],
      ['pin_dio2', 'DIO2', true, false],
    ];
    for (final p in pins) {
      final n = p[0] as String, label = p[1] as String, optional = p[2] as bool, output = p[3] as bool;
      final pv = t(n).trim();
      _c[n]!.text = pv;
      final x = int.tryParse(pv);
      if (!RegExp(r'^-?\d+$').hasMatch(pv) || x == null || x < (optional ? -1 : 0) || x > pinMax) {
        e.add('Pino $label: GPIO de ${optional ? '-1' : '0'} a $pinMax.');
        bad.add(n);
        continue;
      }
      if (x < 0) continue;
      if (used.containsKey(x)) e.add('Pino $label: GPIO $x já usado em ${used[x]}.');
      used[x] = label;
      if (rsv != null) {
        if (rsv.containsKey('$x')) {
          e.add('Pino $label: GPIO $x não pode ser usado no $boardName (${rsv['$x']}).');
        } else if (output && inOnly.contains('$x')) {
          e.add('Pino $label: GPIO $x é só entrada no $boardName.');
        }
      } else if (classic) {
        if (output && x >= 34) e.add('Pino $label: GPIO $x é só entrada no ESP32.');
        if (x >= 6 && x <= 11) e.add('Pino $label: GPIO 6–11 são da memória flash.');
      }
    }
    numChk('spi_freq', 0, 10000000, 'Clock SPI');
    v = t('web_user').trim();
    if (v.isEmpty || v.length > 31 || v.contains(':') || v == '_logout_') {
      e.add('Usuário da página: 1 a 31 caracteres, sem dois-pontos.');
    }
    v = t('web_pswd');
    if (v.isNotEmpty && (v.length < 6 || v.contains(':'))) {
      e.add('Nova senha da página: mínimo de 6 caracteres, sem dois-pontos.');
    }
    if (v != _webPass2.text) e.add('Nova senha da página: a confirmação não confere.');
    _bad = bad;
    return e;
  }

  // -------------------------------- salvar --------------------------------
  Map<String, String> _fields() {
    final f = <String, String>{};
    const common = [
      'name', 'wifi_ssid', 'wifi_pswd', 'ip_addr', 'ip_mask', 'ip_gw', 'ip_dns1', 'ip_dns2',
      'ap_ssid', 'ap_pswd', 'sta_to', 'boot_pin', 'web_user', 'web_pswd',
      'ch_list', 'rx2_freq', 'tx_int', 'fport', 'payload', 'rst_port', 'rst_delay', 'rst_cmd',
      'pin_sclk', 'pin_miso', 'pin_mosi', 'pin_nss', 'pin_rst', 'pin_dio0', 'pin_dio1', 'pin_dio2',
      'spi_freq', 'dev_eui',
    ];
    for (final n in common) {
      f[n] = _secret.contains(n) || n == 'payload' ? t(n) : t(n).trim();
    }
    // os campos do outro modo ficam desativados na página e não são enviados
    final modeFields = otaa ? ['join_eui', 'app_key'] : ['dev_addr', 'net_id', 'nwk_skey', 'app_skey', 'rx1_delay'];
    for (final n in modeFields) {
      f[n] = t(n).trim();
    }
    _r.forEach((k, v) {
      if (v == null) return;
      if (k == 'eui_rev' && !otaa) return;
      f[k] = v;
    });
    _sel.forEach((k, v) {
      if (v != null) f[k] = '$v';
    });
    return f;
  }

  Future<void> save() async {
    FocusScope.of(context).unfocus();
    final e = _check();
    setState(() => _errors = e);
    if (e.isNotEmpty) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      return;
    }
    final newUser = t('web_user').trim();
    final newPass = t('web_pswd').isNotEmpty ? t('web_pswd') : api.password;
    final loginChanged = newUser != api.user || newPass != api.password;
    setState(() => _saving = true);
    try {
      final r = await api.postForm('/save', _fields());
      final page = parseSimplePage(r.text);
      if (page.isError) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          _errors = page.paragraphs.where((p) => !p.startsWith('Corrija')).expand((p) => p.split('\n')).toList();
        });
        _scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
        messageDialog(context, page.title, page.body);
        return;
      }
      if (loginChanged) await s.updateCredentials(newUser, newPass);
      try {
        await s.reloadConfig();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _fill(s.config, fromImport: false);
        _dirty = false;
        _saving = false;
        _errors = [];
      });
      s.refreshStatus();
      final body = [
        if (page.body.isNotEmpty) page.body else 'Configuração enviada.',
        if (loginChanged) 'O app já passou a usar o novo login.',
      ].join('\n\n');
      await messageDialog(
        context,
        page.title.isEmpty ? 'Configuração salva' : page.title,
        body,
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Voltar')),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              widget.onReboot(ask: false);
            },
            child: const Text('Reiniciar agora'),
          ),
        ],
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      // login recusado: a tela principal já avisa e volta para a lista
      if (e.unauthorized) return;
      messageDialog(context, 'Não foi possível salvar', e.message);
    }
  }

  void _jump(String key) {
    final ctx = _sec[key]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), alignment: 0.02);
    }
  }

  // --------------------------------- telas ---------------------------------
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
            children: [
              _jumpBar(),
              const SizedBox(height: 8),
              const Hint(
                  'LoRaWAN, rádio, uplink e reset remoto valem assim que você salva. Wi-Fi, inicialização e '
                  'hardware valem depois de reiniciar.',
                  top: 0),
              const SizedBox(height: 10),
              ErrorBox(_errors),
              _activation(),
              _radioSec(),
              _uplink(),
              _reset(),
              _wifi(),
              _boot(),
              _hw(),
              _access(),
              DevFooter(t('name').trim().isEmpty ? 'LoRaWAN Node' : t('name').trim()),
            ],
          ),
        ),
        SaveBar(
          dirty: _dirty,
          saving: _saving,
          onSave: save,
          onReboot: () => widget.onReboot(ask: true),
          rebootLabel: 'Reiniciar',
        ),
      ],
    );
  }

  Widget _jumpBar() {
    final items = [
      ['act', 'Ativação ${otaa ? 'OTAA' : 'ABP'}'],
      ['radio', 'Rádio LoRa'],
      ['upl', 'Uplink'],
      ['rst', 'Reset remoto'],
      ['wifi', 'Rede Wi-Fi'],
      ['boot', 'Inicialização'],
      ['hw', 'Hardware'],
      ['acc', 'Acesso'],
    ];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final i in items) ActionChip(label: Text(i[1]), onPressed: () => _jump(i[0])),
      ],
    );
  }

  TextFieldX _key(String n, String label, int bytes, {List<Widget>? trailing, String? helper}) => TextFieldX(
        controller: _c[n]!,
        label: label,
        mono: true,
        maxLength: bytes * 3 - 1,
        helper: _bad.contains(n) ? 'Valor inválido${helper == null ? '' : '. $helper'}' : helper,
        invalid: _bad.contains(n),
        // chaves de 16 bytes (47 caracteres) e EUIs com botões ao lado não cabem numa linha
        // do celular: quebram em vez de esconder o começo do valor
        wrap: bytes >= 8,
        // todo campo em hexadecimal tem Copiar (sem espaços, como no ChirpStack)
        trailing: [...?trailing, CopyHexButton(value: () => t(n), name: label.split(' ').first)],
      );

  Widget _activation() {
    final de = hexb(t('dev_eui')), je = hexb(t('join_eui'));
    final rv = _r['eui_rev'] == 'on';
    var euih = '';
    if (de != null && de.length == 8) {
      euih = 'O ChirpStack vai receber DevEUI ${hx(rv ? de : de.reversed.toList())}'
          '${je != null && je.length == 8 ? ' e JoinEUI ${hx(rv ? je : je.reversed.toList())}' : ''}'
          ' — cadastre o dispositivo com esses valores.';
    }
    return SectionCard(
      key: _sec['act'],
      title: 'Ativação ${otaa ? 'OTAA' : 'ABP'}',
      subtitle: otaa
          ? 'O nó faz o JOIN e recebe as chaves de sessão do servidor. Cadastre no ChirpStack os mesmos '
              'DevEUI, JoinEUI e AppKey.'
          : 'Sessão pré-provisionada: sem JOIN, o nó transmite logo ao ligar. Copie os valores de '
              'ChirpStack → Devices → Activation.',
      tag: 'aplica na hora',
      children: otaa
          ? [
              _key('dev_eui', 'DevEUI (8 bytes, MSB)', 8,
                  helper: 'Digite como o ChirpStack mostra (MSB). Abaixo aparece o valor que o servidor vai receber.',
                  trailing: [
                    IconButton(
                        tooltip: 'Inverter (LSB ↔ MSB)',
                        onPressed: () => _rev('dev_eui'),
                        icon: const Icon(Icons.swap_horiz)),
                    IconButton(
                        tooltip: 'Gerar a partir do MAC deste ESP32',
                        onPressed: _macEui,
                        icon: const Icon(Icons.memory)),
                  ]),
              _key('join_eui', 'JoinEUI / AppEUI (8 bytes, MSB)', 8, trailing: [
                IconButton(
                    tooltip: 'Inverter (LSB ↔ MSB)',
                    onPressed: () => _rev('join_eui'),
                    icon: const Icon(Icons.swap_horiz)),
              ]),
              _key('app_key', 'AppKey (16 bytes, MSB)', 16,
                  helper: 'Mudar DevEUI, JoinEUI, AppKey ou os canais refaz o JOIN ao salvar.'),
              SegChoice(
                label: 'Ordem dos bytes do DevEUI/JoinEUI no ar',
                options: const [
                  SegOption('off', 'Como digitado',
                      'Como no firmware original: os bytes vão ao LMiC na ordem digitada. O servidor recebe o EUI invertido.'),
                  SegOption('on', 'Invertida (LSB)',
                      'Padrão MCCI LMiC (LSB first): o servidor recebe exatamente o EUI digitado acima.'),
                ],
                value: _r['eui_rev'],
                onChanged: (v) => _radio('eui_rev', v),
              ),
              Hint(euih, top: 0),
              if (euih.isNotEmpty)
                Wrap(spacing: 4, children: [
                  TextButton.icon(
                    onPressed: () => copyHex(context, hx(rv ? de! : de!.reversed.toList()), 'DevEUI (servidor)'),
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copiar DevEUI'),
                  ),
                  if (je != null && je.length == 8)
                    TextButton.icon(
                      onPressed: () => copyHex(context, hx(rv ? je : je.reversed.toList()), 'JoinEUI (servidor)'),
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Copiar JoinEUI'),
                    ),
                ]),
            ]
          : [
              Pair(
                _key('dev_addr', 'DevAddr (4 bytes)', 4),
                TextFieldX(
                  controller: _c['net_id']!,
                  label: 'NetID',
                  mono: true,
                  maxLength: 8,
                  helper: '000000 ChirpStack · 000013 TTN',
                  trailing: [
                    CopyHexButton(value: () => t('net_id'), name: 'NetID'),
                    PopupMenuButton<String>(
                      tooltip: 'Sugestões',
                      icon: const Icon(Icons.arrow_drop_down),
                      onSelected: (v) => _c['net_id']!.text = v,
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: '000000', child: Text('000000 · ChirpStack')),
                        PopupMenuItem(value: '000013', child: Text('000013 · The Things Network')),
                      ],
                    ),
                  ],
                ),
              ),
              _key('nwk_skey', 'NwkSKey — Network Session Key (16 bytes, MSB)', 16),
              _key('app_skey', 'AppSKey — Application Session Key (16 bytes, MSB)', 16),
              Pair(
                TextFieldX(
                  controller: _c['rx1_delay']!,
                  label: 'Atraso da janela RX1 (s)',
                  mono: true,
                  keyboard: TextInputType.number,
                  helper: 'Igual ao RX1 delay do perfil no ChirpStack (padrão 1 s).',
                ),
                _key('dev_eui', 'DevEUI (referência)', 8, helper: 'Não é usado no ABP; fica guardado só para o cadastro.'),
              ),
              const Hint('Mudar o DevAddr zera o FCnt (dispositivo novo). Mudar só as chaves mantém o FCnt.', top: 0),
            ],
    );
  }

  Widget _radioSec() {
    final m = _chans;
    Widget band;
    if (m == null) {
      band = const StatusBanner('Lista de canais inválida.', level: Level.warn);
    } else {
      final n125 = m.where((c) => c < 64).length, n500 = m.where((c) => c >= 64).length;
      band = BandChart(
        on: m,
        caption: 'Transmitindo em $n125 canal(is) de 125 kHz${n500 > 0 ? ' e $n500 de 500 kHz' : ''} na faixa AU915.',
      );
    }
    return SectionCard(
      key: _sec['radio'],
      title: 'Rádio LoRa',
      subtitle: 'Canais de uplink, data rate e potência. Use os mesmos canais que o gateway escuta.',
      tag: 'aplica na hora',
      children: [
        DropField<int>(
          label: 'Sub-banda (canais de 125 kHz) · no Brasil, SB1',
          items: subBandItems,
          value: _sel['sub_band'],
          onChanged: (v) => _select('sub_band', v),
        ),
        SegChoice(
          label: 'Canal de 500 kHz',
          options: const [SegOption('on', 'Ligado'), SegOption('off', 'Desligado')],
          value: _r['ch500'],
          onChanged: (v) => _radio('ch500', v),
          showHint: false,
        ),
        ExpansionTile(
          key: PageStorageKey('chl$_customCh'),
          initiallyExpanded: _customCh,
          tilePadding: EdgeInsets.zero,
          title: const Text('Canais personalizados', style: TextStyle(fontSize: 14)),
          children: [
            TextFieldX(
              controller: _c['ch_list']!,
              label: 'Lista de canais (0–71)',
              mono: true,
              hint: 'ex.: 8-15,65',
              helper: 'Preenchido, substitui a sub-banda. Vazio usa a sub-banda escolhida acima.',
            ),
          ],
        ),
        band,
        const Divider(height: 20),
        DropField<int>(label: 'Data rate de uplink', items: drItems, value: _sel['dr'], onChanged: (v) => _select('dr', v)),
        DropField<int>(
            label: 'Potência de transmissão (dBm)',
            items: txPowItems,
            value: _sel['tx_pow'],
            onChanged: (v) => _select('tx_pow', v)),
        SegChoice(
          label: 'ADR (Adaptive Data Rate)',
          options: const [
            SegOption('off', 'Desligado', 'Data rate e potência fixos (os escolhidos acima).'),
            SegOption('on', 'Ligado', 'O servidor ajusta data rate e potência. Os valores acima são só o ponto de partida.'),
          ],
          value: _r['adr'],
          onChanged: (v) => _radio('adr', v),
        ),
        SegChoice(
          label: 'Link check',
          options: const [
            SegOption('off', 'Desligado', 'Recomendado: não reduz o data rate sozinho.'),
            SegOption('on', 'Ligado',
                'Pede confirmação de link ao servidor; pode baixar o data rate e o tamanho do payload.'),
          ],
          value: _r['link_chk'],
          onChanged: (v) => _radio('link_chk', v),
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Janela RX2 e relógio', style: TextStyle(fontSize: 14)),
          children: [
            DropField<int>(
                label: 'Data rate RX2', items: rx2DrItems, value: _sel['rx2_dr'], onChanged: (v) => _select('rx2_dr', v)),
            TextFieldX(
                controller: _c['rx2_freq']!,
                label: 'Frequência RX2 (Hz)',
                mono: true,
                keyboard: TextInputType.number,
                hint: '923300000'),
            DropField<int>(
                label: 'Erro de relógio', items: clkItems, value: _sel['clk_err'], onChanged: (v) => _select('clk_err', v)),
            const Hint(
                'Padrão AU915/ChirpStack: RX2 em 923,3 MHz com DR8 (SF12/BW500). Frequência vazia usa o padrão da '
                'região. O erro de relógio alarga a janela de recepção; aumente se o nó perder downlinks.',
                top: 0),
            const SizedBox(height: 8),
          ],
        ),
      ],
    );
  }

  Widget _uplink() {
    final hex = _r['pl_fmt'] == 'hex';
    final n = _plBytes();
    final dr = (_sel['dr'] ?? 0).clamp(0, 6);
    final mx = nodeDr[dr][2];
    final iv = int.tryParse(t('tx_int').trim()) ?? 0;
    String bytesHint;
    if (n < 0) {
      bytesHint = 'Hexadecimal inválido.';
    } else {
      bytesHint = '$n byte(s) · máximo em DR$dr: $mx bytes${n > mx ? ' — grande demais para este data rate' : ''}';
    }
    var calc = '';
    if (n > 0) {
      final toa = timeOnAir(dr, n + 13);
      calc = 'Tempo no ar por uplink ≈ ${dec(toa, 1)} ms (SF${nodeDr[dr][0]}/BW${nodeDr[dr][1]}, ${n + 13} bytes PHY)'
          '${iv > 0 ? ' · ocupação ≈ ${dec(100 * toa / (iv * 1000), 2)} % do tempo' : ''}'
          '${_r['adr'] == 'on' ? '. Com ADR, o servidor pode mudar o data rate.' : '.'}';
    }
    return SectionCard(
      key: _sec['upl'],
      title: 'Uplink',
      subtitle: 'O que o nó envia e com que frequência.',
      tag: 'aplica na hora',
      children: [
        Pair(
          TextFieldX(controller: _c['tx_int']!, label: 'Intervalo (s)', mono: true, keyboard: TextInputType.number),
          TextFieldX(controller: _c['fport']!, label: 'FPort', mono: true, keyboard: TextInputType.number),
        ),
        SegChoice(
          label: 'Confirmação (ACK)',
          options: const [SegOption('off', 'Não'), SegOption('on', 'Sim')],
          value: _r['confirmed'],
          onChanged: (v) => _radio('confirmed', v),
          showHint: false,
        ),
        SegChoice(
          label: 'Payload',
          options: const [SegOption('text', 'Texto'), SegOption('hex', 'Hexadecimal')],
          value: _r['pl_fmt'],
          onChanged: (v) => _radio('pl_fmt', v),
          showHint: false,
        ),
        TextFieldX(
          controller: _c['payload']!,
          label: hex ? 'Conteúdo (bytes em hexadecimal)' : 'Conteúdo (texto)',
          mono: true,
          wrap: true,
          hint: hex ? '41 64 61 69 6C' : 'texto do payload',
          helper: bytesHint,
          invalid: n < 0 || n > mx,
          trailing: [CopyHexButton(value: () => t('payload'), name: 'Payload', hex: hex)],
        ),
        Hint(calc, top: 0),
      ],
    );
  }

  Widget _reset() {
    final rc = hexb(t('rst_cmd'));
    final hint = rc != null && rc.isNotEmpty
        ? 'Para enfileirar no ChirpStack: FPort ${t('rst_port').isEmpty ? '-' : t('rst_port')}, hex ${hx(rc)}, '
            'base64 ${base64Encode(rc)}'
        : 'Ex.: AD A1 DE AD BE EF 0D 0A';
    return SectionCard(
      key: _sec['rst'],
      title: 'Reset remoto',
      subtitle: 'Reinicia o ESP32 quando chega um downlink com exatamente este conteúdo nesta FPort.',
      tag: 'aplica na hora',
      children: [
        SegChoice(
          label: 'Comando de reset por downlink',
          options: const [SegOption('on', 'Ativado'), SegOption('off', 'Desativado')],
          value: _r['rst_en'],
          onChanged: (v) => _radio('rst_en', v),
          showHint: false,
        ),
        Pair(
          TextFieldX(controller: _c['rst_port']!, label: 'FPort', mono: true, keyboard: TextInputType.number),
          TextFieldX(
              controller: _c['rst_delay']!,
              label: 'Espera antes de reiniciar (ms)',
              mono: true,
              keyboard: TextInputType.number),
        ),
        TextFieldX(
            controller: _c['rst_cmd']!,
            label: 'Comando (1 a 16 bytes em hexadecimal)',
            mono: true,
            wrap: true,
            helper: hint,
            trailing: [CopyHexButton(value: () => t('rst_cmd'), name: 'Comando de reset')]),
        if (rc != null && rc.isNotEmpty)
          Wrap(spacing: 4, children: [
            TextButton.icon(
              onPressed: () => copyHex(context, hx(rc), 'Comando (hex)'),
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copiar hex'),
            ),
            TextButton.icon(
              onPressed: () => copyHex(context, base64Encode(rc), 'Comando (base64)', hex: false),
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copiar base64'),
            ),
          ]),
      ],
    );
  }

  Widget _wifi() {
    final isStatic = _r['ip_mode'] == 'static';
    final h = hostSlug(t('name'));
    return SectionCard(
      key: _sec['wifi'],
      title: 'Rede Wi-Fi',
      subtitle: 'Rede em que o nó se conecta para esta página e o app, e como ele recebe o endereço IP.',
      tag: 'vale após reiniciar',
      tagNow: false,
      children: [
        TextFieldX(
          controller: _c['name']!,
          label: 'Nome do nó',
          maxLength: 31,
          helper: 'Endereço na rede: http://$h.local/. Também é o nome padrão do Soft AP.',
        ),
        TextFieldX(controller: _c['wifi_ssid']!, label: 'Nome da rede (SSID)', maxLength: 32),
        TextFieldX(
          controller: _c['wifi_pswd']!,
          label: 'Senha',
          password: true,
          maxLength: 64,
          hint: _wifiPassSet ? 'Salva (vazio mantém)' : null,
        ),
        SegChoice(
          label: 'Endereço IP',
          options: const [
            SegOption('dhcp', 'Automático (DHCP)', 'O roteador entrega IP, gateway e DNS.'),
            SegOption('static', 'IP fixo',
                'Endereço, gateway e DNS definidos abaixo. Use um IP fora da faixa do DHCP do roteador.'),
          ],
          value: _r['ip_mode'],
          onChanged: (v) => _radio('ip_mode', v),
        ),
        if (isStatic) ...[
          Pair(
            TextFieldX(
                controller: _c['ip_addr']!,
                label: 'Endereço IP',
                mono: true,
                keyboard: const TextInputType.numberWithOptions(decimal: true)),
            TextFieldX(
                controller: _c['ip_mask']!,
                label: 'Máscara de rede',
                mono: true,
                hint: '255.255.255.0',
                keyboard: const TextInputType.numberWithOptions(decimal: true)),
          ),
          TextFieldX(
              controller: _c['ip_gw']!,
              label: 'Gateway (roteador)',
              mono: true,
              keyboard: const TextInputType.numberWithOptions(decimal: true)),
          Pair(
            TextFieldX(
                controller: _c['ip_dns1']!,
                label: 'DNS primário',
                mono: true,
                hint: t('ip_gw').trim().isEmpty ? 'igual ao gateway' : t('ip_gw').trim(),
                keyboard: const TextInputType.numberWithOptions(decimal: true)),
            TextFieldX(
                controller: _c['ip_dns2']!,
                label: 'DNS secundário (opcional)',
                mono: true,
                hint: '8.8.8.8',
                keyboard: const TextInputType.numberWithOptions(decimal: true)),
          ),
          const Hint('DNS primário vazio usa o gateway. Depois de reiniciar, abra o app no novo IP.', top: 0),
        ],
      ],
    );
  }

  Widget _boot() {
    return SectionCard(
      key: _sec['boot'],
      title: 'Inicialização',
      subtitle: 'Como o Wi-Fi sobe quando o nó liga, e o Soft AP de configuração.',
      tag: 'vale após reiniciar',
      tagNow: false,
      children: [
        OptionCards(
          items: const [
            OptionItem('sta', 'Station', 'Conecta na rede acima. Sem conexão, abre o Soft AP de emergência.'),
            OptionItem('ap', 'Soft AP', 'Cria a própria rede; página em 192.168.101.101.'),
            OptionItem('off', 'Desligado', 'Economiza energia. Para configurar, segure o botão do Soft AP por 3 s.'),
          ],
          value: _r['wifi_mode'],
          onChanged: (v) => _radio('wifi_mode', v),
        ),
        const SizedBox(height: 14),
        Pair(
          TextFieldX(
              controller: _c['ap_ssid']!,
              label: 'Nome do Soft AP',
              maxLength: 32,
              hint: t('name').isEmpty ? null : t('name')),
          TextFieldX(
            controller: _c['ap_pswd']!,
            label: 'Senha do Soft AP',
            password: true,
            maxLength: 64,
            hint: _apPassSet ? 'Salva (vazio mantém)' : null,
          ),
        ),
        DropField<int>(label: 'Canal do Soft AP', items: apChItems, value: _sel['ap_ch'], onChanged: (v) => _select('ap_ch', v)),
        Pair(
          TextFieldX(controller: _c['sta_to']!, label: 'Espera pelo Wi-Fi (s)', mono: true, keyboard: TextInputType.number),
          TextFieldX(
              controller: _c['boot_pin']!,
              label: 'Botão do Soft AP (GPIO)',
              mono: true,
              keyboard: const TextInputType.numberWithOptions(signed: true)),
        ),
        const Hint(
            'Com o nó ligado, segure o botão (nível baixo) por 3 s para abrir o Soft AP, mesmo com o Wi-Fi desligado. '
            'GPIO 0 é o botão BOOT das placas DevKit (não segure ao ligar: isso entra no modo de gravação). -1 '
            'desativa. No console serial, wifi_ap faz o mesmo.',
            top: 0),
      ],
    );
  }

  Widget _hw() {
    Widget pin(String n, String label) => TextFieldX(
          controller: _c[n]!,
          label: label,
          mono: true,
          keyboard: const TextInputType.numberWithOptions(signed: true),
          helper: _bad.contains(n) ? 'inválido' : null,
          invalid: _bad.contains(n),
        );
    return SectionCard(
      key: _sec['hw'],
      title: 'Hardware',
      subtitle: 'Ligação ESP32 ↔ RFM95W (SX1276) e console serial.',
      tag: 'vale após reiniciar',
      tagNow: false,
      children: [
        Pair(pin('pin_sclk', 'SCLK'), pin('pin_miso', 'MISO')),
        Pair(pin('pin_mosi', 'MOSI'), pin('pin_nss', 'NSS / CS')),
        Pair(pin('pin_rst', 'RESET'), pin('pin_dio0', 'DIO0')),
        Pair(pin('pin_dio1', 'DIO1'), pin('pin_dio2', 'DIO2')),
        Hint(
            '-1 = não conectado (só RESET, DIO1 e DIO2). '
            '${cfg['_pins_hint'] != null ? '${cfg['_board_name'] ?? ''}: ${cfg['_pins_hint']}' : 'GPIO 34–39 do ESP32 são só entrada: servem para DIO, nunca para SCLK, MOSI, NSS ou RESET.'}',
            top: 0),
        const Divider(height: 24),
        TextFieldX(
            controller: _c['spi_freq']!,
            label: 'Clock SPI (Hz)',
            mono: true,
            keyboard: TextInputType.number,
            helper: '0 = padrão do LMiC.'),
        DropField<int>(label: 'Velocidade da serial', items: baudItems, value: _sel['baud'], onChanged: (v) => _select('baud', v)),
        SegChoice(
          label: 'Diagnóstico de sessão',
          options: const [
            SegOption('on', 'Ligado', 'Chaves, frame e MIC a cada envio (aplica na hora).'),
            SegOption('off', 'Desligado', 'Chaves, frame e MIC a cada envio (aplica na hora).'),
          ],
          value: _r['verbose'],
          onChanged: (v) => _radio('verbose', v),
        ),
      ],
    );
  }

  Widget _access() {
    return SectionCard(
      key: _sec['acc'],
      title: 'Acesso',
      subtitle: 'Usuário e senha pedidos ao abrir a página e o app.',
      tag: 'aplica na hora',
      children: [
        TextFieldX(controller: _c['web_user']!, label: 'Usuário', maxLength: 31),
        Pair(
          TextFieldX(
              controller: _c['web_pswd']!,
              label: 'Nova senha',
              password: true,
              maxLength: 31,
              hint: 'vazio mantém a atual'),
          TextFieldX(controller: _webPass2, label: 'Confirmar nova senha', password: true, maxLength: 31),
        ),
        const Hint(
            'Mínimo de 6 caracteres. Depois de salvar, o app passa a usar o novo login. Esqueceu? No console serial: '
            'web_auth --reset (volta para admin / lorawan101).',
            top: 0),
      ],
    );
  }
}
