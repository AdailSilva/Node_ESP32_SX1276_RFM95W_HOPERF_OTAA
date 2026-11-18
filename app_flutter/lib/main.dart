// App Android do nó LoRaWAN OTAA (ESP32 + RFM95W, MCCI LMiC).
// Mesmas funções da página web do firmware: login, status e ações,
// configuração, logs e manutenção.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/app_host.dart';
import 'core/flavor.dart';
import 'node/node_shell.dart';
import 'ui/devices_screen.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  appHost = AppHost(
    flavor: const AppFlavor(
      kind: DeviceKind.nodeOtaa,
      appTitle: 'LoRaWAN Node OTAA',
      deviceNoun: 'nó',
      defaultApSsid: 'lorawan-node-otaa',
      apHint: 'Nó em modo Soft AP (escolhido em Inicialização, sem Wi-Fi configurado, Soft AP de '
          'emergência ou botão do Soft AP segurado por 3 s): a rede tem o nome do nó '
          '(padrão lorawan-node-otaa), senha lorawan101.',
    ),
    shellBuilder: (s) => NodeShell(session: s),
  );
  runApp(const NodeApp());
}

class NodeApp extends StatelessWidget {
  const NodeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LoRaWAN Node OTAA',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      locale: const Locale('pt', 'BR'),
      supportedLocales: const [Locale('pt', 'BR'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const DevicesScreen(),
    );
  }
}
