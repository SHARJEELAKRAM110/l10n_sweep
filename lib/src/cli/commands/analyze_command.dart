import 'dart:io';

import 'package:path/path.dart' as p;

import '../../configuration/l10n_sweep_config.dart';
import '../../models/analysis_report.dart';
import '../../reporting/console_reporter.dart';
import '../../reporting/json_reporter.dart';
import '../../reporting/markdown_reporter.dart';
import '../../utils/ansi.dart';
import 'base_command.dart';

/// Renders [report] in [format].
String renderReport(
  AnalysisReport report,
  ReportFormat format, {
  required Ansi ansi,
  bool verbose = false,
}) => switch (format) {
  ReportFormat.console => ConsoleReporter(
    ansi: ansi,
    verbose: verbose,
  ).render(report),
  ReportFormat.json => const JsonReporter().render(report),
  ReportFormat.markdown => const MarkdownReporter().render(report),
};

/// Writes [content] to [path] (relative to [root]), creating directories.
String writeReportFile(String root, String path, String content) {
  final file = File(p.isAbsolute(path) ? path : p.join(root, path));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
  return file.path;
}

class AnalyzeCommand extends L10nSweepCommand {
  AnalyzeCommand(super.env) {
    argParser
      ..addFlag(
        'verbose',
        abbr: 'v',
        negatable: false,
        help: 'List every key with the reasons for its classification.',
      )
      ..addOption(
        'format',
        abbr: 'f',
        allowed: ['console', 'json', 'markdown'],
        help: 'Output format (default: console).',
      )
      ..addOption('output', abbr: 'o', help: 'Also write the report to a file.')
      ..addFlag(
        'fail-on-unused',
        negatable: false,
        help: 'Exit with code 1 when unused keys are found.',
      )
      ..addFlag(
        'fail-on-missing',
        negatable: false,
        help:
            'Exit with code 1 when a locale lacks keys of the primary locale.',
      )
      ..addFlag(
        'fail-on-uncertain',
        negatable: false,
        help:
            'Exit with code 1 when keys are potentially unused or translation '
            'calls cannot be resolved.',
      )
      ..addFlag(
        'fail-on-undefined',
        negatable: false,
        help: 'Exit with code 1 when code uses keys missing from locale files.',
      );
  }

  @override
  String get name => 'analyze';

  @override
  String get description =>
      'Report unused, uncertain and missing translation keys. Never modifies '
      'files.';

  @override
  int execute() {
    final args = argResults!;
    final loaded = loadConfig();
    final result = analyze(loaded);
    final report = result.report;
    final format = args['format'] == null
        ? ReportFormat.console
        : ReportFormat.parse(args['format'] as String);
    logger.write(
      renderReport(
        report,
        format,
        ansi: logger.ansi,
        verbose: args['verbose'] as bool,
      ),
    );
    final output = args['output'] as String?;
    if (output != null) {
      final written = writeReportFile(
        loaded.config.projectRoot,
        output,
        renderReport(
          report,
          _formatFor(output, format),
          ansi: const Ansi(false),
        ),
      );
      logger.status('Report written to $written');
    }

    if (report.hasErrors) return ExitCode.error;
    final failures = <String>[
      if (args['fail-on-unused'] as bool && report.unusedKeys.isNotEmpty)
        '${report.unusedKeys.length} unused keys',
      if (args['fail-on-missing'] as bool && report.missingTranslationCount > 0)
        '${report.missingTranslationCount} missing translations',
      if (args['fail-on-uncertain'] as bool && report.uncertainCount > 0)
        '${report.uncertainCount} uncertain keys or references',
      if (args['fail-on-undefined'] as bool && report.undefinedKeys.isNotEmpty)
        '${report.undefinedKeys.length} undefined keys',
    ];
    if (failures.isNotEmpty) {
      logger.status('Check failed: ${failures.join(', ')}.');
      return ExitCode.checkFailed;
    }
    return ExitCode.success;
  }

  static ReportFormat _formatFor(String path, ReportFormat fallback) =>
      switch (p.extension(path).toLowerCase()) {
        '.json' => ReportFormat.json,
        '.md' || '.markdown' => ReportFormat.markdown,
        '.txt' || '.log' => ReportFormat.console,
        _ => fallback,
      };
}
