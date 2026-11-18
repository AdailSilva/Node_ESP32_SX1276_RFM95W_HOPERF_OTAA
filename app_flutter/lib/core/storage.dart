// Dispositivos salvos no celular (lista + login), guardados criptografados
// pelo flutter_secure_storage (Android Keystore / iOS Keychain).
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SavedDevice {
  SavedDevice({
    required this.id,
    required this.name,
    required this.host,
    this.port = 80,
    this.user = 'admin',
    this.password,
    this.remember = false,
    this.mdnsHost = '',
    this.version = '',
    this.detail = '',
    this.apSsid = '',
    this.lastSeen,
  });

  final String id;
  String name;
  String host;
  int port;
  String user;
  String? password;
  bool remember;
  String mdnsHost;
  String version;
  String detail;
  String apSsid;
  DateTime? lastSeen;

  String get address => port == 80 ? host : '$host:$port';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'user': user,
        'password': remember ? password : null,
        'remember': remember,
        'mdnsHost': mdnsHost,
        'version': version,
        'detail': detail,
        'apSsid': apSsid,
        'lastSeen': lastSeen?.toIso8601String(),
      };

  factory SavedDevice.fromJson(Map<String, dynamic> j) => SavedDevice(
        id: '${j['id']}',
        name: '${j['name'] ?? ''}',
        host: '${j['host'] ?? ''}',
        port: (j['port'] as num?)?.toInt() ?? 80,
        user: '${j['user'] ?? 'admin'}',
        password: j['password'] as String?,
        remember: j['remember'] == true,
        mdnsHost: '${j['mdnsHost'] ?? ''}',
        version: '${j['version'] ?? ''}',
        detail: '${j['detail'] ?? ''}',
        apSsid: '${j['apSsid'] ?? ''}',
        lastSeen: DateTime.tryParse('${j['lastSeen'] ?? ''}'),
      );

  static String newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);
}

class DeviceStore {
  DeviceStore._();

  static final DeviceStore instance = DeviceStore._();

  static const _key = 'devices_v1';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  List<SavedDevice>? _cache;

  Future<List<SavedDevice>> load() async {
    if (_cache != null) return _cache!;
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) {
        _cache = [];
      } else {
        final list = jsonDecode(raw) as List<dynamic>;
        _cache = list
            .whereType<Map<String, dynamic>>()
            .map(SavedDevice.fromJson)
            .toList();
      }
    } catch (_) {
      _cache = [];
    }
    return _cache!;
  }

  Future<void> _save() async {
    final list = _cache ?? [];
    await _storage.write(
        key: _key, value: jsonEncode(list.map((d) => d.toJson()).toList()));
  }

  /// Insere ou atualiza (mesmo id, ou mesmo host:porta).
  Future<SavedDevice> upsert(SavedDevice d) async {
    final list = await load();
    final i = list.indexWhere(
        (x) => x.id == d.id || (x.host == d.host && x.port == d.port));
    if (i >= 0) {
      list[i] = SavedDevice.fromJson({...d.toJson(), 'id': list[i].id, 'password': d.password});
      list[i].password = d.password;
      await _save();
      return list[i];
    }
    list.add(d);
    await _save();
    return d;
  }

  Future<void> remove(String id) async {
    final list = await load();
    list.removeWhere((x) => x.id == id);
    await _save();
  }

  Future<void> update(SavedDevice d) async {
    final list = await load();
    final i = list.indexWhere((x) => x.id == d.id);
    if (i >= 0) {
      list[i] = d;
    } else {
      list.add(d);
    }
    await _save();
  }
}
