// O que muda entre os três apps (gateway, nó ABP, nó OTAA).
enum DeviceKind { gateway, nodeAbp, nodeOtaa }

class AppFlavor {
  const AppFlavor({
    required this.kind,
    required this.appTitle,
    required this.deviceNoun,
    required this.defaultApSsid,
    required this.apHint,
  });

  final DeviceKind kind;
  final String appTitle;

  /// "gateway" / "nó" (usado nos textos).
  final String deviceNoun;

  /// Nome padrão do Soft AP do firmware.
  final String defaultApSsid;
  final String apHint;

  /// Endereço do dispositivo no próprio Soft AP (igual nos três firmwares).
  static const String apIp = '192.168.101.101';
  static const String defaultUser = 'admin';
  static const String defaultPassword = 'lorawan101';

  bool get isGateway => kind == DeviceKind.gateway;
  bool get isNode => !isGateway;

  /// "abp" / "otaa" (nós).
  String get nodeMode => kind == DeviceKind.nodeAbp ? 'abp' : 'otaa';

  String get deviceNounCap =>
      deviceNoun.isEmpty ? '' : deviceNoun[0].toUpperCase() + deviceNoun.substring(1);

  /// "o gateway" / "o nó"
  String get theDevice => isGateway ? 'o gateway' : 'o nó';

  /// O GET /info pertence a este app?
  bool acceptsInfo(Map<String, dynamic> info) {
    if (isGateway) return info['type'] == 'gateway';
    return info['type'] == 'node' && info['mode'] == nodeMode;
  }

  /// Descreve o /info de outro tipo ("um nó OTAA", "um gateway").
  static String describeInfo(Map<String, dynamic> info) {
    if (info['type'] == 'gateway') return 'um gateway ESP32_SX1302';
    if (info['type'] == 'node') return 'um nó LoRaWAN ${'${info['mode'] ?? ''}'.toUpperCase()}';
    return 'outro tipo de dispositivo';
  }

  /// O config.json pertence a este app? null = sim; senão, a mensagem de erro.
  String? checkConfig(Map<String, dynamic> cfg) {
    if (isGateway) {
      if (cfg['_type'] == 'esp32_sx1302') return null;
      if (cfg['_mode'] != null) {
        return 'Este endereço é de um nó LoRaWAN ${'${cfg['_mode']}'.toUpperCase()}, '
            'não de um gateway. Use o app do nó.';
      }
      return 'O dispositivo respondeu, mas não parece ser um gateway ESP32_SX1302.';
    }
    final m = cfg['_mode'];
    if (m == nodeMode) return null;
    if (cfg['_type'] == 'esp32_sx1302') {
      return 'Este endereço é do gateway ESP32_SX1302. Use o app do gateway.';
    }
    if (m is String) {
      return 'Este nó tem firmware ${m.toUpperCase()}; este app é para nós '
          '${nodeMode.toUpperCase()}. Use o app LoRaWAN Node ${m.toUpperCase()}.';
    }
    return 'O dispositivo respondeu, mas não parece ser um nó LoRaWAN.';
  }
}
