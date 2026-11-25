class SerialSettings {
  const SerialSettings(
    this.path,
    this.baud,
    this.bits,
    this.stopBits,
    this.parity,
    this.flow,
  );
  final String path;
  final int baud, bits, stopBits, parity, flow;

  void validate() {
    if (path.trim().isEmpty ||
        path.length > 4096 ||
        path.contains('\x00') ||
        baud < 50 ||
        baud > 4000000 ||
        bits < 5 ||
        bits > 8 ||
        stopBits < 1 ||
        stopBits > 2 ||
        parity < 0 ||
        parity > 4 ||
        flow < 0 ||
        flow > 2) {
      throw const FormatException('串口参数无效');
    }
  }

  Map<String, dynamic> toJson() => {
    'path': path,
    'baud': baud,
    'bits': bits,
    'stopBits': stopBits,
    'parity': parity,
    'flow': flow,
  };

  factory SerialSettings.fromJson(Map<String, dynamic> json) {
    final value = SerialSettings(
      json['path'] as String,
      json['baud'] as int,
      json['bits'] as int,
      json['stopBits'] as int,
      json['parity'] as int,
      json['flow'] as int,
    );
    value.validate();
    return value;
  }
}
