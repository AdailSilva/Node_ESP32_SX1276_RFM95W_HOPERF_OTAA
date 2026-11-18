// Sessão aberta com um dispositivo: cliente HTTP, configuração salva
// (GET /config.json) e status (GET /status a cada 5 s, como a página).
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'device_api.dart';
import 'storage.dart';

class DeviceSession extends ChangeNotifier {
  DeviceSession({required this.api, required this.device, required this.config}) {
    // 401 em qualquer endereço (não só no /status) derruba a sessão
    api.onUnauthorized = _onUnauthorized;
  }

  final DeviceApi api;
  final SavedDevice device;
  Map<String, dynamic> config;

  Map<String, dynamic>? status;
  String? statusError;
  DateTime? statusAt;

  /// O login deixou de valer (senha trocada por outro meio).
  bool authLost = false;

  bool _busy = false;
  bool _disposed = false;
  bool _polling = false;
  int _gen = 0;
  Timer? _timer;

  bool get disposed => _disposed;

  void _onUnauthorized() {
    if (_disposed || authLost) return;
    authLost = true;
    _polling = false;
    _timer?.cancel();
    // fora da pilha da requisição: quem chamou ainda trata a exceção primeiro
    scheduleMicrotask(() {
      if (!_disposed) notifyListeners();
    });
  }

  /// Uma requisição por vez; a próxima só depois da resposta da anterior.
  Future<void> refreshStatus() async {
    if (_busy || _disposed) return;
    _busy = true;
    try {
      status = await api.getJson('/status');
      statusError = null;
      statusAt = DateTime.now();
    } on ApiException catch (e) {
      statusError = e.message;
    } catch (e) {
      statusError = 'Resposta inesperada do dispositivo.';
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Liga/desliga a atualização automática (só com a aba visível).
  void setPolling(bool on) {
    if (on == _polling) return;
    _polling = on;
    _gen++;
    _timer?.cancel();
    if (on) _loop(_gen);
  }

  Future<void> _loop(int gen) async {
    if (!_polling || _disposed || gen != _gen) return;
    await refreshStatus();
    if (!_polling || _disposed || gen != _gen) return;
    _timer = Timer(const Duration(seconds: 5), () => _loop(gen));
  }

  Future<void> reloadConfig() async {
    config = await api.getJson('/config.json');
    if (!_disposed) notifyListeners();
  }

  /// Login alterado em "Acesso": o app passa a usar o novo na hora.
  Future<void> updateCredentials(String user, String password) async {
    api.user = user;
    api.password = password;
    device.user = user;
    device.password = password;
    await DeviceStore.instance.update(device);
  }

  void touch() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _polling = false;
    _timer?.cancel();
    api.onUnauthorized = null;
    api.close();
    super.dispose();
  }
}
