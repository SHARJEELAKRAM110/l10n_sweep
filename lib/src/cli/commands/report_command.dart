import '../../configuration/l10n_sweep_config.dart';
import '../../utils/ansi.dart';
import 'analyze_command.dart';
import 'base_command.dart';

class ReportCommand extends L10nSweepCommand {
  ReportCommand(super.env) {
    argParser
      ..addOption(
        'format',
        abbr: 'f',
        allowed: ['console', 'json', 'markdown'],
        help:
            'Report format (default: output.format from the configuration, '
            'or json).',
      )
      ..addOption(
        'output',
        abbr: 'o',
        help:
            'Report file (default: output.path from the configuration, or '
            'build/l10n_sweep_report.<ext>).',
      )
      ..addFlag(
        'stdout',
        negatable: false,
        help: 'Print the report instead of writing a file.',
      );
  }

  @override
  String get name => 'report';

  @override
  String get description =>
      'Write a JSON, Markdown or text report file. Never modifies locale files.';

  @override
  int execute() {
    final args = argResults!;
    final loaded = loadConfig();
    final config = loaded.config;
    final configured = config.output.format;
    final format = args['format'] != null
        ? ReportFormat.parse(args['format'] as String)
        : (config.output.path == null && configured == ReportFormat.console
              ? ReportFormat.json
              : configured);
    final report = analyze(loaded).report;
    final content = renderReport(report, format, ansi: const Ansi(false));
    if (args['stdout'] as bool) {
      logger.write(content);
    } else {
      final path =
          args['output'] as String? ??
          config.output.path ??
          'build/l10n_sweep_report.${format.extension}';
      final written = writeReportFile(config.projectRoot, path, content);
      logger.info(
        'Report written to $written '
        '(${report.unusedKeys.length} unused, '
        '${report.potentiallyUnusedKeys.length} potentially unused, '
        '${report.missingTranslationCount} missing translations).',
      );
    }
    return report.hasErrors ? ExitCode.error : ExitCode.success;
  }
}
