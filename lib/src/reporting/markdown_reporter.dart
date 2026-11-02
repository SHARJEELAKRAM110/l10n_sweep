import '../models/analysis_report.dart';
import '../models/unused_key_result.dart';

/// Renders an [AnalysisReport] as GitHub-flavored Markdown, suitable for
/// pull request comments and `$GITHUB_STEP_SUMMARY`.
class MarkdownReporter {
  const MarkdownReporter();

  static const _limit = 200;

  String render(AnalysisReport report) {
    final out = StringBuffer();
    final status = report.hasErrors
        ? ':x: Analysis completed with errors'
        : report.unusedKeys.isEmpty
        ? ':white_check_mark: No unused translation keys'
        : ':warning: ${report.unusedKeys.length} unused translation '
              '${report.unusedKeys.length == 1 ? 'key' : 'keys'}';
    out.writeln('## Localization report (l10n_sweep)');
    out.writeln();
    out.writeln(status);
    out.writeln();
    out.writeln('| Metric | Count |');
    out.writeln('| --- | ---: |');
    out.writeln('| Translation files | ${report.localeFiles.length} |');
    out.writeln('| Total keys | ${report.keys.length} |');
    out.writeln('| Used keys | ${report.usedKeys.length} |');
    out.writeln('| Unused keys | ${report.unusedKeys.length} |');
    out.writeln(
      '| Potentially unused keys | ${report.potentiallyUnusedKeys.length} |',
    );
    out.writeln(
      '| Dynamically referenced keys | ${report.dynamicKeys.length} |',
    );
    out.writeln('| Missing translations | ${report.missingTranslationCount} |');
    out.writeln('| Undefined keys | ${report.undefinedKeys.length} |');
    out.writeln(
      '| Unresolved translation calls | '
      '${report.unresolvedReferences.where((r) => !r.acknowledged).length} |',
    );
    out.writeln();

    if (report.localeFiles.isNotEmpty) {
      out.writeln('| Locale file | Keys | Unused | Missing | Extra |');
      out.writeln('| --- | ---: | ---: | ---: | ---: |');
      for (final f in report.localeFiles) {
        final name = '`${f.path}`${f.isPrimary ? ' (primary)' : ''}';
        final keys = f.isValid ? '${f.keyCount}' : 'invalid';
        out.writeln(
          '| $name | $keys | ${f.unusedCount} | ${f.missingKeys.length} | '
          '${f.extraKeys.length} |',
        );
      }
      out.writeln();
    }

    _keys(out, 'Unused keys', report.unusedKeys, reasons: false);
    _keys(
      out,
      'Unused keys missing from the primary locale',
      report.orphanUnusedKeys,
      reasons: false,
    );
    _keys(
      out,
      'Potentially unused keys',
      report.potentiallyUnusedKeys,
      reasons: true,
    );

    final missing = report.localeFiles.where((f) => f.missingKeys.isNotEmpty);
    if (missing.isNotEmpty) {
      out.writeln('<details><summary>Missing translations</summary>');
      out.writeln();
      for (final f in missing) {
        out.writeln('**`${f.path}`**');
        out.writeln();
        for (final k in f.missingKeys.take(_limit)) {
          out.writeln('- `${_code(k)}`');
        }
        out.writeln();
      }
      out.writeln('</details>');
      out.writeln();
    }

    if (report.undefinedKeys.isNotEmpty) {
      out.writeln(
        '<details><summary>Keys used in code but not defined '
        '(${report.undefinedKeys.length})</summary>',
      );
      out.writeln();
      for (final e in report.undefinedKeys.entries.take(_limit)) {
        out.writeln('- `${_code(e.key)}` — `${e.value.first}`');
      }
      out.writeln();
      out.writeln('</details>');
      out.writeln();
    }

    if (report.unresolvedReferences.isNotEmpty) {
      out.writeln(
        '<details><summary>Translation calls with unknown keys '
        '(${report.unresolvedReferences.length})</summary>',
      );
      out.writeln();
      for (final r in report.unresolvedReferences.take(_limit)) {
        final ack = r.acknowledged ? ' _(acknowledged)_' : '';
        out.writeln('- `${r.location}` — `${_code(r.snippet)}`$ack');
      }
      out.writeln();
      out.writeln('</details>');
      out.writeln();
    }

    if (report.errors.isNotEmpty || report.warnings.isNotEmpty) {
      out.writeln('### Diagnostics');
      out.writeln();
      for (final e in report.errors) {
        out.writeln('- :x: ${_escape(e.toString())}');
      }
      for (final w in report.warnings) {
        out.writeln('- :warning: ${_escape(w.toString())}');
      }
      out.writeln();
    }
    return out.toString();
  }

  void _keys(
    StringBuffer out,
    String title,
    List<KeyClassification> keys, {
    required bool reasons,
  }) {
    if (keys.isEmpty) return;
    out.writeln('<details><summary>$title (${keys.length})</summary>');
    out.writeln();
    for (final k in keys.take(_limit)) {
      final why = reasons ? ' — ${_escape(k.reasons.first)}' : '';
      out.writeln('- `${_code(k.key)}`$why');
    }
    if (keys.length > _limit) {
      out.writeln('- ... and ${keys.length - _limit} more');
    }
    out.writeln();
    out.writeln('</details>');
    out.writeln();
  }

  /// Escapes text placed inside a `code span`.
  static String _code(String text) => text.replaceAll('`', "'");

  /// Escapes plain Markdown text.
  static String _escape(String text) =>
      text.replaceAll('|', r'\|').replaceAll('<', '&lt;').replaceAll('`', "'");
}
