import 'package:l10n_sweep/l10n_sweep.dart';
import 'package:l10n_sweep/src/utils/path_matcher.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  group('ConfigLoader', () {
    test('reads every option from l10n_sweep.yaml', () {
      final dir = createProject({
        'l10n_sweep.yaml': '''
l10n_sweep:
  translations_path: assets/lang/
  primary_locale: ur
  source_paths: [lib, packages/core/lib]
  file_extensions: [.dart]
  excluded_paths: [lib/generated, '**/*.g.dart']
  excluded_keys: [app.version]
  ignored_keys: [legacy.*]
  dynamic_key_patterns: ['onboarding.step_*']
  translation_functions:
    - translate
    - name: AppText
      key_argument: textKey
    - name: t
      key_argument: 1
  output:
    format: markdown
    path: build/report.md
  safety:
    create_backup: false
    backup_path: .backups
    require_confirmation: false
    preserve_uncertain_keys: false
    allow_unresolved_references: true
  cleanup:
    remove_empty_parents: false
''',
      });
      addTearDown(() => deleteQuietly(dir));
      final loaded = const ConfigLoader().load(dir.path);
      final c = loaded.config;
      expect(loaded.warnings, isEmpty);
      expect(c.translationsPath, 'assets/lang');
      expect(c.primaryLocale, 'ur');
      expect(c.sourcePaths, ['lib', 'packages/core/lib']);
      expect(c.fileExtensions, ['dart']);
      expect(c.excludedPaths, ['lib/generated', '**/*.g.dart']);
      expect(c.excludedKeys, ['app.version']);
      expect(c.ignoredKeys, ['legacy.*']);
      expect(c.dynamicKeyPatterns, ['onboarding.step_*']);
      expect(c.translationFunctions.map((f) => f.toJson()), [
        {'name': 'translate', 'key_argument': 0},
        {'name': 'AppText', 'key_argument': 'textKey'},
        {'name': 't', 'key_argument': 1},
      ]);
      expect(c.output.format, ReportFormat.markdown);
      expect(c.output.path, 'build/report.md');
      expect(c.safety.createBackup, isFalse);
      expect(c.safety.backupPath, '.backups');
      expect(c.safety.requireConfirmation, isFalse);
      expect(c.safety.preserveUncertainKeys, isFalse);
      expect(c.safety.allowUnresolvedReferences, isTrue);
      expect(c.cleanup.removeEmptyParents, isFalse);
      expect(c.configFile, endsWith('l10n_sweep.yaml'));
    });

    test('falls back to a section in pubspec.yaml', () {
      final dir = createProject({
        'pubspec.yaml': 'name: app\nl10n_sweep:\n  primary_locale: fr\n',
      });
      addTearDown(() => deleteQuietly(dir));
      final c = const ConfigLoader().load(dir.path).config;
      expect(c.primaryLocale, 'fr');
      expect(c.configFile, endsWith('pubspec.yaml'));
    });

    test('detects defaults from the project structure', () {
      final dir = createProject({
        'pubspec.yaml': '''
name: app
dependencies:
  flutter:
    sdk: flutter
  easy_localization: ^3.0.7
flutter:
  assets:
    - assets/i18n/
''',
        'assets/i18n/en.json': '{}',
        'assets/i18n/de.json': '{}',
        'lib/main.dart': '''
void main() => runApp(EasyLocalization(
  supportedLocales: const [Locale('en'), Locale('de')],
  path: 'assets/i18n',
  fallbackLocale: const Locale('de'),
  child: const App(),
));
''',
        'lib/generated/locale_keys.g.dart':
            'abstract class LocaleKeys { static const a = "a"; }',
      });
      addTearDown(() => deleteQuietly(dir));
      final loaded = const ConfigLoader().load(dir.path);
      expect(loaded.config.configFile, isNull);
      expect(loaded.config.translationsPath, 'assets/i18n');
      expect(loaded.config.primaryLocale, 'de');
      expect(loaded.detected.isFlutter, isTrue);
      expect(loaded.detected.hasEasyLocalization, isTrue);
      expect(loaded.detected.generatedKeysPaths, [
        'lib/generated/locale_keys.g.dart',
      ]);
    });

    test('warns about unknown options', () {
      final dir = createProject({
        'l10n_sweep.yaml': 'l10n_sweep:\n  primary_lokale: en\n',
      });
      addTearDown(() => deleteQuietly(dir));
      final loaded = const ConfigLoader().load(dir.path);
      expect(loaded.warnings.single, contains('primary_lokale'));
    });

    test('rejects invalid values with a clear message', () {
      for (final (yaml, message) in [
        ('l10n_sweep:\n  source_paths: {a: b}\n', 'source_paths'),
        ('l10n_sweep:\n  safety:\n    create_backup: maybe\n', 'create_backup'),
        ('l10n_sweep:\n  output:\n    format: html\n', 'html'),
        ('other: 1\n', 'l10n_sweep'),
        ('l10n_sweep: [\n', 'Invalid YAML'),
      ]) {
        final dir = createProject({'l10n_sweep.yaml': yaml});
        addTearDown(() => deleteQuietly(dir));
        expect(
          () => const ConfigLoader().load(dir.path),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              contains(message),
            ),
          ),
          reason: yaml,
        );
      }
    });
  });

  group('PathMatcher', () {
    test('matches directory prefixes', () {
      final m = PathMatcher(['lib/generated', './test/']);
      expect(m.matches('lib/generated/keys.dart'), isTrue);
      expect(m.matches('lib/generated'), isTrue);
      expect(m.matches('lib/generated_other/a.dart'), isFalse);
      expect(m.matches('test/a_test.dart'), isTrue);
    });

    test('matches globs', () {
      final m = PathMatcher(['**/*.g.dart', 'lib/*/legacy.dart']);
      expect(m.matches('lib/models/user.g.dart'), isTrue);
      expect(m.matches('user.g.dart'), isTrue);
      expect(m.matches('lib/a/legacy.dart'), isTrue);
      expect(m.matches('lib/a/b/legacy.dart'), isFalse);
    });
  });

  group('KeyPattern.glob', () {
    test('matches across dots and escapes regex characters', () {
      final p = KeyPattern.glob('onboarding.step_*');
      expect(p.matches('onboarding.step_1'), isTrue);
      expect(p.matches('onboarding.step_a.b'), isTrue);
      expect(p.matches('onboardingXstep_1'), isFalse);
      expect(KeyPattern.glob('a+b').matches('a+b'), isTrue);
    });
  });
}
