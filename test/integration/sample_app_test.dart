import 'dart:convert';
import 'dart:io';

import 'package:l10n_sweep/l10n_sweep.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../cli_harness.dart';
import '../helpers.dart';

const _expectedUnused = [
  'home.description',
  'profile.edit_button',
  'settings.experimental_feature',
  'errors.timeout',
  'unused_message',
  'old.banner',
  'old.footer',
];

void main() {
  late Directory project;

  setUp(() => project = copyFixture('sample_flutter_app'));
  tearDown(() => deleteQuietly(project));

  Map<String, dynamic> readJson(String locale) =>
      jsonDecode(
            File(
              p.join(project.path, 'assets/translations/$locale.json'),
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;

  group('analysis of the sample app', () {
    late AnalysisReport report;

    setUp(() {
      final config = const ConfigLoader().load(project.path).config;
      report = LocalizationAnalyzer(config).analyze().report;
    });

    test('classifies every key', () {
      expect(report.errors, isEmpty);
      expect(report.unresolvedReferences, isEmpty);
      expect(report.unusedKeys.map((k) => k.key), _expectedUnused);
      expect(report.orphanUnusedKeys.map((k) => k.key), ['ur_only']);
      expect(keysWith(report, KeyStatus.used), {
        'app_name',
        'home.title',
        'profile.title',
        'items_count',
        'greeting',
        'settings.language',
        'errors.network',
        'tabs.home',
        'tabs.settings',
        'actions.increment',
        'onboarding.step_1',
        'onboarding.step_2',
        'legacy.translation',
      });
      expect(keysWith(report, KeyStatus.dynamicallyUsed), {
        'sections.news',
        'sections.events',
      });
      expect(keysWith(report, KeyStatus.excluded), {'app.version'});
    });

    test('reports locale differences', () {
      final ur = report.localeFiles.firstWhere((f) => f.locale == 'ur');
      expect(ur.missingKeys, ['settings.experimental_feature']);
      expect(ur.extraKeys, ['ur_only']);
      expect(report.localeFiles.first.isPrimary, isTrue);
      expect(report.localeFiles.first.unusedCount, 7);
    });

    test('scanned the generated keys only for declarations', () {
      expect(report.stats.dartFiles, 4);
      expect(report.stats.usageFiles, 3);
    });
  });

  group('CLI', () {
    test('analyze prints the summary and exits 0', () async {
      final run = await runCli(['analyze'], projectRoot: project.path);
      expect(run.exitCode, 0, reason: '$run');
      expect(run.out, contains('Unused keys:'));
      expect(run.out, contains('Translation files:'));
      for (final key in _expectedUnused) {
        expect(run.out, contains(key));
      }
      expect(run.out, contains('Analysis completed successfully.'));
    });

    test('analyze --fail-on-* gates', () async {
      for (final flag in [
        '--fail-on-unused',
        '--fail-on-missing',
        '--fail-on-uncertain',
      ]) {
        final run = await runCli(['analyze', flag], projectRoot: project.path);
        expect(run.exitCode, 1, reason: '$flag\n$run');
      }
      final ok = await runCli([
        'analyze',
        '--fail-on-undefined',
      ], projectRoot: project.path);
      expect(ok.exitCode, 0, reason: '$ok');
    });

    test('analyze --format json is parseable', () async {
      final run = await runCli([
        'analyze',
        '--format',
        'json',
      ], projectRoot: project.path);
      final json = jsonDecode(run.out) as Map<String, dynamic>;
      expect(json['schema_version'], 1);
      final summary = json['summary'] as Map<String, dynamic>;
      expect(summary['unused_keys'], 7);
      expect(summary['missing_translations'], 1);
      expect(
        (json['unused_keys'] as List).map((k) => (k as Map)['key']),
        _expectedUnused,
      );
    });

    test('report writes JSON and Markdown files', () async {
      final json = await runCli(['report'], projectRoot: project.path);
      expect(json.exitCode, 0, reason: '$json');
      final jsonFile = File(
        p.join(project.path, 'build', 'l10n_sweep_report.json'),
      );
      expect(
        jsonDecode(jsonFile.readAsStringSync()),
        isA<Map<String, dynamic>>(),
      );

      final md = await runCli([
        'report',
        '--format',
        'markdown',
        '--output',
        'build/report.md',
      ], projectRoot: project.path);
      expect(md.exitCode, 0, reason: '$md');
      final markdown = File(
        p.join(project.path, 'build', 'report.md'),
      ).readAsStringSync();
      expect(markdown, contains('| Unused keys | 7 |'));
      expect(markdown, contains('`old.banner`'));
    });

    test(
      'clean --yes removes definitely unused keys from all locales',
      () async {
        final run = await runCli(['clean', '--yes'], projectRoot: project.path);
        expect(run.exitCode, 0, reason: '$run');
        expect(run.out, contains('Force cleanup'));
        expect(run.out, contains('Removed 7 keys from 2 files.'));

        final en = readJson('en');
        expect(
          en.containsKey('old'),
          isFalse,
          reason: 'emptied parent removed',
        );
        expect(en.containsKey('unused_message'), isFalse);
        expect((en['home'] as Map).keys, ['title']);
        expect((en['settings'] as Map).keys, ['language']);
        expect((en['sections'] as Map).keys, ['news', 'events']);
        expect(en['onboarding'], isNotNull);
        expect(en['legacy'], isNotNull);
        expect(en['app'], isNotNull);

        final ur = readJson('ur');
        expect(ur['app_name'], 'نمونہ ایپ');
        expect(ur.containsKey('old'), isFalse);
        // Orphan keys are never removed by --yes.
        expect(ur['ur_only'], 'صرف اردو');

        final after = await runCli([
          'analyze',
          '--fail-on-unused',
        ], projectRoot: project.path);
        expect(after.exitCode, 0, reason: '$after');
      },
    );

    test('interactive clean removes only the selected keys', () async {
      final prompter = ScriptedPrompter(
        selection: (items) => [
          'unused_message',
          'settings.experimental_feature',
        ],
        confirmAnswer: true,
      );
      final run = await runCli(
        ['clean'],
        projectRoot: project.path,
        prompter: prompter,
      );
      expect(run.exitCode, 0, reason: '$run');
      expect(prompter.preselected, _expectedUnused);
      expect(prompter.shownLabels, contains('ur_only'));
      expect(prompter.questions.single, 'Remove 2 selected keys from 2 files?');
      expect(run.out, contains('settings.experimental_feature: only in en'));
      final en = readJson('en');
      expect(en.containsKey('unused_message'), isFalse);
      expect((en['settings'] as Map).keys, ['language']);
      expect(en['old'], isNotNull);
    });

    test('doctor reports a healthy fixture', () async {
      final run = await runCli(['doctor'], projectRoot: project.path);
      expect(run.exitCode, 0, reason: '$run');
      expect(run.out, contains('[ok]   Flutter project "sample_flutter_app"'));
      expect(run.out, contains('2 locale files are valid JSON (en, ur)'));
      expect(
        run.out,
        contains("EasyLocalization(path: 'assets/translations') matches"),
      );
    });

    test('init generates a configuration that loads', () async {
      File(p.join(project.path, 'l10n_sweep.yaml')).deleteSync();
      final run = await runCli(['init'], projectRoot: project.path);
      expect(run.exitCode, 0, reason: '$run');
      final config = const ConfigLoader().load(project.path);
      expect(config.warnings, isEmpty);
      expect(config.config.translationsPath, 'assets/translations');
      expect(config.config.primaryLocale, 'en');
      expect(config.config.excludedPaths, contains('lib/generated'));

      final again = await runCli(['init'], projectRoot: project.path);
      expect(again.exitCode, 2);
      expect(again.err, contains('already exists'));
    });

    test('--version and usage errors', () async {
      final version = await runCli(['--version'], projectRoot: project.path);
      expect(version.out.trim(), startsWith('l10n_sweep '));
      final usage = await runCli(['analyse'], projectRoot: project.path);
      expect(usage.exitCode, 64);
    });
  });
}
