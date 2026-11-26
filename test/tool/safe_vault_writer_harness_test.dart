// spec 008 Gate 1 T111 — the harness, executed on the CI host.
//
// The same eight cases the device runner executes, run here against the host
// filesystem on every PR. Two reasons this exists rather than trusting the
// device run alone:
//
//   * a harness is code, and a harness that silently stops exercising the
//     writer would certify every platform it touches. These tests fail when
//     that happens, in CI, on the PR that causes it.
//   * the host run is itself one legitimate artifact — but for exactly ONE
//     row. `host platform never qualifies another target` in the Gate 0
//     schema test is the rule; nothing here may be read as evidence for
//     Android, iOS or Windows.
//
// Order-independent by construction: every case gets its own `createTemp`
// directory and nothing is shared between tests (the PR `test` job runs the
// suite with a random seed).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/safe_vault_writer_harness.dart';
import '../../tool/safety_evidence_schema.dart';

/// Set by `tool/run_safety_harness.sh -H` to make the host run FILE an
/// artifact instead of merely asserting.
///
/// This is legitimate evidence for exactly one platform — the one it ran on —
/// and it is the reason the Linux and Windows T111 rows can be closed in CI
/// at all: on those two targets the GitHub-hosted runner IS the platform, with
/// a real ext4 / NTFS volume underneath. It is NOT legitimate for Android,
/// iOS or macOS, and `file_safety_evidence.dart` refuses a platform mismatch.
const _emit = bool.fromEnvironment('HARNESS_EMIT');
const _commit = String.fromEnvironment('HARNESS_COMMIT');
const _flutterVersion = String.fromEnvironment('HARNESS_FLUTTER_VERSION');
const _command = String.fromEnvironment('HARNESS_COMMAND');
const _filesystem = String.fromEnvironment(
  'HARNESS_FILESYSTEM',
  defaultValue: 'unknown',
);
const _runner = String.fromEnvironment(
  'HARNESS_DEVICE',
  defaultValue: 'ci host',
);

void main() {
  late Directory workspace;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('t111_harness_');
  });

  tearDown(() async {
    if (workspace.existsSync()) {
      await workspace.delete(recursive: true);
    }
  });

  group('T111 harness on the host filesystem', () {
    test('every required case executes and passes', () async {
      final run = await runHarness(workspace);

      expect(
        run.cases.map((c) => c.name).toList(),
        requiredHarnessCases,
        reason:
            'the harness must execute exactly the cases the Gate 0 schema '
            'requires, in a stable order',
      );

      for (final c in run.cases) {
        expect(
          c.passed,
          isTrue,
          reason: 'case ${c.name} failed on the host: ${c.detail}',
        );
        expect(
          c.targetState,
          anyOf('old', 'new'),
          reason:
              'case ${c.name} left the target neither fully old nor fully '
              'new — that is the corruption this gate exists to detect',
        );
      }
    });

    test('an ordinary POSIX/NTFS host reports both gated guarantees', () async {
      final run = await runHarness(workspace);
      expect(
        run.capabilities.atomicReplaceOverExisting,
        isTrue,
        reason:
            'rename over an existing file is not atomic on this host '
            'filesystem; the writer cannot hold its contract here',
      );
      expect(
        run.capabilities.backupNoOverwrite,
        isTrue,
        reason:
            'exclusive create did not refuse an existing name; the '
            'no-overwrite backup guarantee does not hold on this filesystem',
      );
    });

    test(
      'the assembled artifact validates and enables only this host',
      () async {
        final started = DateTime.now().toUtc();
        final run = await runHarness(workspace);
        final artifact = buildArtifact(
          run: run,
          platform: Platform.operatingSystem,
          osVersion: Platform.operatingSystemVersion,
          deviceOrRunner: 'host test',
          filesystem: 'host',
          flutterVersion: 'host test',
          dartVersion: Platform.version,
          commit: 'host test',
          command: 'flutter test test/tool/safe_vault_writer_harness_test.dart',
          startedAtUtc: started,
          completedAtUtc: DateTime.now().toUtc(),
        );

        expect(validateArtifact(artifact), isEmpty);
        expect(artifact['status'], 'passed');
        expect(qualifiedPlatforms(artifact), [Platform.operatingSystem]);
        for (final other in targetPlatforms.where(
          (p) => p != Platform.operatingSystem,
        )) {
          expect(qualifiedPlatforms(artifact), isNot(contains(other)));
        }
      },
    );

    // The gate's whole purpose is to REFUSE a platform, so the refusing path
    // needs its own evidence. Without this, a harness that could never report
    // `failed` would look identical to one that always passes.
    test('a failing case forces status=failed and enables nothing', () async {
      final run = await runHarness(workspace);
      final broken = HarnessRun(
        cases: [
          for (final c in run.cases)
            if (c.name == requiredHarnessCases.first)
              HarnessCase(
                name: c.name,
                injectedFailurePhase: c.injectedFailurePhase,
                targetState: c.targetState,
                passed: false,
                finalChecksum: c.finalChecksum,
                detail: 'synthetic failure',
              )
            else
              c,
        ],
        capabilities: run.capabilities,
      );
      final artifact = buildArtifact(
        run: broken,
        platform: Platform.operatingSystem,
        osVersion: 'x',
        deviceOrRunner: 'x',
        filesystem: 'x',
        flutterVersion: 'x',
        dartVersion: 'x',
        commit: 'x',
        command: 'x',
        startedAtUtc: DateTime.now().toUtc(),
        completedAtUtc: DateTime.now().toUtc(),
      );
      expect(artifact['status'], 'failed');
      expect(qualifiedPlatforms(artifact), isEmpty);
    });

    test('a platform without atomic replace cannot pass', () async {
      final run = await runHarness(workspace);
      final artifact = buildArtifact(
        run: HarnessRun(
          cases: run.cases,
          capabilities: const HarnessCapabilities(
            flushSupported: true,
            directorySyncSupported: true,
            atomicReplaceOverExisting: false,
            backupNoOverwrite: true,
          ),
        ),
        platform: Platform.operatingSystem,
        osVersion: 'x',
        deviceOrRunner: 'x',
        filesystem: 'x',
        flutterVersion: 'x',
        dartVersion: 'x',
        commit: 'x',
        command: 'x',
        startedAtUtc: DateTime.now().toUtc(),
        completedAtUtc: DateTime.now().toUtc(),
      );
      expect(artifact['status'], 'failed');
      expect(qualifiedPlatforms(artifact), isEmpty);
    });
  });

  // Skipped in ordinary runs, so the normal suite never writes into
  // `build/safety-evidence/` and never trips the Gate 0 tripwire.
  test('emit an artifact for this host platform', () async {
    final started = DateTime.now().toUtc();
    final run = await runHarness(workspace);
    final artifact = buildArtifact(
      run: run,
      platform: Platform.operatingSystem,
      osVersion: Platform.operatingSystemVersion,
      deviceOrRunner: _runner,
      filesystem: _filesystem,
      flutterVersion: _flutterVersion,
      dartVersion: Platform.version,
      commit: _commit,
      command: _command,
      startedAtUtc: started,
      completedAtUtc: DateTime.now().toUtc(),
    );
    // ignore: avoid_print
    print(encodeArtifactLine(artifact));
    expect(
      validateArtifact(artifact),
      isEmpty,
      reason: 'the emitted artifact does not satisfy the Gate 0 schema',
    );
  }, skip: _emit ? false : 'set --dart-define=HARNESS_EMIT=true to file');

  group('filer CLI', _filerTests);

  group('artifact transport', () {
    test('round-trips through the stdout marker line', () async {
      final run = await runHarness(workspace);
      final artifact = buildArtifact(
        run: run,
        platform: Platform.operatingSystem,
        osVersion: 'x',
        deviceOrRunner: 'x',
        filesystem: 'x',
        flutterVersion: 'x',
        dartVersion: 'x',
        commit: 'x',
        command: 'x',
        startedAtUtc: DateTime.now().toUtc(),
        completedAtUtc: DateTime.now().toUtc(),
      );
      final line = encodeArtifactLine(artifact);
      expect(decodeArtifactLine(line), artifact);
    });

    test('survives a device log prefix on the same line', () {
      // `flutter test -d <device>` prefixes app stdout; a transport that only
      // worked on a bare line would lose the artifact on exactly the runs
      // that matter.
      final line = encodeArtifactLine(const {'hello': 'world'});
      expect(decodeArtifactLine('I/flutter (1234): $line'), {'hello': 'world'});
    });

    test('a non-artifact line decodes to null', () {
      expect(decodeArtifactLine('QA|CASE|whatever=pass'), isNull);
      expect(decodeArtifactLine('ordinary log output'), isNull);
    });

    test('a truncated payload decodes to null rather than throwing', () {
      final line = encodeArtifactLine(const {'hello': 'world'});
      final truncated = line.substring(0, line.length - 8);
      expect(() => decodeArtifactLine(truncated), returnsNormally);
      expect(decodeArtifactLine(truncated), isNull);
    });
  });
}

// =============================================================================
// The filer CLI, exercised as a process.
//
// This group exists because of a defect it caught: `file_safety_evidence.dart`
// originally returned its status from `main`, which the Dart VM ignores, so
// every refusal exited 0 and `run_safety_harness.sh` would have treated an
// unfileable run as a successful one. Exit codes are the whole interface
// between the two, so they are asserted here rather than assumed.
// =============================================================================

void _filerTests() {
  Future<ProcessResult> file(
    String transcript,
    String outRoot, [
    String platform = '',
  ]) {
    return Process.run('dart', [
      'run',
      'tool/file_safety_evidence.dart',
      transcript,
      outRoot,
      platform,
    ], workingDirectory: Directory.current.path);
  }

  late Directory scratch;
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('t111_filer_');
  });
  tearDown(() async {
    if (scratch.existsSync()) await scratch.delete(recursive: true);
  });

  Future<String> transcriptFor(Map<String, dynamic> artifact) async {
    final f = File(joinPath(scratch.path, 'transcript.log'));
    await f.writeAsString(
      'I/flutter (1): ${encodeArtifactLine(artifact)}\n',
      flush: true,
    );
    return f.path;
  }

  Map<String, dynamic> passing() => <String, dynamic>{
    'schemaVersion': 1,
    'platform': 'linux',
    'osVersion': 'x',
    'deviceOrRunner': 'x',
    'filesystem': 'x',
    'flutterVersion': 'x',
    'dartVersion': 'x',
    'commit': 'deadbeef',
    'command': 'tool/run_safety_harness.sh -d x',
    'startedAtUtc': '2026-01-01T00:00:00Z',
    'completedAtUtc': '2026-01-01T00:00:01Z',
    'status': 'passed',
    'flushSupported': true,
    'directorySyncSupported': true,
    'atomicReplaceOverExisting': true,
    'backupNoOverwrite': true,
    'cases': [
      for (final name in requiredHarnessCases)
        <String, dynamic>{
          'name': name,
          'injectedFailurePhase': name,
          'targetState': 'old',
          'passed': true,
          'finalChecksum': 'x',
        },
    ],
    'logPath': 'build/safety-evidence/linux/safe-vault-writer.log',
  };

  test('a passing artifact is filed and exits 0', () async {
    final out = joinPath(scratch.path, 'out');
    final r = await file(await transcriptFor(passing()), out);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    expect(
      File(joinPath(out, 'linux', 'safe-vault-writer.json')).existsSync(),
      isTrue,
    );
  });

  test('a failed artifact is still filed, but exits 2', () async {
    final artifact = passing()
      ..['status'] = 'failed'
      ..['atomicReplaceOverExisting'] = false;
    final out = joinPath(scratch.path, 'out');
    final r = await file(await transcriptFor(artifact), out);
    expect(
      r.exitCode,
      2,
      reason: 'a recordable finding must be distinguishable from a pass',
    );
    expect(
      File(joinPath(out, 'linux', 'safe-vault-writer.json')).existsSync(),
      isTrue,
      reason: 'a platform that fails the gate is evidence and must be filed',
    );
  });

  test('a schema-violating artifact is refused and files nothing', () async {
    final artifact = passing()..['commit'] = '';
    final out = joinPath(scratch.path, 'out');
    final r = await file(await transcriptFor(artifact), out);
    expect(r.exitCode, 1);
    expect(Directory(out).existsSync(), isFalse);
  });

  test(
    'an artifact for another platform is refused and files nothing',
    () async {
      final out = joinPath(scratch.path, 'out');
      final r = await file(await transcriptFor(passing()), out, 'android');
      expect(
        r.exitCode,
        1,
        reason: 'host evidence never qualifies another target',
      );
      expect(Directory(out).existsSync(), isFalse);
    },
  );

  test('a transcript with no artifact is refused and files nothing', () async {
    final f = File(joinPath(scratch.path, 'noise.log'));
    await f.writeAsString('flutter: ordinary log output\n', flush: true);
    final out = joinPath(scratch.path, 'out');
    final r = await file(f.path, out);
    expect(r.exitCode, 1);
    expect(Directory(out).existsSync(), isFalse);
  });
}

String joinPath(String a, String b, [String? c]) =>
    c == null ? '$a/$b' : '$a/$b/$c';
