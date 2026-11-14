/// I/O port of the opt-in update check: persisted state plus the remote
/// lookup. Keeps the cubit free of HTTP and storage details.
abstract interface class UpdateCheckGateway {
  bool get enabled;
  Future<void> setEnabled(bool value);

  /// Epoch milliseconds of the last successful check, or null.
  int? get lastCheckMs;
  Future<void> setLastCheckMs(int value);

  /// Last version seen from the server, or null.
  String? get latestVersion;
  Future<void> setLatestVersion(String value);

  /// Last version the user was already notified about, or null.
  String? get notifiedVersion;
  Future<void> setNotifiedVersion(String value);

  /// Strict `X.Y.Z` from the remote `latest.json`, or null on any failure.
  Future<String?> fetchLatestVersion();
}
