import 'dart:io';

import '../configuration/l10n_sweep_config.dart';
import '../models/analysis_issue.dart';
import '../models/analysis_report.dart';
import '../models/source_location.dart';
import '../models/unused_key_result.dart';
import '../parsers/dart_source_parser.dart';
import '../parsers/translation_catalog.dart';
import '../utils/path_matcher.dart';
import 'dynamic_key_analyzer.dart';
import 'project_index.dart';
import 'unused_key_detector.dart';

/// The result of [LocalizationAnalyzer.analyze]: the report plus the parsed
/// locale files, which the cleanup engine needs.
class AnalysisResult {
  const AnalysisResult(this.report, this.catalog);

  final AnalysisReport report;
  final TranslationCatalog catalog;
}

/// Entry point of the analysis engine. Independent of the CLI, so it can be
/// embedded in build tools, IDE plugins or CI scripts.
///
/// ```dart
/// final config = const ConfigLoader().load('path/to/app').config;
/// final result = LocalizationAnalyzer(config).analyze();
/// for (final key in result.report.unusedKeys) {
///   print(key.key);
/// }
/// ```
class LocalizationAnalyzer {
  LocalizationAnalyzer(this.config, {DartSourceParser? parser})
    : _parser =
          parser ??
          DartSourceParser(translationFunctions: config.translationFunctions);

  final L10nSweepConfig config;
  final DartSourceParser _parser;

  /// Reads the project from disk and analyzes it. Never writes files.
  AnalysisResult analyze() {
    final stopwatch = Stopwatch()..start();
    final catalog = TranslationCatalog.load(
      projectRoot: config.projectRoot,
      translationsPath: config.translationsPath,
      primaryLocale: config.primaryLocale,
    );
    final issues = <AnalysisIssue>[];
    for (final sourcePath in config.sourcePaths) {
      final type = FileSystemEntity.typeSync(
        '${config.projectRoot}${Platform.pathSeparator}$sourcePath',
      );
      if (type == FileSystemEntityType.notFound) {
        issues.add(
          AnalysisIssue.warning(
            'source_path_missing',
            'Source path "$sourcePath" does not exist',
          ),
        );
      }
    }
    final sources = DartSourceCollector(config).collect();
    final indexes = <FileIndex>[];
    for (final source in sources) {
      String content;
      try {
        content = File(source.absolutePath).readAsStringSync();
      } on FileSystemException catch (e) {
        issues.add(
          AnalysisIssue.warning(
            'unreadable_file',
            'Cannot read Dart file: ${e.message}',
            at: SourceLocation(source.path, 1, 1),
          ),
        );
        continue;
      } on FormatException {
        issues.add(
          AnalysisIssue.warning(
            'invalid_encoding',
            'Dart file is not valid UTF-8 and was skipped',
            at: SourceLocation(source.path, 1, 1),
          ),
        );
        continue;
      }
      indexes.add(
        _parser.parse(
          path: source.path,
          content: content,
          isUsageSource: source.isUsageSource,
        ),
      );
    }
    _parser.retainOnly({for (final s in sources) s.path});
    if (sources.where((s) => s.isUsageSource).isEmpty) {
      issues.add(
        const AnalysisIssue.warning(
          'no_dart_sources',
          'No Dart source files were scanned. Every key will look unused; '
              'check "source_paths" and "excluded_paths".',
        ),
      );
    }
    final report = buildReport(
      config: config,
      catalog: catalog,
      fileIndexes: indexes,
      extraIssues: issues,
      elapsed: stopwatch.elapsed,
    );
    return AnalysisResult(report, catalog);
  }

  /// Analyzes in-memory sources. Paths are project-relative.
  ///
  /// Useful for tools that hold files in memory, such as editors.
  static AnalysisResult analyzeSources({
    required L10nSweepConfig config,
    required Map<String, String> dartSources,
    required Map<String, String> translationSources,
  }) {
    final stopwatch = Stopwatch()..start();
    final catalog = TranslationCatalog.fromSources(
      translationSources,
      primaryLocale: config.primaryLocale,
    );
    final excluded = PathMatcher(config.excludedPaths);
    final parser = DartSourceParser(
      translationFunctions: config.translationFunctions,
    );
    final indexes = [
      for (final entry in dartSources.entries)
        parser.parse(
          path: entry.key,
          content: entry.value,
          isUsageSource: !excluded.matches(entry.key),
        ),
    ];
    final report = buildReport(
      config: config,
      catalog: catalog,
      fileIndexes: indexes,
      extraIssues: const [],
      elapsed: stopwatch.elapsed,
    );
    return AnalysisResult(report, catalog);
  }

  /// Combines parsed sources and locale files into a report.
  static AnalysisReport buildReport({
    required L10nSweepConfig config,
    required TranslationCatalog catalog,
    required List<FileIndex> fileIndexes,
    required List<AnalysisIssue> extraIssues,
    required Duration elapsed,
  }) {
    final index = ProjectIndex(fileIndexes);
    final resolver = KeyResolver(index);
    final sinks = [
      for (final sink in index.sinks)
        ResolvedSink(sink, resolver.resolve(sink.key)),
    ];

    final weakLiterals = <String>{...index.literals};
    for (final name in index.referencedNames) {
      final declared = index.declaredLiterals[name];
      if (declared != null) weakLiterals.addAll(declared);
    }

    final detection = UnusedKeyDetector(
      config,
    ).classify(catalog: catalog, sinks: sinks, weakLiterals: weakLiterals);

    final issues = <AnalysisIssue>[
      ...catalog.issues,
      for (final f in catalog.files) ...f.issues,
      for (final f in fileIndexes) ...f.issues,
      ...extraIssues,
    ];
    // Situations in which "no reference found" proves nothing.
    String? distrust;
    final invalidPrimary = catalog.primary != null && !catalog.primary!.isValid;
    final usageFileCount = fileIndexes.where((f) => f.isUsageSource).length;
    if (invalidPrimary) {
      issues.add(
        AnalysisIssue.error(
          'primary_locale_invalid',
          'The primary locale file ${catalog.primary!.path} is invalid; keys '
              'cannot be classified reliably.',
        ),
      );
      distrust = 'the primary locale file is invalid';
    } else if (usageFileCount == 0) {
      distrust = 'no Dart source files were scanned';
    } else if (index.sinks.isEmpty) {
      issues.add(
        const AnalysisIssue.warning(
          'no_translation_calls',
          'No easy_localization translation calls were found. If the app '
              'uses wrapper functions, list them under translation_functions.',
        ),
      );
      distrust = 'no translation calls were found in the scanned code';
    }
    if (distrust != null) {
      for (final key in detection.keys) {
        if (key.status == KeyStatus.unused) {
          key.status = KeyStatus.potentiallyUnused;
          key.reasons.insert(0, 'not verified: $distrust');
        }
      }
    }

    final byKey = {for (final k in detection.keys) k.key: k};
    final files = <LocaleFileSummary>[];
    final primary = catalog.primary;
    for (final file in catalog.files) {
      final isPrimary = identical(file, primary);
      files.add(
        LocaleFileSummary(
          locale: file.locale,
          path: file.path,
          isPrimary: isPrimary,
          isValid: file.isValid,
          keyCount: file.entries.length,
          unusedCount: file.entries.keys
              .where((k) => byKey[k]?.status == KeyStatus.unused)
              .length,
          missingKeys: isPrimary || primary == null || !file.isValid
              ? const []
              : [
                  for (final k in primary.entries.keys)
                    if (!file.entries.containsKey(k) &&
                        byKey[k]?.status != KeyStatus.excluded)
                      k,
                ],
          extraKeys: isPrimary || primary == null
              ? const []
              : [
                  for (final k in file.entries.keys)
                    if (!primary.entries.containsKey(k)) k,
                ],
        ),
      );
    }

    final dynamicUsages = [
      for (final entry in detection.dynamicPatterns.entries)
        DynamicKeyUsage(entry.key, entry.value)
          ..matchedKeys = detection.keys
              .where((k) => entry.key.matches(k.key))
              .length,
    ];

    return AnalysisReport(
      projectRoot: config.projectRoot,
      configFile: config.configFile,
      translationsPath: config.translationsPath,
      primaryLocale: primary?.locale,
      localeFiles: files,
      keys: detection.keys,
      dynamicUsages: dynamicUsages,
      unresolvedReferences: detection.unresolved
        ..sort((a, b) => a.location.compareTo(b.location)),
      undefinedKeys: detection.undefinedKeys,
      issues: issues,
      stats: AnalysisStats(
        dartFiles: fileIndexes.length,
        usageFiles: usageFileCount,
        translationCalls: index.sinks.length,
        elapsed: elapsed,
      ),
      allowUnresolvedReferences: config.safety.allowUnresolvedReferences,
    );
  }
}
