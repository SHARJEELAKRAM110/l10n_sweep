import '../../cleanup/backup_manager.dart';
import 'base_command.dart';

class RestoreCommand extends L10nSweepCommand {
  RestoreCommand(super.env) {
    argParser
      ..addOption('id', help: 'Backup to restore (default: the newest).')
      ..addFlag('list', abbr: 'l', negatable: false, help: 'List backups.')
      ..addFlag(
        'yes',
        abbr: 'y',
        negatable: false,
        help: 'Restore without asking for confirmation.',
      );
  }

  @override
  String get name => 'restore';

  @override
  String get description =>
      'Restore locale files from a backup created by "clean".';

  @override
  int execute() {
    final args = argResults!;
    final config = loadConfig().config;
    final manager = BackupManager(
      projectRoot: config.projectRoot,
      backupPath: config.safety.backupPath,
    );
    final backups = manager.list();
    if (args['list'] as bool) {
      if (backups.isEmpty) {
        logger.info('No backups found in ${config.safety.backupPath}.');
        return ExitCode.success;
      }
      for (final b in backups) {
        logger.info(
          '${b.id}  ${b.files.length} files, ${b.removedKeys.length} keys '
          'removed',
        );
      }
      return ExitCode.success;
    }
    if (backups.isEmpty) {
      logger.error('No backups found in ${config.safety.backupPath}.');
      return ExitCode.error;
    }
    final id = args['id'] as String?;
    final backup = id == null
        ? backups.first
        : backups.where((b) => b.id == id).firstOrNull;
    if (backup == null) {
      logger.error('Backup "$id" not found. Use --list to see backups.');
      return ExitCode.error;
    }
    logger.info('Backup ${backup.id} contains:');
    for (final f in backup.files) {
      logger.info('  $f');
    }
    if (!(args['yes'] as bool)) {
      if (!env.prompter.canPrompt) {
        logger.error('Confirmation needed. Re-run with --yes.');
        return ExitCode.error;
      }
      if (!env.prompter.confirm('Overwrite these files with the backup?')) {
        logger.info('Cancelled. No files were modified.');
        return ExitCode.success;
      }
    }
    try {
      manager.restore(backup.id);
    } on BackupException catch (e) {
      logger.error(e.message);
      return ExitCode.error;
    }
    logger.success('Restored ${backup.files.length} files from ${backup.id}.');
    return ExitCode.success;
  }
}
