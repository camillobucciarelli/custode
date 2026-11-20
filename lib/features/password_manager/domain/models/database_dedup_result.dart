import '../entities/database_record.dart';

enum DatabaseDuplicateMatchType { none, source, hash, name }

enum DatabaseDuplicateResolution {
  useExisting,
  replaceExisting,
  keepBoth,
  cancel,
}

class DatabaseDedupResult {
  const DatabaseDedupResult({
    required this.matchType,
    required this.resolution,
    this.existingRecord,
  });

  final DatabaseDuplicateMatchType matchType;
  final DatabaseDuplicateResolution resolution;
  final DatabaseRecord? existingRecord;

  bool get hasDuplicate => existingRecord != null;

  static const noDuplicate = DatabaseDedupResult(
    matchType: DatabaseDuplicateMatchType.none,
    resolution: DatabaseDuplicateResolution.keepBoth,
  );
}
