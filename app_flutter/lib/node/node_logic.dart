// Regras da página do nó (node_page.h) portadas para Dart: tabela de data
// rates AU915, canais, tempo no ar e os textos de status.
import 'dart:math' as math;

import '../core/format.dart';
import '../ui/widgets.dart';

/// AU915: [SF, BW kHz, payload máximo] para DR0..DR6.
const List<List<int>> nodeDr = [
  [12, 125, 51],
  [11, 125, 51],
  [10, 125, 51],
  [9, 125, 115],
  [8, 125, 222],
  [7, 125, 222],
  [8, 500, 222],
];

String _mhz(double v) => v.toStringAsFixed(1).replaceAll('.', ',');

final List<MapEntry<int, String>> subBandItems = [
  for (var i = 0; i < 8; i++)
    MapEntry(i, 'SB$i · canais ${i * 8}–${i * 8 + 7} · ${_mhz(915.2 + 1.6 * i)}–${_mhz(916.6 + 1.6 * i)} MHz'),
];

final List<MapEntry<int, String>> drItems = [
  for (var i = 0; i < nodeDr.length; i++)
    MapEntry(i, 'DR$i — SF${nodeDr[i][0]} / BW${nodeDr[i][1]} · até ${nodeDr[i][2]} bytes'),
];

final List<MapEntry<int, String>> txPowItems = [
  for (final v in [2, 4, 6, 8, 10, 12, 14, 16, 17, 18, 20])
    MapEntry(v, '$v dBm${v == 14 ? ' (padrão)' : v == 20 ? ' (máx. RFM95W)' : ''}'),
];

final List<MapEntry<int, String>> rx2DrItems = [
  for (final v in [8, 9, 10, 11, 12, 13]) MapEntry(v, 'DR$v · SF${20 - v}/BW500'),
];

final List<MapEntry<int, String>> clkItems = [
  for (final v in [0, 1, 2, 3, 4, 5, 7, 10]) MapEntry(v, '$v %${v == 1 ? ' (padrão)' : ''}'),
];

final List<MapEntry<int, String>> apChItems = [
  for (var v = 1; v <= 13; v++) MapEntry(v, 'Canal $v'),
];

final List<MapEntry<int, String>> baudItems = [
  for (final v in [9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600]) MapEntry(v, '$v bps'),
];

/// "8-15,65" -> canais; null se inválida ou vazia.
Set<int>? chList(String s) {
  final m = <int>{};
  var ok = true;
  for (var p in s.split(RegExp(r'[,;]'))) {
    p = p.trim();
    if (p.isEmpty) continue;
    final r = RegExp(r'^(\d+)\s*(?:-\s*(\d+))?$').firstMatch(p);
    if (r == null) {
      ok = false;
      continue;
    }
    final a = int.parse(r.group(1)!), b = r.group(2) != null ? int.parse(r.group(2)!) : a;
    if (a > b || b > 71) {
      ok = false;
      continue;
    }
    for (var c = a; c <= b; c++) {
      m.add(c);
    }
  }
  return ok && m.isNotEmpty ? m : null;
}

/// Canais efetivos: lista personalizada ou sub-banda (+ canal de 500 kHz).
Set<int>? channels(String list, int subBand, bool ch500) {
  if (list.trim().isNotEmpty) return chList(list.trim());
  final m = <int>{for (var i = 0; i < 8; i++) subBand * 8 + i};
  if (ch500) m.add(64 + subBand);
  return m;
}

/// Tempo no ar LoRa (ms): cabeçalho explícito, CRC, CR 4/5, preâmbulo 8.
double timeOnAir(int dr, int pl) {
  final d = nodeDr[dr];
  final sf = d[0], bw = d[1];
  final de = (bw == 125 && sf >= 11) ? 1 : 0;
  final ts = math.pow(2, sf) / (bw * 1000);
  final n = 8 + math.max(((8 * pl - 4 * sf + 28 + 16) / (4 * (sf - 2 * de))).ceil() * 5, 0);
  return ((12.25 + n) * ts * 1000).toDouble();
}

num _n(Map m, String k) => (m[k] as num?) ?? 0;
bool _b(Map m, String k) => m[k] == true;

typedef StatusLine = ({Level level, String text});

/// Faixa principal do Status (gs).
StatusLine nodeLine(Map l) {
  final otaa = l['mode'] == 'otaa';
  if (otaa && !_b(l, 'joined')) {
    final tries = _n(l, 'join_tries');
    return (
      level: Level.warn,
      text: tries > 0
          ? 'Aguardando o JOIN (tentativa $tries). Confira DevEUI, JoinEUI, AppKey e se o gateway escuta estes canais.'
          : 'Iniciando o JOIN…'
    );
  }
  if (_b(l, 'pending')) return (level: Level.ok, text: 'Transmitindo agora…');
  final last = _n(l, 'last_tx');
  if (last < 0) {
    return (
      level: Level.ok,
      text: otaa ? 'JOIN aceito, aguardando o primeiro envio.' : 'Sessão ABP provisionada, aguardando o primeiro envio.'
    );
  }
  final interval = _n(l, 'interval');
  if (last > math.max(60, 3 * interval)) {
    return (
      level: Level.warn,
      text: 'Nenhum uplink há ${dur(last)} (intervalo de $interval s). Veja os logs.'
    );
  }
  return (level: Level.ok, text: 'Nó transmitindo. Último uplink há ${dur(last)}.');
}

String lwChip(Map? l) {
  if (l == null) return 'LoRaWAN…';
  if (l['mode'] == 'abp') return 'Sessão ABP';
  return _b(l, 'joined') ? 'JOIN aceito' : 'Aguardando JOIN';
}

Level lwChipLevel(Map? l) {
  if (l == null) return Level.none;
  return (l['mode'] == 'abp' || _b(l, 'joined')) ? Level.ok : Level.warn;
}

List<KvItem> nodeKv(Map n, Map l, {required bool confirmed}) {
  final otaa = l['mode'] == 'otaa';
  final rssi = n['rssi'] as num?;
  final wifi = '${n['wifi'] ?? ''}';
  String rssiSub;
  if (wifi == 'ap') {
    rssiSub = 'Soft AP ${n['ap_ssid'] ?? ''} · ${n['ap_clients'] ?? 0} conectado(s)';
  } else if (wifi == 'off') {
    rssiSub = 'Wi-Fi desligado';
  } else if (rssi == null) {
    rssiSub = 'conectando ao Wi-Fi…';
  } else {
    rssiSub = '${rssi >= -60 ? 'sinal bom' : rssi >= -75 ? 'sinal regular' : 'sinal fraco'} · ${n['ssid'] ?? ''}'
        '${wifi == 'apsta' ? ' · Soft AP ativo' : ''}';
  }
  final d = l['last_dn'] as Map?;
  final nextTx = _n(l, 'next_tx');
  final freq = _n(l, 'freq');
  return [
    KvItem('Ligado há', dur(_n(n, 'up')), 'contadores zeram ao reiniciar'),
    KvItem('Memória livre', kb(_n(n, 'heap')), 'mínima desde que ligou: ${kb(_n(n, 'heap_min'))}'),
    KvItem('Sinal Wi-Fi', rssi == null ? '-' : '$rssi dBm', rssiSub),
    KvItem.copyable(
      'Sessão',
      otaa && !_b(l, 'joined') ? 'sem sessão' : '${l['devaddr'] ?? '-'}',
      otaa
          ? (_b(l, 'joined')
              ? 'OTAA · NetID ${l['netid']} · JOIN em ${l['join_tries']} tentativa(s)'
              : 'OTAA · ${l['join_tries']} tentativa(s) de JOIN')
          : 'ABP · NetID ${l['netid']}',
    ),
    KvItem('Frame counter (FCnt)', nf(l['fcnt_up']),
        'próximo de uplink · downlink ${nf(l['fcnt_dn'])}${otaa ? '' : ' · lido da NVS ao ligar: ${nf(l['boot_fcnt'])}'}'),
    KvItem(
      'Uplinks enviados',
      nf(l['up']),
      _n(l, 'ack') > 0
          ? 'com ACK do servidor: ${nf(l['ack'])}'
          : confirmed
              ? 'nenhum ACK ainda'
              : 'sem confirmação (unconfirmed)',
    ),
    KvItem(
      'Downlinks recebidos',
      nf(l['dn']),
      d != null
          ? 'último: FPort ${d['port']} · ${d['len']} B · ${d['hex']} · RSSI ${d['rssi']} dBm · '
              'SNR ${d['snr']} dB · há ${dur(_n(d, 'age'))}'
          : 'nenhum desde que ligou',
    ),
    KvItem(
      'Próximo envio',
      _b(l, 'pending')
          ? 'agora'
          : nextTx < 0
              ? '-'
              : nextTx <= 0
                  ? 'em instantes'
                  : 'em ${dur(nextTx)}',
      'DR${l['dr']} · ${l['txpow']} dBm${freq > 0 ? ' · ${dec(freq / 1e6, 1)} MHz' : ''} · a cada ${l['interval']} s',
    ),
  ];
}

/// GPIO só de entrada / da flash no ESP32 clássico (a página faz a mesma conta).
bool classicEsp32(String chip) =>
    RegExp(r'^ESP32(-D0WD|-D0WDQ6|-D2WD|-S0WD|-U4WDH|-PICO)?').hasMatch(chip) &&
    !RegExp(r'S2|S3|C3|C6|H2').hasMatch(chip);
