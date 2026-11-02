import '../../cleanup/cleanup_engine.dart';
import '../../models/analysis_report.dart';
import '../../models/unused_key_result.dart';
import '../prompter.dart';
import 'base_command.dart';

class CleanCommand extends L10nSweepCommand {
  CleanCommand(super.env) {
    argParser
      ..addFlag(
        'dry-run',
        abbr: 'n',
        negatable: false,
        help: 'Show what would be removed without modifying any file.',
      )
      ..addFlag(
        'yes',
        abbr: 'y',
        negatable: false,
        help:
            'Remove every definitely unused key without prompting. Dynamic, '
            'uncertain, excluded and preserved keys are always kept.',
      )
      ..addMultiOption(
        'keys',
        abbr: 'k',
        help: 'Only consider these keys (comma-separated or repeated).',
      )
      ..addFlag(
        'include-uncertain',
        negatable: false,
        help:
            'Also offer dynamically referenced keys in the interactive '
            'selection (never pre-selected, never removed by --yes).',
      )
      ..addFlag(
        'backup',
        defaultsTo: true,
        help:
            'Back up locale files before modifying them. Overrides '
            'safety.create_backup.',
      );
  }

  @override
  String get name => 'clean';

  @override
  String get description =>
      'Remove unused keys from every locale file after confirmation.';

  @override
  int execute() {
    final args = argResults!;
    final dryRun = args['dry-run'] as bool;
    final yes = args['yes'] as bool;
    final requestedKeys = (args['keys'] as List<String>)
        .expand((k) => k.split(','))
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty)
        .toList();
    final loaded = loadConfig();
    final config = loaded.config;
    final result = analyze(loaded);
    final report = result.report;

    if (report.hasErrors) {
      for (final e in report.errors) {
        logger.error(e.toString());
      }
      logger.error('Cleanup stopped. No files were modified.');
      return ExitCode.error;
    }

    final byKey = {for (final k in report.keys) k.key: k};
    for (final key in requestedKeys) {
      if (!byKey.containsKey(key)) {
        logger.error('"$key" is not defined in any locale file.');
        return ExitCode.error;
      }
    }
    bool requested(KeyClassification k) =>
        requestedKeys.isEmpty || requestedKeys.contains(k.key);

    final definite = report.unusedKeys.where(requested).toList();
    final includeDynamic =
        args['include-uncertain'] as bool ||
        !config.safety.preserveUncertainKeys;
    final optional = [
      ...report.potentiallyUnusedKeys.where((k) => k.inPrimary),
      ...report.orphanUnusedKeys,
      if (includeDynamic) ...report.dynamicKeys,
    ].where(requested).toList();

    if (yes) {
      final refused = requestedKeys
          .where((k) => !byKey[k]!.isSafeToRemove)
          .toList();
      if (refused.isNotEmpty) {
        logger.error(
          '--yes only removes keys classified as definitely unused. Not '
          'removing: ${refused.map((k) => '$k (${byKey[k]!.status.id})').join(', ')}. '
          'Run without --yes to review them interactively.',
        );
        return ExitCode.error;
      }
    }

    _printUncertainty(report);

    if (dryRun) {
      _preview(report, definite, yes ? const [] : optional);
      logger.info('');
      logger.success('Dry run: no files were modified.');
      return ExitCode.success;
    }

    List<String> selected;
    if (yes) {
      logger.info(
        logger.ansi.yellow(
          'Force cleanup (--yes): removing keys classified as definitely '
          'unused without prompting. Dynamic, uncertain, excluded and '
          'preserved keys are kept.',
        ),
      );
      if (definite.isEmpty) {
        logger.info('No definitely unused keys found. Nothing to remove.');
        return ExitCode.success;
      }
      selected = [for (final k in definite) k.key];
    } else {
      if (definite.isEmpty && optional.isEmpty) {
        logger.info('No unused keys found. Nothing to remove.');
        return ExitCode.success;
      }
      if (!env.prompter.canPrompt) {
        logger.error(
          'Interactive cleanup needs a terminal. Use --dry-run to preview, or '
          '--yes to remove only definitely unused keys.',
        );
        return ExitCode.error;
      }
      logger.info(
        'Found ${definite.length} unused '
        '${definite.length == 1 ? 'key' : 'keys'}'
        '${optional.isEmpty ? '' : ' and ${optional.length} that need review'}.',
      );
      logger.info('');
      final items = [
        for (final k in definite) SelectableItem(label: k.key, selected: true),
        for (final k in optional)
          SelectableItem(label: k.key, detail: _label(k), selected: false),
      ];
      final chosen = env.prompter.select('Select keys to remove:', items);
      if (chosen == null) {
        logger.info('Cancelled. No files were modified.');
        return ExitCode.success;
      }
      if (chosen.isEmpty) {
        logger.info('No keys selected. No files were modified.');
        return ExitCode.success;
      }
      selected = [for (final i in chosen) items[i].label];
    }

    final engine = CleanupEngine(
      config: config,
      catalog: result.catalog,
      report: report,
    );
    CleanupPlan plan;
    try {
      plan = engine.plan(selected);
    } on CleanupException catch (e) {
      logger.error(e.message);
      return ExitCode.error;
    }

    _printPlan(plan);
    if (!yes && config.safety.requireConfirmation) {
      final files = plan.keysByFile.length;
      final confirmed = env.prompter.confirm(
        'Remove ${plan.keys.length} selected '
        '${plan.keys.length == 1 ? 'key' : 'keys'} from $files '
        '${files == 1 ? 'file' : 'files'}?',
      );
      if (!confirmed) {
        logger.info('Cancelled. No files were modified.');
        return ExitCode.success;
      }
    }

    try {
      final outcome = engine.apply(
        plan,
        createBackup: args.wasParsed('backup') ? args['backup'] as bool : null,
      );
      logger.success(
        'Removed ${outcome.removedKeys.length} '
        '${outcome.removedKeys.length == 1 ? 'key' : 'keys'} from '
        '${outcome.modifiedFiles.length} '
        '${outcome.modifiedFiles.length == 1 ? 'file' : 'files'}.',
      );
      final backup = outcome.backup;
      if (backup != null) {
        logger.detail('Backup: ${backup.directory}');
        logger.detail(
          'Undo with: dart run l10n_sweep restore --id ${backup.id}',
        );
      }
      return ExitCode.success;
    } on CleanupException catch (e) {
      logger.error(e.message);
      return ExitCode.error;
    }
  }

  void _printUncertainty(AnalysisReport report) {
    final blocking = report.blockingUnresolved;
    if (blocking.isEmpty) return;
    logger.warn(
      '${blocking.length} translation '
      '${blocking.length == 1 ? 'call has' : 'calls have'} keys that cannot be '
      'determined, so no key is classified as definitely unused. Run '
      '"analyze --verbose" for details.',
    );
  }

  void _preview(
    AnalysisReport report,
    List<KeyClassification> definite,
    List<KeyClassification> optional,
  ) {
    final ansi = logger.ansi;
    if (definite.isEmpty) {
      logger.info('No keys would be removed automatically.');
    } else {
      logger.info(
        ansi.bold(
          '${definite.length} definitely unused '
          '${definite.length == 1 ? 'key' : 'keys'} would be removed:',
        ),
      );
      for (final k in definite) {
        logger.info(
          '  ${ansi.red('- ${k.key}')}  ${ansi.dim('[${k.locales.join(', ')}]')}',
        );
      }
      final perFile = <String, int>{};
      for (final f in report.localeFiles) {
        final count = definite
            .where((k) => k.locales.contains(f.locale))
            .length;
        if (count > 0) perFile[f.path] = count;
      }
      logger.info('');
      logger.info(ansi.bold('Files that would change:'));
      perFile.forEach((path, count) {
        logger.info('  $path: $count ${count == 1 ? 'key' : 'keys'}');
      });
      _printInconsistencies(report, {
        for (final k in definite)
          if (k.locales.length != report.localeFiles.length) k.key: k.locales,
      });
    }
    if (optional.isNotEmpty) {
      logger.info('');
      logger.info(
        ansi.bold(
          '${optional.length} more ${optional.length == 1 ? 'key needs' : 'keys need'} '
          'review and would only be removed if selected interactively:',
        ),
      );
      for (final k in optional) {
        logger.info('  ${ansi.yellow('? ${k.key}')}  ${ansi.dim(_label(k))}');
      }
    }
  }

  void _printPlan(CleanupPlan plan) {
    logger.info('');
    logger.info(logger.ansi.bold('Files to modify:'));
    plan.keysByFile.forEach((path, keys) {
      logger.info(
        '  $path: ${keys.length} ${keys.length == 1 ? 'key' : 'keys'}',
      );
    });
    if (plan.inconsistencies.isNotEmpty) {
      logger.info('');
      logger.info(
        logger.ansi.yellow(
          'Note: these keys are not present in every locale; they will be '
          'removed wherever they exist:',
        ),
      );
      plan.inconsistencies.forEach((key, locales) {
        logger.info('  $key: only in ${locales.join(', ')}');
      });
    }
    logger.info('');
  }

  void _printInconsistencies(
    AnalysisReport report,
    Map<String, List<String>> inconsistencies,
  ) {
    if (inconsistencies.isEmpty) return;
    logger.info('');
    logger.info(
      logger.ansi.yellow(
        'Locale inconsistencies (keys missing from some locales):',
      ),
    );
    inconsistencies.forEach((key, locales) {
      logger.info('  $key: only in ${locales.join(', ')}');
    });
  }

  static String _label(KeyClassification k) => switch (k.status) {
    KeyStatus.unused => 'not in primary locale',
    KeyStatus.potentiallyUnused => 'uncertain: ${k.reasons.first}',
    KeyStatus.dynamicallyUsed => 'dynamic: ${k.reasons.first}',
    _ => k.status.id,
  };
}
