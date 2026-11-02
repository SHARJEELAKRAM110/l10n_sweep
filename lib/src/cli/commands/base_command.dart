import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../../analyzer/localization_analyzer.dart';
import '../../configuration/config_loader.dart';
import '../logger.dart';
import '../prompter.dart';

/// Process exit codes used by every command.
abstract final class ExitCode {
  static const success = 0;

  /// A requested check failed (`--fail-on-*`, `doctor` problems).
  static const checkFailed = 1;

  /// The project could not be analyzed or modified (invalid configuration,
  /// invalid locale files, refused or failed cleanup).
  static const error = 2;

  /// Invalid command-line usage.
  static const usage = 64;
}

/// Shared services for commands.
class CliEnvironment {
  CliEnvironment({
    required this.logger,
    required this.prompter,
    required this.workingDirectory,
  });

  final Logger logger;
  final Prompter prompter;
  final String workingDirectory;
}

abstract class L10nSweepCommand extends Command<int> {
  L10nSweepCommand(this.env);

  final CliEnvironment env;

  Logger get logger => env.logger;

  /// Absolute project directory from `--project` or the working directory.
  String get projectRoot {
    final value = globalResults?['project'] as String?;
    if (value == null) return env.workingDirectory;
    return p.normalize(
      p.isAbsolute(value) ? value : p.join(env.workingDirectory, value),
    );
  }

  String? get configPath => globalResults?['config'] as String?;

  /// Loads the configuration, printing its warnings. Throws
  /// [ConfigException] for invalid configuration.
  LoadedConfig loadConfig() {
    final loaded = const ConfigLoader().load(
      projectRoot,
      configPath: configPath,
    );
    for (final warning in loaded.warnings) {
      logger.warn(warning);
    }
    return loaded;
  }

  AnalysisResult analyze(LoadedConfig loaded) =>
      LocalizationAnalyzer(loaded.config).analyze();

  @override
  Future<int> run() async {
    try {
      return execute();
    } on ConfigException catch (e) {
      logger.error(e.message);
      return ExitCode.error;
    }
  }

  int execute();
}
