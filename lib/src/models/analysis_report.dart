import 'analysis_issue.dart';
import 'localization_usage.dart';
import 'source_location.dart';
import 'unused_key_result.dart';

/// Per-file summary of a locale file.
class LocaleFileSummary {
  const LocaleFileSummary({
    required this.locale,
    required this.path,
    required this.isPrimary,
    required this.isValid,
    required this.keyCount,
    required this.unusedCount,
    required this.missingKeys,
    required this.extraKeys,
  });

  final String locale;
  final String path;
  final bool isPrimary;
  final bool isValid;
  final int keyCount;

  /// Keys in this file classified as definitely unused.
  final int unusedCount;

  /// Keys in the primary locale that this file lacks.
  final List<String> missingKeys;

  /// Keys in this file that the primary locale lacks.
  final List<String> extraKeys;

  Map<String, Object?> toJson() => {
    'locale': locale,
    'path': path,
    'primary': isPrimary,
    'valid': isValid,
    'keys': keyCount,
    'unused': unusedCount,
    'missing_keys': missingKeys,
    'extra_keys': extraKeys,
  };
}

/// A dynamic key shape and where it is built.
class DynamicKeyUsage {
  DynamicKeyUsage(this.pattern, this.locations);

  final KeyPattern pattern;
  final List<SourceLocation> locations;

  /// Number of known keys the pattern matches.
  int matchedKeys = 0;

  Map<String, Object?> toJson() => {
    'pattern': pattern.display,
    'matched_keys': matchedKeys,
    'locations': [for (final l in locations) l.toJson()],
  };
}

class AnalysisStats {
  const AnalysisStats({
    required this.dartFiles,
    required this.usageFiles,
    required this.translationCalls,
    required this.elapsed,
  });

  /// Dart files parsed, including declaration-only files.
  final int dartFiles;

  /// Dart files scanned for translation calls.
  final int usageFiles;
  final int translationCalls;
  final Duration elapsed;

  Map<String, Object?> toJson() => {
    'dart_files': dartFiles,
    'usage_files': usageFiles,
    'translation_calls': translationCalls,
    'elapsed_ms': elapsed.inMilliseconds,
  };
}

/// The complete result of analysing a project.
class AnalysisReport {
  AnalysisReport({
    required this.projectRoot,
    required this.configFile,
    required this.translationsPath,
    required this.primaryLocale,
    required this.localeFiles,
    required this.keys,
    required this.dynamicUsages,
    required this.unresolvedReferences,
    required this.undefinedKeys,
    required this.issues,
    required this.stats,
    required this.allowUnresolvedReferences,
  });

  static const schemaVersion = 1;

  final String projectRoot;
  final String? configFile;
  final String translationsPath;
  final String? primaryLocale;
  final List<LocaleFileSummary> localeFiles;

  /// Every key found in any locale file, primary locale order first.
  final List<KeyClassification> keys;
  final List<DynamicKeyUsage> dynamicUsages;
  final List<UnresolvedReference> unresolvedReferences;

  /// Keys referenced in code that no locale file defines.
  final Map<String, List<SourceLocation>> undefinedKeys;
  final List<AnalysisIssue> issues;
  final AnalysisStats stats;
  final bool allowUnresolvedReferences;

  Iterable<KeyClassification> withStatus(KeyStatus status) =>
      keys.where((k) => k.status == status);

  /// Keys that `clean --yes` may remove.
  List<KeyClassification> get unusedKeys =>
      keys.where((k) => k.isSafeToRemove).toList();

  /// Unused keys that exist only in non-primary locales.
  List<KeyClassification> get orphanUnusedKeys =>
      keys.where((k) => k.status == KeyStatus.unused && !k.inPrimary).toList();

  List<KeyClassification> get potentiallyUnusedKeys =>
      withStatus(KeyStatus.potentiallyUnused).toList();

  List<KeyClassification> get dynamicKeys =>
      withStatus(KeyStatus.dynamicallyUsed).toList();

  List<KeyClassification> get usedKeys => withStatus(KeyStatus.used).toList();

  List<KeyClassification> get excludedKeys =>
      withStatus(KeyStatus.excluded).toList();

  List<UnresolvedReference> get blockingUnresolved => allowUnresolvedReferences
      ? const []
      : unresolvedReferences.where((r) => !r.acknowledged).toList();

  int get missingTranslationCount =>
      localeFiles.fold(0, (sum, f) => sum + f.missingKeys.length);

  /// Keys the analyzer cannot classify with confidence.
  int get uncertainCount =>
      dynamicKeys.length +
      potentiallyUnusedKeys.length +
      unresolvedReferences.where((r) => !r.acknowledged).length;

  List<AnalysisIssue> get errors =>
      issues.where((i) => i.severity == IssueSeverity.error).toList();

  List<AnalysisIssue> get warnings =>
      issues.where((i) => i.severity == IssueSeverity.warning).toList();

  bool get hasErrors => errors.isNotEmpty;

  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'tool': 'l10n_sweep',
    'project_root': projectRoot,
    'config_file': configFile,
    'translations_path': translationsPath,
    'primary_locale': primaryLocale,
    'summary': {
      'translation_files': localeFiles.length,
      'total_keys': keys.length,
      'used_keys': usedKeys.length,
      'unused_keys': unusedKeys.length,
      'orphan_unused_keys': orphanUnusedKeys.length,
      'potentially_unused_keys': potentiallyUnusedKeys.length,
      'dynamic_keys': dynamicKeys.length,
      'excluded_keys': excludedKeys.length,
      'missing_translations': missingTranslationCount,
      'undefined_keys': undefinedKeys.length,
      'unresolved_references': unresolvedReferences.length,
      'blocking_unresolved_references': blockingUnresolved.length,
    },
    'files': [for (final f in localeFiles) f.toJson()],
    'unused_keys': [for (final k in unusedKeys) k.toJson()],
    'orphan_unused_keys': [for (final k in orphanUnusedKeys) k.toJson()],
    'potentially_unused_keys': [
      for (final k in potentiallyUnusedKeys) k.toJson(),
    ],
    'dynamic_keys': [for (final k in dynamicKeys) k.toJson()],
    'excluded_keys': [for (final k in excludedKeys) k.key],
    'used_keys': [for (final k in usedKeys) k.key],
    'dynamic_patterns': [for (final d in dynamicUsages) d.toJson()],
    'unresolved_references': [for (final r in unresolvedReferences) r.toJson()],
    'undefined_keys': [
      for (final entry in undefinedKeys.entries)
        {
          'key': entry.key,
          'locations': [for (final l in entry.value) l.toJson()],
        },
    ],
    'warnings': [for (final w in warnings) w.toJson()],
    'errors': [for (final e in errors) e.toJson()],
    'stats': stats.toJson(),
  };
}
