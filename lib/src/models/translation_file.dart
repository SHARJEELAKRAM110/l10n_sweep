import '../parsers/json_document.dart';
import 'analysis_issue.dart';
import 'localization_key.dart';

/// One translatable unit read from a locale file.
class TranslationEntry {
  TranslationEntry({
    required this.key,
    required this.member,
    required this.rawValue,
    required this.line,
    required this.linkedKeys,
  });

  final LocalizationKey key;

  /// The JSON member that holds this unit.
  final JsonMember member;

  /// Exact source text of the value, used to verify edits.
  final String rawValue;

  /// 1-based line of the member name.
  final int line;

  /// Keys referenced through easy_localization linked translations
  /// (`@:other.key`, `@.upper:other.key`).
  final Set<String> linkedKeys;
}

/// A parsed locale file such as `assets/translations/en.json`.
class TranslationFile {
  TranslationFile({
    required this.locale,
    required this.path,
    required this.absolutePath,
    required this.originalText,
    required this.hadBom,
    required this.document,
    required this.entries,
    required this.issues,
  });

  /// Locale code derived from the file name, for example `en` or `en-US`.
  final String locale;

  /// Path relative to the project root.
  final String path;
  final String absolutePath;

  /// Exact file contents as read from disk (including any BOM).
  final String originalText;
  final bool hadBom;

  /// `null` when the file could not be parsed.
  final JsonDocument? document;

  /// Translatable units keyed by dot-notation key, in file order.
  final Map<String, TranslationEntry> entries;
  final List<AnalysisIssue> issues;

  bool get isValid => document != null;

  String get fileName => path.split('/').last;
}
