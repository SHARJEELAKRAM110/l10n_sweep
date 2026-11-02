import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/analysis_issue.dart';
import '../models/source_location.dart';
import '../models/translation_file.dart';
import '../utils/path_matcher.dart';
import 'json_translation_parser.dart';

/// All locale files of a project and the chosen primary locale.
class TranslationCatalog {
  TranslationCatalog._(this.files, this.primary, this.issues);

  /// Locale files sorted with the primary locale first.
  final List<TranslationFile> files;
  final TranslationFile? primary;

  /// Catalog-level problems (missing directory, missing primary locale).
  /// File-level problems are on each [TranslationFile].
  final List<AnalysisIssue> issues;

  static final _localeName = RegExp(
    r'^([a-zA-Z]{2,3}(?:[-_][a-zA-Z0-9]{2,8})*)\.(json|jsonc)$',
  );

  /// Returns the locale code for a file name such as `en-US.json`.
  static String? localeFromFileName(String fileName) =>
      _localeName.firstMatch(fileName)?.group(1);

  /// Reads every `<locale>.json` file in [translationsPath].
  static TranslationCatalog load({
    required String projectRoot,
    required String translationsPath,
    String? primaryLocale,
  }) {
    final dir = Directory(p.join(projectRoot, translationsPath));
    if (!dir.existsSync()) {
      return TranslationCatalog._(const [], null, [
        AnalysisIssue.error(
          'translations_not_found',
          'Translations directory "$translationsPath" does not exist. Set '
              '"translations_path" in l10n_sweep.yaml.',
        ),
      ]);
    }
    final sources = <String, String>{};
    final issues = <AnalysisIssue>[];
    final entries = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in entries) {
      final name = p.basename(file.path);
      if (!name.endsWith('.json') && !name.endsWith('.jsonc')) continue;
      final relative = relativePosix(file.path, projectRoot);
      try {
        sources[relative] = utf8.decode(file.readAsBytesSync());
      } on FormatException {
        issues.add(
          AnalysisIssue.error(
            'invalid_encoding',
            'File is not valid UTF-8',
            at: SourceLocation(relative, 1, 1),
          ),
        );
      } on FileSystemException catch (e) {
        issues.add(
          AnalysisIssue.error(
            'unreadable_file',
            'Cannot read file: ${e.message}',
            at: SourceLocation(relative, 1, 1),
          ),
        );
      }
    }
    final catalog = fromSources(
      sources,
      projectRoot: projectRoot,
      primaryLocale: primaryLocale,
    );
    return TranslationCatalog._(catalog.files, catalog.primary, [
      ...issues,
      ...catalog.issues,
    ]);
  }

  /// Builds a catalog from in-memory file contents keyed by relative path.
  static TranslationCatalog fromSources(
    Map<String, String> sources, {
    String projectRoot = '',
    String? primaryLocale,
  }) {
    const parser = JsonTranslationParser();
    final issues = <AnalysisIssue>[];
    final files = <TranslationFile>[];
    final seenLocales = <String, String>{};
    for (final entry in sources.entries) {
      final relative = entry.key.replaceAll(r'\', '/');
      final name = relative.split('/').last;
      final locale = localeFromFileName(name);
      if (locale == null) {
        issues.add(
          AnalysisIssue.warning(
            'unrecognized_locale_file',
            'Skipped "$name": the file name is not a locale code such as '
                'en.json or en-US.json',
            at: SourceLocation(relative, 1, 1),
          ),
        );
        continue;
      }
      final normalized = _normalize(locale);
      final clash = seenLocales[normalized];
      if (clash != null) {
        issues.add(
          AnalysisIssue.warning(
            'duplicate_locale',
            'Locale "$locale" is defined by both $clash and $relative',
            at: SourceLocation(relative, 1, 1),
          ),
        );
      }
      seenLocales[normalized] = relative;
      files.add(
        parser.parse(
          locale: locale,
          path: relative,
          absolutePath: projectRoot.isEmpty
              ? relative
              : p.join(projectRoot, relative),
          content: entry.value,
        ),
      );
    }

    TranslationFile? primary;
    if (files.isEmpty) {
      issues.add(
        const AnalysisIssue.error(
          'no_translation_files',
          'No <locale>.json files were found in the translations directory',
        ),
      );
    } else if (primaryLocale != null) {
      final wanted = _normalize(primaryLocale);
      primary = files.where((f) => _normalize(f.locale) == wanted).firstOrNull;
      if (primary == null) {
        issues.add(
          AnalysisIssue.error(
            'primary_locale_missing',
            'Primary locale "$primaryLocale" has no file. Available: '
                '${files.map((f) => f.locale).join(', ')}',
          ),
        );
      }
    } else {
      primary =
          files.where((f) => _normalize(f.locale) == 'en').firstOrNull ??
          (List.of(files)..sort((a, b) => a.locale.compareTo(b.locale))).first;
    }

    if (primary != null) {
      files
        ..remove(primary)
        ..sort((a, b) => a.locale.compareTo(b.locale))
        ..insert(0, primary);
    }
    return TranslationCatalog._(files, primary, issues);
  }

  static String _normalize(String locale) =>
      locale.replaceAll('_', '-').toLowerCase();
}
