class HostKeyPolicy {
  HostKeyPolicy(this.known);
  final Map<String, String> known;
  bool matches(String endpoint, String algorithm, String fingerprint) =>
      known[endpoint] == '$algorithm $fingerprint';
  void pin(String endpoint, String algorithm, String fingerprint) {
    if (!fingerprint.startsWith('SHA256:') || algorithm.isEmpty) {
      throw const FormatException('无效主机密钥');
    }
    known[endpoint] = '$algorithm $fingerprint';
  }
}
