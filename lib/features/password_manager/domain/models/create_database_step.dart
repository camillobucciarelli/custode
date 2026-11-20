/// FR-2 create-database wizard steps. Non-secret — safe to hold in BLoC
/// state (C-5): the wizard's step position is UI/workflow state, the
/// password itself never is.
///
/// spec 015 FR-1: two steps on native — name and storage, then one
/// credentials step holding password, key file and biometric activation.
enum CreateDatabaseStep {
  /// Step 1 of 2 — name / storage note.
  nameAndStorage,

  /// Step 2 of 2 — credentials: optional master password, three-way key
  /// control, biometric activation.
  credentials,
}
