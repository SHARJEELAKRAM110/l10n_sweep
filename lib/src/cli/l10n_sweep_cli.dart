import 'dart:io';

import 'package:args/command_runner.dart';

import '../utils/ansi.dart';
import '../version.dart';
import 'commands/analyze_command.dart';
import 'commands/base_command.dart';
import 'commands/clean_command.dart';
import 'commands/doctor_command.dart';
import 'commands/init_command.dart';
import 'commands/report_command.dart';
import 'commands/restore_command.dart';
import 'logger.dart';
import 'prompter.dart';

/// The `l10n_sweep` command-line interface.
class L10nSweepCli {
  /// [out], [err], [prompter] and [workingDirectory] can be replaced for
  /// testing.
  L10nSweepCli({
    StringSink? out,
    StringSink? err,
    Prompter? prompter,
    String? workingDirectory,
    bool? color,
  }) : _out = out,
       _err = err,
       _prompter = prompter,
       _workingDirectory = workingDirectory,
       _color = color;

  final StringSink? _out;
  final StringSink? _err;
  final Prompter? _prompter;
  final String? _workingDirectory;
  final bool? _color;

  static const executableName = 'l10n_sweep';

  /// Runs the CLI and returns the process exit code.
  Future<int> run(List<String> arguments) async {
    final colorOverride = _colorFlag(arguments);
    final ansi = colorOverride != null || _color != null
        ? Ansi(colorOverride ?? _color!)
        : Ansi.detect();
    final logger = Logger(ansi: ansi, out: _out, err: _err);
    final env = CliEnvironment(
      logger: logger,
      prompter: _prompter ?? TerminalPrompter(ansi),
      workingDirectory: _workingDirectory ?? Directory.current.path,
    );

    final runner =
        CommandRunner<int>(
            executableName,
            'Find and safely remove unused easy_localization translation keys.',
          )
          ..argParser.addOption(
            'project',
            abbr: 'C',
            valueHelp: 'path',
            help: 'Flutter project directory (default: current directory).',
          )
          ..argParser.addOption(
            'config',
            abbr: 'c',
            valueHelp: 'path',
            help: 'Configuration file (default: l10n_sweep.yaml).',
          )
          ..argParser.addFlag(
            'color',
            help:
                'Force colored output on or off (default: auto, honours '
                'NO_COLOR).',
          )
          ..argParser.addFlag(
            'version',
            negatable: false,
            help: 'Print the version.',
          )
          ..addCommand(InitCommand(env))
          ..addCommand(AnalyzeCommand(env))
          ..addCommand(CleanCommand(env))
          ..addCommand(ReportCommand(env))
          ..addCommand(DoctorCommand(env))
          ..addCommand(RestoreCommand(env));

    try {
      final parsed = runner.parse(arguments);
      if (parsed['version'] as bool) {
        logger.info('$executableName $packageVersion');
        return ExitCode.success;
      }
      return await runner.runCommand(parsed) ?? ExitCode.success;
    } on UsageException catch (e) {
      logger.error(e.message);
      logger.info('');
      logger.info(e.usage);
      return ExitCode.usage;
    } on FormatException catch (e) {
      logger.error(e.message);
      return ExitCode.usage;
    } on FileSystemException catch (e) {
      logger.error('${e.message}${e.path == null ? '' : ': ${e.path}'}');
      return ExitCode.error;
    }
  }

  /// Reads `--color` / `--no-color` before full parsing so that usage
  /// errors are styled consistently.
  static bool? _colorFlag(List<String> arguments) {
    bool? result;
    for (final arg in arguments) {
      if (arg == '--') break;
      if (arg == '--color') result = true;
      if (arg == '--no-color') result = false;
    }
    return result;
  }
}
