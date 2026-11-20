import '../../../../core/utils/portable_path.dart';
import '../../domain/entities/database_security_profile.dart';
import '../../domain/repositories/database_security_repository.dart';
import '../datasources/database_security_local_data_source.dart';

class DatabaseSecurityRepositoryImpl implements DatabaseSecurityRepository {
  DatabaseSecurityRepositoryImpl({required this.localDataSource});

  final DatabaseSecurityLocalDataSource localDataSource;

  @override
  Future<DatabaseSecurityProfile?> getProfile(String databaseId) async {
    if (databaseId.trim().isEmpty) {
      return null;
    }

    final raw = await localDataSource.getProfile(databaseId);
    if (raw == null) {
      return null;
    }
    return _profileFromMap(raw, await PortablePath.documentsRoot());
  }

  @override
  Future<void> saveProfile(DatabaseSecurityProfile profile) async {
    await localDataSource.saveProfile(
      profile.databaseId,
      _profileToMap(profile, await PortablePath.documentsRoot()),
    );
  }

  @override
  Future<void> removeProfile(String databaseId) async {
    if (databaseId.trim().isEmpty) {
      return;
    }
    await localDataSource.removeProfile(databaseId);
  }
}

DatabaseSecurityProfile _profileFromMap(
  Map<String, dynamic> map,
  String documentsRoot,
) => DatabaseSecurityProfile(
  databaseId: map['databaseId'] as String,
  keyFilePath: PortablePath.decodeNullable(
    map['keyFilePath'] as String?,
    documentsRoot,
  ),
  // spec-011 FR-7: an absent flag is never consent to persist a secret.
  biometricProtectionEnabled:
      map['biometricProtectionEnabled'] as bool? ?? false,
  biometricOfferAnswered: map['biometricOfferAnswered'] as bool? ?? false,
  inactivityLockTimeoutSeconds: map['inactivityLockTimeoutSeconds'] as int?,
  updatedAt: map['updatedAt'] == null
      ? null
      : DateTime.parse(map['updatedAt'] as String).toLocal(),
);

Map<String, dynamic> _profileToMap(
  DatabaseSecurityProfile profile,
  String documentsRoot,
) => {
  'databaseId': profile.databaseId,
  'keyFilePath': PortablePath.encodeNullable(
    profile.keyFilePath,
    documentsRoot,
  ),
  'biometricProtectionEnabled': profile.biometricProtectionEnabled,
  'biometricOfferAnswered': profile.biometricOfferAnswered,
  'inactivityLockTimeoutSeconds': profile.inactivityLockTimeoutSeconds,
  'updatedAt': profile.updatedAt?.toUtc().toIso8601String(),
};
