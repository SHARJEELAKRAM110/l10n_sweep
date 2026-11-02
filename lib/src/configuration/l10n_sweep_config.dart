import '../models/localization_usage.dart';

/// Output format of a report.
enum ReportFormat {
  console,
  json,
  markdown;

  static ReportFormat parse(String value) => switch (value.toLowerCase()) {
    'console' || 'text' => console,
    'json' => json,
    'markdown' || 'md' => markdown,
    _ => throw FormatException(
      'Unknown report format "$value". Use console, json or markdown.',
    ),
  };

  String get extension => switch (this) {
    console => 'txt',
    json => 'json',
    markdown => 'md',
  };
}

/// A custom function, method or constructor whose argument is a translation
/// key, for wrappers the analyzer cannot follow on its own.
class TranslationFunction {
  const TranslationFunction({
    required this.name,
    this.position = 0,
    this.namedArgument,
  });

  /// Function, method or class name, for example `translate` or `AppText`.
  final String name;

  /// Zero-based positional argument that holds the key.
  final int position;

  /// Named argument that holds the key. Takes precedence over [position].
  final String? namedArgument;

  Map<String, Object?> toJson() => {
    'name': name,
    'key_argument': namedArgument ?? position,
  };
}

class OutputConfig {
  const OutputConfig({this.format = ReportFormat.console, this.path});

  final ReportFormat format;

  /// Where `report` writes its file. Relative to the project root.
  final String? path;
}

class SafetyConfig {
  const SafetyConfig({
    this.createBackup = true,
    this.backupPath = '.l10n_sweep/backups',
    this.requireConfirmation = true,
    this.preserveUncertainKeys = true,
    this.allowUnresolvedReferences = false,
  });

  /// Copy every locale file before it is modified.
  final bool createBackup;

  /// Backup directory relative to the project root.
  final String backupPath;

  /// Ask "Remove selected keys? (y/N)" after interactive selection.
  final bool requireConfirmation;

  /// Hide dynamically referenced keys from interactive cleanup. They are
  /// never removed by `clean --yes` regardless of this setting.
  final bool preserveUncertainKeys;

  /// When `false` (default), translation calls whose key cannot be resolved
  /// prevent any key from being classified as definitely unused, because
  /// such a call could reference any key.
  final bool allowUnresolvedReferences;
}

class CleanupConfig {
  const CleanupConfig({this.removeEmptyParents = true});

  /// Remove an object that becomes empty because all of its keys were
  /// removed. Objects that were already empty are left alone.
  final bool removeEmptyParents;
}

/// Fully resolved configuration for one project.
class L10nSweepConfig {
  L10nSweepConfig({
    required this.projectRoot,
    this.translationsPath = 'assets/translations',
    this.primaryLocale,
    this.sourcePaths = const ['lib'],
    this.fileExtensions = const ['dart'],
    this.excludedPaths = const [],
    this.excludedKeys = const [],
    this.ignoredKeys = const [],
    this.dynamicKeyPatterns = const [],
    this.translationFunctions = const [],
    this.output = const OutputConfig(),
    this.safety = const SafetyConfig(),
    this.cleanup = const CleanupConfig(),
    this.configFile,
  });

  /// Absolute path of the Flutter project.
  final String projectRoot;

  /// Directory that holds `<locale>.json` files, relative to [projectRoot].
  final String translationsPath;

  /// Reference locale. Keys are removed based on this locale's contents.
  /// When `null`, it is detected from `EasyLocalization(fallbackLocale:)`,
  /// then `en`, then the first locale alphabetically.
  final String? primaryLocale;

  final List<String> sourcePaths;
  final List<String> fileExtensions;

  /// Paths whose files are not scanned for translation calls. Their
  /// declarations (such as generated `LocaleKeys` constants) are still read
  /// so references to them resolve.
  final List<String> excludedPaths;

  /// Keys (globs allowed) that are never reported and never removed.
  final List<String> excludedKeys;

  /// Keys (globs allowed) that are always treated as used.
  final List<String> ignoredKeys;

  /// Globs describing keys that are built at run time and must be kept,
  /// for example `onboarding.step_*`.
  final List<String> dynamicKeyPatterns;

  final List<TranslationFunction> translationFunctions;
  final OutputConfig output;
  final SafetyConfig safety;
  final CleanupConfig cleanup;

  /// The file this configuration was loaded from, if any.
  final String? configFile;

  late final List<KeyPattern> excludedKeyPatterns = excludedKeys
      .map(KeyPattern.glob)
      .toList();
  late final List<KeyPattern> ignoredKeyPatterns = ignoredKeys
      .map(KeyPattern.glob)
      .toList();
  late final List<KeyPattern> dynamicPatterns = dynamicKeyPatterns
      .map(KeyPattern.glob)
      .toList();

  L10nSweepConfig copyWith({String? primaryLocale, String? translationsPath}) =>
      L10nSweepConfig(
        projectRoot: projectRoot,
        translationsPath: translationsPath ?? this.translationsPath,
        primaryLocale: primaryLocale ?? this.primaryLocale,
        sourcePaths: sourcePaths,
        fileExtensions: fileExtensions,
        excludedPaths: excludedPaths,
        excludedKeys: excludedKeys,
        ignoredKeys: ignoredKeys,
        dynamicKeyPatterns: dynamicKeyPatterns,
        translationFunctions: translationFunctions,
        output: output,
        safety: safety,
        cleanup: cleanup,
        configFile: configFile,
      );
}
