import '../models/analysis_issue.dart';
import '../models/analysis_report.dart';
import '../models/unused_key_result.dart';
import '../utils/ansi.dart';

/// Renders an [AnalysisReport] for a terminal.
class ConsoleReporter {
  const ConsoleReporter({this.ansi = const Ansi(false), this.verbose = false});

  final Ansi ansi;

  /// Show every key with reasons and references instead of a summary.
  final bool verbose;

  static const _listLimit = 50;
  static const _detailLimit = 15;

  String render(AnalysisReport report) {
    final out = StringBuffer();
    out.writeln(ansi.bold('l10n_sweep analysis'));
    out.writeln();

    final rows = <(String, String)>[
      (
        'Translation files',
        '${report.localeFiles.length}'
            '${report.primaryLocale == null ? '' : ' (primary: ${report.primaryLocale})'}',
      ),
      ('Total translation keys', '${report.keys.length}'),
      ('Used keys', '${report.usedKeys.length}'),
      ('Unused keys', _count(report.unusedKeys.length, ansi.red)),
      (
        'Potentially unused keys',
        _count(report.potentiallyUnusedKeys.length, ansi.yellow),
      ),
      ('Dynamically referenced keys', '${report.dynamicKeys.length}'),
      if (report.excludedKeys.isNotEmpty)
        ('Excluded keys', '${report.excludedKeys.length}'),
      (
        'Missing translations',
        _count(report.missingTranslationCount, ansi.yellow),
      ),
      if (report.undefinedKeys.isNotEmpty)
        ('Undefined keys', _count(report.undefinedKeys.length, ansi.yellow)),
      (
        'Uncertain references',
        _count(
          report.unresolvedReferences.where((r) => !r.acknowledged).length,
          ansi.yellow,
        ),
      ),
    ];
    final width = rows.map((r) => r.$1.length).reduce((a, b) => a > b ? a : b);
    for (final (label, value) in rows) {
      out.writeln('${'$label:'.padRight(width + 2)}$value');
    }

    if (report.localeFiles.isNotEmpty) {
      out.writeln();
      out.writeln(ansi.bold('Unused keys by locale:'));
      // With many locales, list only the files worth looking at.
      final compact = !verbose && report.localeFiles.length > 8;
      var hidden = 0;
      for (final f in report.localeFiles) {
        if (compact && !f.isPrimary && f.isValid && f.unusedCount == 0) {
          hidden++;
          continue;
        }
        final name = f.path.split('/').last;
        final tag = f.isPrimary ? ' (primary)' : '';
        final state = f.isValid ? '${f.unusedCount}' : ansi.red('invalid JSON');
        out.writeln('  $name$tag: $state');
      }
      if (hidden > 0) {
        out.writeln(
          ansi.dim(
            '  $hidden other locale ${hidden == 1 ? 'file' : 'files'}: 0',
          ),
        );
      }
    }

    _section(
      out,
      'Unused keys',
      report.unusedKeys,
      color: ansi.red,
      limit: verbose ? null : _listLimit,
      hint: 'Safe to remove with "clean". Review with --verbose.',
    );
    _section(
      out,
      'Unused keys missing from the primary locale',
      report.orphanUnusedKeys,
      color: ansi.red,
      limit: verbose ? null : _detailLimit,
      withReasons: false,
    );
    _section(
      out,
      'Potentially unused keys (review before removing)',
      report.potentiallyUnusedKeys,
      color: ansi.yellow,
      limit: verbose ? null : _detailLimit,
      withReasons: true,
    );
    if (verbose) {
      _section(
        out,
        'Dynamically referenced keys (kept)',
        report.dynamicKeys,
        color: ansi.cyan,
        limit: null,
        withReasons: true,
      );
    }

    if (report.dynamicUsages.isNotEmpty) {
      out.writeln();
      out.writeln(ansi.bold('Dynamic key patterns:'));
      final usages = verbose
          ? report.dynamicUsages
          : report.dynamicUsages.take(_detailLimit);
      for (final d in usages) {
        final where = d.locations.first;
        final more = d.locations.length > 1
            ? ' (+${d.locations.length - 1} more)'
            : '';
        out.writeln(
          '  ${ansi.cyan(d.pattern.display)}  matches ${d.matchedKeys} '
          '${d.matchedKeys == 1 ? 'key' : 'keys'}  ${ansi.dim('$where$more')}',
        );
      }
      _more(out, report.dynamicUsages.length, verbose ? null : _detailLimit);
    }

    if (report.unresolvedReferences.isNotEmpty) {
      out.writeln();
      out.writeln(ansi.bold('Translation calls with unknown keys:'));
      final refs = verbose
          ? report.unresolvedReferences
          : report.unresolvedReferences.take(_detailLimit);
      for (final r in refs) {
        final tag = r.acknowledged ? ansi.dim(' [acknowledged]') : '';
        out.writeln('  ${r.location}  ${r.snippet}$tag');
        if (verbose) out.writeln(ansi.dim('      ${r.reason}'));
      }
      _more(
        out,
        report.unresolvedReferences.length,
        verbose ? null : _detailLimit,
      );
      if (report.blockingUnresolved.isNotEmpty) {
        out.writeln(
          ansi.yellow(
            '  These calls could reference any key, so no key is reported '
            'as definitely unused.',
          ),
        );
        out.writeln(
          '  Add "// l10n_sweep:keys <pattern>" or "// l10n_sweep:ignore" '
          'above each call, or list patterns under dynamic_key_patterns.',
        );
      }
    }

    final missing = report.localeFiles.where((f) => f.missingKeys.isNotEmpty);
    final extra = report.localeFiles.where((f) => f.extraKeys.isNotEmpty);
    if (missing.isNotEmpty || extra.isNotEmpty) {
      out.writeln();
      out.writeln(ansi.bold('Locale consistency:'));
      for (final f in missing) {
        out.writeln(
          '  ${f.path.split('/').last}: ${f.missingKeys.length} missing'
          '${_preview(f.missingKeys)}',
        );
      }
      for (final f in extra) {
        out.writeln(
          '  ${f.path.split('/').last}: ${f.extraKeys.length} not in the '
          'primary locale${_preview(f.extraKeys)}',
        );
      }
    }

    if (report.undefinedKeys.isNotEmpty) {
      out.writeln();
      out.writeln(ansi.bold('Keys used in code but not defined:'));
      final entries = verbose
          ? report.undefinedKeys.entries
          : report.undefinedKeys.entries.take(_detailLimit);
      for (final e in entries) {
        out.writeln('  ${ansi.yellow(e.key)}  ${ansi.dim('${e.value.first}')}');
      }
      _more(out, report.undefinedKeys.length, verbose ? null : _detailLimit);
    }

    _issues(out, 'Warnings', report.warnings, ansi.yellow);
    _issues(out, 'Errors', report.errors, ansi.red);

    out.writeln();
    final seconds = report.stats.elapsed.inMilliseconds;
    final scanned =
        '${report.stats.usageFiles} Dart files, '
        '${report.stats.translationCalls} translation calls, $seconds ms';
    if (report.hasErrors) {
      out.writeln(
        ansi.red('Analysis completed with errors.') + ansi.dim(' ($scanned)'),
      );
    } else {
      out.writeln(
        ansi.green('Analysis completed successfully.') +
            ansi.dim(' ($scanned)'),
      );
    }
    return out.toString();
  }

  String _count(int value, String Function(String) color) =>
      value == 0 ? '0' : color('$value');

  String _preview(List<String> keys) {
    if (verbose) return ': ${keys.join(', ')}';
    final shown = keys.take(5).join(', ');
    return keys.length > 5 ? ' ($shown, ...)' : ' ($shown)';
  }

  void _section(
    StringBuffer out,
    String title,
    List<KeyClassification> keys, {
    required String Function(String) color,
    required int? limit,
    bool withReasons = false,
    String? hint,
  }) {
    if (keys.isEmpty) return;
    out.writeln();
    out.writeln(ansi.bold('$title:'));
    final shown = limit == null ? keys : keys.take(limit);
    for (final k in shown) {
      final locales = verbose ? ansi.dim('  [${k.locales.join(', ')}]') : '';
      out.writeln('  ${color(k.key)}$locales');
      if (withReasons || verbose) {
        for (final reason in k.reasons) {
          out.writeln(ansi.dim('      $reason'));
        }
        if (verbose) {
          for (final e in k.evidence) {
            out.writeln(ansi.dim('      at $e'));
          }
        }
      }
    }
    _more(out, keys.length, limit);
    if (hint != null) out.writeln(ansi.dim('  $hint'));
  }

  void _more(StringBuffer out, int total, int? limit) {
    if (limit != null && total > limit) {
      out.writeln(ansi.dim('  ... and ${total - limit} more (use --verbose)'));
    }
  }

  void _issues(
    StringBuffer out,
    String title,
    List<AnalysisIssue> issues,
    String Function(String) color,
  ) {
    if (issues.isEmpty) return;
    out.writeln();
    out.writeln(ansi.bold('$title:'));
    for (final issue in issues) {
      out.writeln('  ${color(issue.toString())}');
    }
  }
}
