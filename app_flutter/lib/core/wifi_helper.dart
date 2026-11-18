// Soft AP dos dispositivos: rede Wi-Fi SEM internet. O Android, nesse caso,
// manda o tráfego do app pelos dados móveis e o 192.168.101.101 não responde.
// O MainActivity.kt deste app (canal "lorawan/wifi") prende o tráfego do app
// ao Wi-Fi (ConnectivityManager.bindProcessToNetwork) e conecta no Soft AP
// com WifiNetworkSpecifier (Android 10+), sem plugin de terceiros.
import 'dart:io';

import 'package:flutter/services.dart';

class WifiHelper {
  WifiHelper._();

  static const MethodChannel _ch = MethodChannel('lorawan/wifi');

  /// Prende o tráfego do app ao Wi-Fi atual (Android). Sem efeito no iOS.
  static Future<bool> bindToWifi() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('bindWifi') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> unbind() async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod<bool>('unbind');
    } catch (_) {}
  }

  /// Conecta no Soft AP do dispositivo (WPA2). O Android mostra um aviso
  /// pedindo para confirmar a rede. false = não conectou (ou Android < 10).
  static Future<bool> connectSoftAp(String ssid, String password) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('connectAp', {'ssid': ssid, 'password': password}) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> disconnectSoftAp() => unbind();
}
