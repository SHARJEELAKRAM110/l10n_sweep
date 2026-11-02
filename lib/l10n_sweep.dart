/// Detects unused easy_localization translation keys in Flutter projects and
/// removes them safely.
///
/// This library exposes the analysis and cleanup engine without any CLI
/// dependencies, so it can be embedded in other tools. The command-line
/// interface lives in `package:l10n_sweep/cli.dart`.
library;

export 'src/analyzer/dart_ast_analyzer.dart' show DartAstAnalyzer;
export 'src/analyzer/localization_analyzer.dart';
export 'src/cleanup/backup_manager.dart';
export 'src/cleanup/cleanup_engine.dart';
export 'src/cleanup/json_preservation_service.dart';
export 'src/configuration/config_loader.dart';
export 'src/configuration/l10n_sweep_config.dart';
export 'src/configuration/project_detector.dart';
export 'src/models/analysis_issue.dart';
export 'src/models/analysis_report.dart';
export 'src/models/localization_key.dart';
export 'src/models/localization_usage.dart';
export 'src/models/source_location.dart';
export 'src/models/translation_file.dart';
export 'src/models/unused_key_result.dart';
export 'src/parsers/dart_source_parser.dart';
export 'src/parsers/json_document.dart';
export 'src/parsers/json_parser.dart';
export 'src/parsers/json_translation_parser.dart';
export 'src/parsers/translation_catalog.dart';
export 'src/reporting/console_reporter.dart';
export 'src/reporting/json_reporter.dart';
export 'src/reporting/markdown_reporter.dart';
