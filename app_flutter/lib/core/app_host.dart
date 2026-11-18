// Liga as telas comuns (lista, login, logs) às telas próprias de cada app.
import 'package:flutter/widgets.dart';

import 'flavor.dart';
import 'session.dart';

class AppHost {
  AppHost({required this.flavor, required this.shellBuilder});

  final AppFlavor flavor;

  /// Tela principal do dispositivo depois do login.
  final Widget Function(DeviceSession session) shellBuilder;
}

late AppHost appHost;
