// Descoberta de dispositivos na rede Wi-Fi do celular:
//  1. mDNS (_http._tcp): nós LoRaWAN e o gateway ESP32-S3 (GW_MDNS);
//  2. varredura da sub-rede: GET /info em cada IP (gateway ESP32-WROOM-32U,
//     que não tem mDNS, e qualquer dispositivo com mDNS bloqueado no roteador).
import 'dart:async';
import 'dart:io';

import 'package:nsd/nsd.dart' as nsd;

import 'device_api.dart';

class FoundDevice {
  FoundDevice({
    required this.host,
    required this.port,
    required this.info,
    required this.source,
  });

  final String host;
  final int port;
  final Map<String, dynamic> info;
  final String source; // "mDNS" ou "rede"

  String get name {
    final n = '${info['name'] ?? ''}'.trim();
    if (n.isNotEmpty) return n;
    final h = '${info['host'] ?? ''}'.trim();
    if (h.isNotEmpty) return h;
    final g = '${info['gw_id'] ?? ''}'.trim();
    if (g.isNotEmpty) return 'Gateway $g';
    return host;
  }

  String get mdnsHost => '${info['host'] ?? ''}';
}

class ScanProgress {
  ScanProgress(this.done, this.total);
  final int done;
  final int total;
}

class DeviceScanner {
  DeviceScanner({required this.accept});

  /// Diz se o /info é do tipo deste app.
  final bool Function(Map<String, dynamic> info) accept;

  final _found = StreamController<FoundDevice>.broadcast();
  final _progress = StreamController<ScanProgress>.broadcast();
  final Set<String> _seen = {};
  bool _stopped = false;
  nsd.Discovery? _discovery;
  HttpClient? _probeClient;

  Stream<FoundDevice> get found => _found.stream;
  Stream<ScanProgress> get progress => _progress.stream;

  /// Endereços IPv4 privados do celular (Wi-Fi / Soft AP).
  static Future<List<InternetAddress>> localIPv4() async {
    try {
      final ifs = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      final out = <InternetAddress>[];
      for (final i in ifs) {
        final n = i.name.toLowerCase();
        // dados móveis (rmnet, ccmni, pdp...) ficam de fora
        if (n.startsWith('rmnet') || n.startsWith('ccmni') || n.startsWith('pdp') ||
            n.startsWith('tun') || n.startsWith('dummy')) {
          continue;
        }
        for (final a in i.addresses) {
          final b = a.rawAddress;
          final private = b[0] == 10 ||
              (b[0] == 192 && b[1] == 168) ||
              (b[0] == 172 && b[1] >= 16 && b[1] <= 31);
          if (private) out.add(a);
        }
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  Future<void> run({bool mdns = true, bool subnet = true}) async {
    _probeClient = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 1200)
      ..maxConnectionsPerHost = 1;
    final jobs = <Future<void>>[];
    if (mdns) jobs.add(_runMdns());
    if (subnet) jobs.add(_runSubnet());
    try {
      await Future.wait(jobs);
    } finally {
      stop();
    }
  }

  Future<void> _report(String host, int port, String source,
      [Map<String, dynamic>? info]) async {
    final key = '$host:$port';
    if (_stopped || _seen.contains(key)) return;
    _seen.add(key);
    final i = info ??
        await DeviceApi.probeInfo(host,
            port: port,
            client: _probeClient,
            timeout: const Duration(milliseconds: 2500));
    if (i == null || _stopped) return;
    if (!accept(i)) return;
    _found.add(FoundDevice(host: host, port: port, info: i, source: source));
  }

  Future<void> _runMdns() async {
    try {
      final d = await nsd.startDiscovery('_http._tcp',
          ipLookupType: nsd.IpLookupType.v4);
      _discovery = d;
      d.addServiceListener((service, status) {
        if (status != nsd.ServiceStatus.found) return;
        final addrs = service.addresses ?? const <InternetAddress>[];
        final v4 = addrs.where((a) => a.type == InternetAddressType.IPv4);
        if (v4.isEmpty) return;
        _report(v4.first.address, service.port ?? 80, 'mDNS');
      });
      // mDNS responde em poucos segundos; a varredura segue em paralelo
      for (var i = 0; i < 16 && !_stopped; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    } catch (_) {
      // plugin indisponível (ex.: teste no desktop): segue só com a varredura
    } finally {
      final d = _discovery;
      _discovery = null;
      if (d != null) {
        try {
          await nsd.stopDiscovery(d);
        } catch (_) {}
      }
    }
  }

  Future<void> _runSubnet() async {
    final addrs = await localIPv4();
    final hosts = <String>[];
    final self = <String>{};
    for (final a in addrs) {
      self.add(a.address);
      final b = a.rawAddress;
      final prefix = '${b[0]}.${b[1]}.${b[2]}';
      // Soft AP dos dispositivos: o dispositivo é sempre 192.168.101.101
      if (prefix == '192.168.101') {
        hosts.insert(0, '192.168.101.101');
        continue;
      }
      for (var i = 1; i <= 254; i++) {
        hosts.add('$prefix.$i');
      }
    }
    hosts.removeWhere(self.contains);
    final total = hosts.length;
    var done = 0;
    if (!_stopped) _progress.add(ScanProgress(0, total));
    if (total == 0) return;
    var next = 0;
    Future<void> worker() async {
      while (!_stopped) {
        final i = next++;
        if (i >= hosts.length) return;
        await _report(hosts[i], 80, 'rede');
        done++;
        if (!_stopped && (done % 8 == 0 || done == total)) {
          _progress.add(ScanProgress(done, total));
        }
      }
    }

    await Future.wait(List.generate(32, (_) => worker()));
  }

  void stop() {
    if (_stopped) return;
    _stopped = true;
    final d = _discovery;
    _discovery = null;
    if (d != null) {
      nsd.stopDiscovery(d).catchError((_) {});
    }
    _probeClient?.close(force: true);
    _found.close();
    _progress.close();
  }
}
