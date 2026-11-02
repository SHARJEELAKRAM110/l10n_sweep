// Uses the l10n_sweep engine programmatically, without the CLI.
//
// Run from the package root:
//   dart run example/l10n_sweep_example.dart test/fixtures/sample_flutter_app
import 'dart:io';

import 'package:l10n_sweep/l10n_sweep.dart';

void main(List<String> args) {
  final projectRoot = args.isEmpty ? Directory.current.path : args.first;

  // Loads l10n_sweep.yaml, or detects defaults from the project.
  final loaded = const ConfigLoader().load(projectRoot);
  final result = LocalizationAnalyzer(loaded.config).analyze();
  final report = result.report;

  stdout.writeln('Primary locale: ${report.primaryLocale}');
  stdout.writeln('Keys: ${report.keys.length}');

  stdout.writeln('\nDefinitely unused:');
  for (final key in report.unusedKeys) {
    stdout.writeln('  ${key.key}  (${key.locales.join(', ')})');
  }

  stdout.writeln('\nNeeds review:');
  for (final key in report.potentiallyUnusedKeys) {
    stdout.writeln('  ${key.key}: ${key.reasons.first}');
  }

  for (final ref in report.unresolvedReferences) {
    stdout.writeln('\nUnresolved call at ${ref.location}: ${ref.snippet}');
  }

  // Preview a cleanup without writing anything.
  final engine = CleanupEngine(
    config: loaded.config,
    catalog: result.catalog,
    report: report,
  );
  final plan = engine.plan(report.unusedKeys.map((k) => k.key));
  stdout.writeln('\nA cleanup would modify ${plan.keysByFile.length} files.');
  // engine.apply(plan) would perform it, with a backup.
}
