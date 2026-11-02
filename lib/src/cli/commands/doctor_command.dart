import 'dart:io';

import 'package:path/path.dart' as p;

import '../../analyzer/localization_analyzer.dart';
import '../../configuration/config_loader.dart';
import '../../models/analysis_issue.dart';
import '../../parsers/dart_source_parser.dart';
import 'base_command.dart';

enum _Level { ok, info, warning, failure }

class _Check {
  _Check(this.level, this.title, [this.details = const []]);

  final _Level level;
  final String title;
  final List<String> details;
}

class DoctorCommand extends L10nSweepCommand {
  DoctorCommand(super.env);

  @override
  String get name => 'doctor';

  @override
  String get description =>
      'Check the project setup and report patterns the analyzer cannot '
      'follow.';

  static final _getxTr = RegExp(r'''['"]\s*\.tr\b(?!\s*\()''');
  static final _genL10n = RegExp(r'\bAppLocalizations\.of\(');

  @override
  int execute() {
    final root = projectRoot;
    final checks = <_Check>[];

    LoadedConfig loaded;
    try {
      loaded = const ConfigLoader().load(root, configPath: configPath);
    } on ConfigException catch (e) {
      checks.add(
        _Check(_Level.failure, 'Configuration is invalid', [e.message]),
      );
      _print(checks);
      return ExitCode.checkFailed;
    }
    final config = loaded.config;
    final detected = loaded.detected;

    // Project structure.
    if (!detected.hasPubspec) {
      checks.add(_Check(_Level.failure, 'pubspec.yaml not found in $root'));
    } else if (!detected.isFlutter) {
      checks.add(
        _Check(
          _Level.warning,
          'pubspec.yaml does not depend on the Flutter SDK',
        ),
      );
    } else {
      checks.add(
        _Check(
          _Level.ok,
          'Flutter project${detected.packageName == null ? '' : ' "${detected.packageName}"'}',
        ),
      );
    }
    checks.add(
      detected.hasEasyLocalization
          ? _Check(
              _Level.ok,
              'easy_localization dependency (${detected.easyLocalizationConstraint})',
            )
          : _Check(
              _Level.warning,
              'easy_localization is not listed in pubspec.yaml dependencies',
            ),
    );

    // Configuration.
    checks.add(
      _Check(
        loaded.warnings.isEmpty ? _Level.ok : _Level.warning,
        config.configFile == null
            ? 'No configuration file; using detected defaults '
                  '(run "l10n_sweep init" to create one)'
            : 'Configuration: ${p.relative(config.configFile!, from: root)}',
        loaded.warnings,
      ),
    );

    // Translations directory.
    final translationsDir = Directory(p.join(root, config.translationsPath));
    if (!translationsDir.existsSync()) {
      checks.add(
        _Check(
          _Level.failure,
          'Translations directory "${config.translationsPath}" not found',
        ),
      );
    } else {
      checks.add(
        _Check(_Level.ok, 'Translations directory: ${config.translationsPath}'),
      );
      final declared = detected.declaredAssets.any((asset) {
        final normalized = asset.replaceAll(r'\', '/');
        final dir = config.translationsPath;
        return normalized == dir ||
            normalized == '$dir/' ||
            (normalized.endsWith('/') && dir.startsWith(normalized));
      });
      if (detected.hasPubspec && !declared) {
        checks.add(
          _Check(
            _Level.warning,
            '"${config.translationsPath}/" is not listed under flutter: assets '
            'in pubspec.yaml',
            ['easy_localization cannot load files that are not bundled.'],
          ),
        );
      }
    }

    // EasyLocalization widget.
    if (detected.easyLocalizationPath != null) {
      final widgetPath = detected.easyLocalizationPath!.replaceAll(
        RegExp(r'/+$'),
        '',
      );
      checks.add(
        widgetPath == config.translationsPath
            ? _Check(
                _Level.ok,
                'EasyLocalization(path: \'$widgetPath\') matches',
              )
            : _Check(
                _Level.warning,
                'EasyLocalization uses path "$widgetPath" but '
                'translations_path is "${config.translationsPath}"',
              ),
      );
    } else if (detected.hasEasyLocalization) {
      checks.add(
        _Check(
          _Level.info,
          'EasyLocalization(...) widget not found in lib/ (path not verified)',
        ),
      );
    }

    // Source paths.
    final missingSources = config.sourcePaths
        .where(
          (s) =>
              FileSystemEntity.typeSync(p.join(root, s)) ==
              FileSystemEntityType.notFound,
        )
        .toList();
    final sources = DartSourceCollector(config).collect();
    if (missingSources.length == config.sourcePaths.length) {
      checks.add(
        _Check(
          _Level.failure,
          'No source path exists: ${config.sourcePaths.join(', ')}',
        ),
      );
    } else {
      checks.add(
        _Check(
          missingSources.isEmpty ? _Level.ok : _Level.warning,
          'Source paths: ${sources.where((s) => s.isUsageSource).length} Dart '
          'files scanned, ${sources.where((s) => !s.isUsageSource).length} '
          'excluded',
          [for (final s in missingSources) 'Missing: $s'],
        ),
      );
    }

    // Full analysis: JSON validity, primary locale, references.
    if (translationsDir.existsSync()) {
      final report = LocalizationAnalyzer(config).analyze().report;
      final invalid = report.localeFiles.where((f) => !f.isValid).toList();
      final jsonIssues = report.issues
          .where(
            (i) =>
                i.location != null &&
                i.location!.path.startsWith(config.translationsPath),
          )
          .toList();
      final jsonErrors = jsonIssues
          .where((i) => i.severity == IssueSeverity.error)
          .toList();
      final jsonWarnings = jsonIssues
          .where((i) => i.severity == IssueSeverity.warning)
          .toList();
      if (report.localeFiles.isEmpty) {
        checks.add(_Check(_Level.failure, 'No <locale>.json files found'));
      } else {
        checks.add(
          _Check(
            invalid.isEmpty
                ? (jsonWarnings.isEmpty ? _Level.ok : _Level.warning)
                : _Level.failure,
            invalid.isEmpty
                ? '${report.localeFiles.length} locale files are valid JSON '
                      '(${report.localeFiles.map((f) => f.locale).join(', ')})'
                : '${invalid.length} locale '
                      '${invalid.length == 1 ? 'file is' : 'files are'} invalid',
            [
              for (final e in jsonErrors) e.toString(),
              for (final w in jsonWarnings) w.toString(),
            ],
          ),
        );
      }
      final primaryError = report.errors
          .where((e) => e.code.startsWith('primary_locale'))
          .toList();
      if (primaryError.isNotEmpty) {
        checks.add(
          _Check(_Level.failure, 'Primary locale problem', [
            for (final e in primaryError) e.message,
          ]),
        );
      } else if (report.primaryLocale != null) {
        checks.add(
          _Check(
            _Level.ok,
            'Primary locale: ${report.primaryLocale}'
            '${config.primaryLocale == null ? ' (detected)' : ''}',
          ),
        );
      }
      if (report.stats.translationCalls == 0) {
        checks.add(
          _Check(_Level.warning, 'No translation calls found', [
            'Expected calls such as \'key\'.tr(), tr(\'key\') or '
                'context.tr(\'key\').',
            'Custom wrappers can be listed under translation_functions.',
          ]),
        );
      } else {
        checks.add(
          _Check(
            _Level.ok,
            '${report.stats.translationCalls} translation calls found',
          ),
        );
      }
      final unresolved = report.unresolvedReferences
          .where((r) => !r.acknowledged)
          .toList();
      if (unresolved.isNotEmpty) {
        checks.add(
          _Check(
            _Level.warning,
            '${unresolved.length} translation '
            '${unresolved.length == 1 ? 'call has' : 'calls have'} keys the '
            'analyzer cannot determine',
            [
              for (final r in unresolved.take(10))
                '${r.location}  ${r.snippet}',
              if (unresolved.length > 10)
                '... and ${unresolved.length - 10} more',
              'Annotate with "// l10n_sweep:keys <pattern>" or '
                  '"// l10n_sweep:ignore", or set dynamic_key_patterns.',
            ],
          ),
        );
      }
      if (report.undefinedKeys.isNotEmpty) {
        checks.add(
          _Check(
            _Level.warning,
            '${report.undefinedKeys.length} keys used in code are missing '
            'from the primary locale',
            [
              for (final e in report.undefinedKeys.entries.take(10))
                '${e.key}  (${e.value.first})',
            ],
          ),
        );
      }
    }

    // Patterns l10n_sweep does not understand.
    final unsupported = <String>[];
    for (final source in sources.where((s) => s.isUsageSource)) {
      String content;
      try {
        content = File(source.absolutePath).readAsStringSync();
      } on FileSystemException {
        continue;
      }
      if (_getxTr.hasMatch(content)) {
        unsupported.add('${source.path}: GetX-style ".tr" getter');
      }
      if (_genL10n.hasMatch(content)) {
        unsupported.add('${source.path}: Flutter gen-l10n (AppLocalizations)');
      }
    }
    final arbFiles = Directory(root).existsSync()
        ? _findArb(Directory(root))
        : const <String>[];
    if (arbFiles.isNotEmpty) {
      unsupported.add(
        '.arb files found (${arbFiles.first}); only JSON is analyzed',
      );
    }
    if (unsupported.isNotEmpty) {
      checks.add(
        _Check(
          _Level.info,
          'Localization patterns outside easy_localization were found',
          unsupported.take(10).toList(),
        ),
      );
    }

    _print(checks);
    final failures = checks.where((c) => c.level == _Level.failure).length;
    final warnings = checks.where((c) => c.level == _Level.warning).length;
    logger.info('');
    if (failures > 0) {
      logger.info(
        logger.ansi.red(
          '$failures ${failures == 1 ? 'problem' : 'problems'} must be fixed.',
        ),
      );
      return ExitCode.checkFailed;
    }
    logger.info(
      warnings == 0
          ? logger.ansi.green('No issues found.')
          : logger.ansi.yellow(
              'No blocking problems; $warnings '
              '${warnings == 1 ? 'warning' : 'warnings'}.',
            ),
    );
    return ExitCode.success;
  }

  List<String> _findArb(Directory root) {
    final found = <String>[];
    for (final dirName in ['lib', 'l10n', 'assets']) {
      final dir = Directory(p.join(root.path, dirName));
      if (!dir.existsSync()) continue;
      for (final e in dir.listSync(recursive: true)) {
        if (e is File && e.path.endsWith('.arb')) {
          found.add(p.relative(e.path, from: root.path).replaceAll(r'\', '/'));
          if (found.length >= 3) return found;
        }
      }
    }
    return found;
  }

  void _print(List<_Check> checks) {
    final ansi = logger.ansi;
    logger.info(ansi.bold('l10n_sweep doctor'));
    logger.info('');
    for (final check in checks) {
      final symbol = switch (check.level) {
        _Level.ok => ansi.green('[ok]  '),
        _Level.info => ansi.cyan('[info]'),
        _Level.warning => ansi.yellow('[warn]'),
        _Level.failure => ansi.red('[fail]'),
      };
      logger.info('$symbol ${check.title}');
      for (final d in check.details) {
        logger.info(ansi.dim('       $d'));
      }
    }
  }
}
