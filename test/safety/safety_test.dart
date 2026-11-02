import 'dart:convert';
import 'dart:io';

import 'package:l10n_sweep/l10n_sweep.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../cli_harness.dart';
import '../helpers.dart';

void main() {
  late Directory project;

  setUp(() => project = copyFixture('sample_flutter_app'));
  tearDown(() => deleteQuietly(project));

  File locale(String name) =>
      File(p.join(project.path, 'assets', 'translations', '$name.json'));

  Map<String, List<int>> localeFiles() => {
    for (final name in ['en', 'ur']) name: locale(name).readAsBytesSync(),
  };

  test('analysis never modifies files', () async {
    final before = snapshot(project);
    await runCli(['analyze', '--verbose'], projectRoot: project.path);
    await runCli(['analyze', '--format', 'json'], projectRoot: project.path);
    await runCli(['doctor'], projectRoot: project.path);
    expect(snapshot(project), before);
  });

  test('dry-run never modifies files', () async {
    final before = snapshot(project);
    for (final args in [
      ['clean', '--dry-run'],
      ['clean', '--dry-run', '--yes'],
      ['clean', '--dry-run', '--keys', 'unused_message'],
    ]) {
      final run = await runCli(args, projectRoot: project.path);
      expect(run.exitCode, 0, reason: '$run');
      expect(run.out, contains('Dry run: no files were modified.'));
    }
    expect(snapshot(project), before);
  });

  test('clean refuses to run without a terminal or --yes', () async {
    final before = snapshot(project);
    final run = await runCli(['clean'], projectRoot: project.path);
    expect(run.exitCode, 2);
    expect(run.err, contains('needs a terminal'));
    expect(snapshot(project), before);
  });

  test('declining the confirmation or cancelling changes nothing', () async {
    final before = snapshot(project);
    final declined = ScriptedPrompter(confirmAnswer: false);
    var run = await runCli(
      ['clean'],
      projectRoot: project.path,
      prompter: declined,
    );
    expect(run.exitCode, 0);
    expect(declined.questions, hasLength(1));
    expect(run.out, contains('Cancelled. No files were modified.'));

    final cancelled = ScriptedPrompter(selection: (_) => null);
    run = await runCli(
      ['clean'],
      projectRoot: project.path,
      prompter: cancelled,
    );
    expect(run.out, contains('Cancelled. No files were modified.'));

    final nothing = ScriptedPrompter(selection: (_) => []);
    run = await runCli(['clean'], projectRoot: project.path, prompter: nothing);
    expect(run.out, contains('No keys selected.'));
    expect(snapshot(project), before);
  });

  test('cleanup creates a verified backup that restore brings back', () async {
    final original = localeFiles();
    final run = await runCli(['clean', '--yes'], projectRoot: project.path);
    expect(run.exitCode, 0, reason: '$run');
    expect(localeFiles(), isNot(original));

    final backups = Directory(
      p.join(project.path, '.l10n_sweep', 'backups'),
    ).listSync().whereType<Directory>().toList();
    expect(backups, hasLength(1));
    final backup = backups.single;
    expect(
      File(
        p.join(backup.path, 'files', 'assets', 'translations', 'en.json'),
      ).readAsBytesSync(),
      original['en'],
    );
    final manifest =
        jsonDecode(
              File(p.join(backup.path, 'manifest.json')).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(manifest['removed_keys'], contains('unused_message'));

    final restore = await runCli([
      'restore',
      '--yes',
    ], projectRoot: project.path);
    expect(restore.exitCode, 0, reason: '$restore');
    expect(localeFiles(), original);
  });

  test('--no-backup skips the backup', () async {
    final run = await runCli([
      'clean',
      '--yes',
      '--no-backup',
    ], projectRoot: project.path);
    expect(run.exitCode, 0, reason: '$run');
    expect(
      Directory(p.join(project.path, '.l10n_sweep')).existsSync(),
      isFalse,
    );
  });

  test('invalid JSON stops cleanup and is never overwritten', () async {
    const broken = '{\n  "app_name": "x",\n  "oops": \n}\n';
    locale('ur').writeAsStringSync(broken);
    final before = snapshot(project);
    final run = await runCli(['clean', '--yes'], projectRoot: project.path);
    expect(run.exitCode, 2, reason: '$run');
    expect(run.err, contains('assets/translations/ur.json:4:1'));
    expect(run.err, contains('No files were modified.'));
    expect(snapshot(project), before);
    expect(locale('ur').readAsStringSync(), broken);
  });

  test('uncertain, dynamic, excluded and ignored keys survive --yes', () async {
    // An unresolvable call makes every unreferenced key uncertain.
    final screen = File(p.join(project.path, 'lib', 'api_screen.dart'));
    screen.writeAsStringSync('''
import 'package:easy_localization/easy_localization.dart';
Widget build(dynamic api) => Text(api.label.tr());
''');
    final before = localeFiles();
    final run = await runCli(['clean', '--yes'], projectRoot: project.path);
    expect(run.exitCode, 0, reason: '$run');
    expect(run.out, contains('No definitely unused keys found.'));
    expect(localeFiles(), before);

    // Explicitly requesting an uncertain key with --yes is refused.
    final refused = await runCli([
      'clean',
      '--yes',
      '--keys',
      'unused_message',
    ], projectRoot: project.path);
    expect(refused.exitCode, 2);
    expect(refused.err, contains('potentially_unused'));
    expect(localeFiles(), before);

    // Acknowledging the call makes the remaining keys removable again, but
    // dynamic, excluded and ignored keys stay.
    screen.writeAsStringSync('''
import 'package:easy_localization/easy_localization.dart';
// l10n_sweep:ignore
Widget build(dynamic api) => Text(api.label.tr());
''');
    final cleaned = await runCli(['clean', '--yes'], projectRoot: project.path);
    expect(cleaned.exitCode, 0, reason: '$cleaned');
    final en =
        jsonDecode(locale('en').readAsStringSync()) as Map<String, dynamic>;
    expect((en['sections'] as Map).keys, ['news', 'events']);
    expect(en['app'], {'version': '1.0.0'});
    expect(en['legacy'], {'translation': 'Old text'});
    expect((en['onboarding'] as Map).keys, ['step_1', 'step_2']);
  });

  test('used keys can never be removed, even when requested', () async {
    final config = const ConfigLoader().load(project.path).config;
    final result = LocalizationAnalyzer(config).analyze();
    final engine = CleanupEngine(
      config: config,
      catalog: result.catalog,
      report: result.report,
    );
    for (final key in ['home.title', 'app.version', 'legacy.translation']) {
      expect(() => engine.plan([key]), throwsA(isA<CleanupException>()));
    }
    expect(
      () => engine.plan(['does.not.exist']),
      throwsA(isA<CleanupException>()),
    );
  });

  test('unrelated keys and formatting stay byte-identical', () async {
    final enBefore = locale('en').readAsStringSync();
    await runCli([
      'clean',
      '--yes',
      '--keys',
      'errors.timeout',
    ], projectRoot: project.path);
    final enAfter = locale('en').readAsStringSync();
    final removed = enBefore.replaceFirst(
      ',\n    "timeout": "The request timed out"',
      '',
    );
    expect(enAfter, removed);
  });

  test('cleanup can be repeated safely', () async {
    final first = await runCli(['clean', '--yes'], projectRoot: project.path);
    expect(first.exitCode, 0, reason: '$first');
    final after = snapshot(project);
    final second = await runCli(['clean', '--yes'], projectRoot: project.path);
    expect(second.exitCode, 0, reason: '$second');
    expect(second.out, contains('Nothing to remove'));
    expect(snapshot(project), after);
  });

  test('a failed write restores files already written', () {
    final config = const ConfigLoader().load(project.path).config;
    final result = LocalizationAnalyzer(config).analyze();
    final before = localeFiles();
    var writes = 0;
    final engine = CleanupEngine(
      config: config,
      catalog: result.catalog,
      report: result.report,
      writer: (file, bytes) {
        // The first temp file is written; the second fails.
        if (file.path.endsWith('.tmp') && ++writes == 2) {
          throw const FileSystemException('disk full');
        }
        file.writeAsBytesSync(bytes, flush: true);
      },
    );
    final plan = engine.plan(result.report.unusedKeys.map((k) => k.key));
    expect(plan.keysByFile, hasLength(2));
    expect(
      () => engine.apply(plan),
      throwsA(
        isA<CleanupException>().having(
          (e) => e.message,
          'message',
          contains('restored to their original contents'),
        ),
      ),
    );
    expect(localeFiles(), before);
    final leftovers = Directory(
      p.join(project.path, 'assets', 'translations'),
    ).listSync().where((e) => e.path.endsWith('.tmp'));
    expect(leftovers, isEmpty);
  });

  test('files changed after analysis are not overwritten', () {
    final config = const ConfigLoader().load(project.path).config;
    final result = LocalizationAnalyzer(config).analyze();
    final engine = CleanupEngine(
      config: config,
      catalog: result.catalog,
      report: result.report,
    );
    final plan = engine.plan(['unused_message']);
    locale('ur').writeAsStringSync(
      locale('ur').readAsStringSync().replaceFirst('}', ', "new": "x"}'),
    );
    final edited = localeFiles();
    expect(() => engine.apply(plan), throwsA(isA<CleanupException>()));
    expect(localeFiles(), edited);
  });

  test('a project without translation calls never loses keys', () async {
    for (final f in Directory(
      p.join(project.path, 'lib'),
    ).listSync(recursive: true).whereType<File>()) {
      f.writeAsStringSync('// no translations here\n');
    }
    final before = localeFiles();
    final run = await runCli(['clean', '--yes'], projectRoot: project.path);
    expect(run.exitCode, 0, reason: '$run');
    expect(localeFiles(), before);
  });
}
