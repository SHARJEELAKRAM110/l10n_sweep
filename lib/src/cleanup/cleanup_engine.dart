import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../configuration/l10n_sweep_config.dart';
import '../models/analysis_report.dart';
import '../models/translation_file.dart';
import '../models/unused_key_result.dart';
import '../parsers/translation_catalog.dart';
import 'backup_manager.dart';
import 'json_preservation_service.dart';

/// Raised when a cleanup is refused or fails. When raised during
/// [CleanupEngine.apply], no locale file is left modified.
class CleanupException implements Exception {
  CleanupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The keys to remove and where they live.
class CleanupPlan {
  const CleanupPlan({
    required this.keys,
    required this.keysByFile,
    required this.inconsistencies,
  });

  /// Keys selected for removal.
  final List<String> keys;

  /// Locale file path → keys present in that file.
  final Map<String, List<String>> keysByFile;

  /// Keys that are not present in every locale file, with the locales that
  /// do contain them. Removing them makes the locales consistent again.
  final Map<String, List<String>> inconsistencies;

  bool get isEmpty => keys.isEmpty;
}

/// Outcome of a successful cleanup.
class CleanupResult {
  const CleanupResult({
    required this.removedKeys,
    required this.modifiedFiles,
    required this.backup,
  });

  final List<String> removedKeys;
  final List<String> modifiedFiles;

  /// `null` when backups are disabled.
  final BackupInfo? backup;
}

/// Writes bytes to a file. Replaceable in tests to simulate failures.
typedef FileWriter = void Function(File file, List<int> bytes);

/// Removes keys from locale files as a single all-or-nothing operation.
///
/// 1. The plan only accepts keys the analysis did not mark as used.
/// 2. Every locale file must be valid and unchanged since the analysis.
/// 3. All new file contents are computed and verified in memory.
/// 4. A backup of every affected file is written and verified.
/// 5. Files are replaced through a temporary file and rename. If any write
///    fails, files already written are restored from memory.
class CleanupEngine {
  CleanupEngine({
    required this.config,
    required this.catalog,
    required this.report,
    FileWriter? writer,
  }) : _writer = writer ?? _defaultWriter;

  final L10nSweepConfig config;
  final TranslationCatalog catalog;
  final AnalysisReport report;
  final FileWriter _writer;

  static const _removableStatuses = {
    KeyStatus.unused,
    KeyStatus.potentiallyUnused,
    KeyStatus.dynamicallyUsed,
  };

  /// Builds a plan for [keys]. Throws [CleanupException] when a key is used,
  /// excluded or unknown, or when a locale file is invalid.
  CleanupPlan plan(Iterable<String> keys) {
    final byKey = {for (final k in report.keys) k.key: k};
    final selected = <String>[];
    for (final key in keys) {
      final info = byKey[key];
      if (info == null) {
        throw CleanupException('"$key" is not a key in any locale file.');
      }
      if (!_removableStatuses.contains(info.status)) {
        throw CleanupException(
          'Refusing to remove "$key": it is ${info.status.id} '
          '(${info.reasons.first}).',
        );
      }
      if (!selected.contains(key)) selected.add(key);
    }

    final invalid = catalog.files.where((f) => !f.isValid).toList();
    if (invalid.isNotEmpty && selected.isNotEmpty) {
      throw CleanupException(
        'Cleanup stopped: fix the invalid locale '
        '${invalid.length == 1 ? 'file' : 'files'} first: '
        '${invalid.map((f) => f.path).join(', ')}. '
        'Removing keys from only some locales would leave them out of sync.',
      );
    }

    final keysByFile = <String, List<String>>{};
    for (final file in catalog.files) {
      final present = [
        for (final key in selected)
          if (file.entries.containsKey(key)) key,
      ];
      if (present.isNotEmpty) keysByFile[file.path] = present;
    }
    final allLocales = catalog.files.map((f) => f.locale).toList();
    final inconsistencies = <String, List<String>>{};
    for (final key in selected) {
      final locales = byKey[key]!.locales;
      if (locales.length != allLocales.length) inconsistencies[key] = locales;
    }
    return CleanupPlan(
      keys: selected,
      keysByFile: keysByFile,
      inconsistencies: inconsistencies,
    );
  }

  /// Executes [plan]. Never leaves a locale file partially modified.
  CleanupResult apply(CleanupPlan plan, {bool? createBackup, DateTime? now}) {
    if (plan.isEmpty) {
      return const CleanupResult(
        removedKeys: [],
        modifiedFiles: [],
        backup: null,
      );
    }
    final files = {for (final f in catalog.files) f.path: f};
    final service = JsonPreservationService(
      removeEmptyParents: config.cleanup.removeEmptyParents,
    );

    // 1-3: verify inputs and compute every new file in memory.
    final originals = <String, List<int>>{};
    final updates = <TranslationFile, List<int>>{};
    for (final entry in plan.keysByFile.entries) {
      final file = files[entry.key];
      if (file == null) {
        throw CleanupException('Unknown locale file ${entry.key}.');
      }
      final onDisk = File(file.absolutePath);
      List<int> currentBytes;
      try {
        currentBytes = onDisk.readAsBytesSync();
      } on FileSystemException catch (e) {
        throw CleanupException('Cannot read ${file.path}: ${e.message}');
      }
      final current = utf8.decode(currentBytes, allowMalformed: true);
      if (current != file.originalText) {
        throw CleanupException(
          '${file.path} changed after it was analyzed. Run the command '
          'again.',
        );
      }
      try {
        final result = service.removeKeys(file, entry.value.toSet());
        originals[file.path] = currentBytes;
        updates[file] = utf8.encode(result.newContent);
      } on JsonEditException catch (e) {
        throw CleanupException('Cleanup stopped, no files changed: $e');
      }
    }

    // 4: back up.
    BackupInfo? backup;
    if (createBackup ?? config.safety.createBackup) {
      try {
        backup = BackupManager(
          projectRoot: config.projectRoot,
          backupPath: config.safety.backupPath,
        ).create(originals, removedKeys: plan.keys, now: now);
      } on BackupException catch (e) {
        throw CleanupException('Cleanup stopped, no files changed: $e');
      }
    }

    // 5: write, rolling back on failure.
    final written = <TranslationFile>[];
    try {
      for (final entry in updates.entries) {
        _replace(File(entry.key.absolutePath), entry.value);
        written.add(entry.key);
      }
    } on Object catch (error) {
      final failedRestores = <String>[];
      for (final file in written.reversed) {
        try {
          _writer(File(file.absolutePath), originals[file.path]!);
        } on Object {
          failedRestores.add(file.path);
        }
      }
      final restoreNote = failedRestores.isEmpty
          ? 'All locale files were restored to their original contents.'
          : 'Could not restore ${failedRestores.join(', ')}; recover them '
                'with "l10n_sweep restore${backup == null ? '' : ' --id ${backup.id}'}".';
      throw CleanupException(
        'Writing locale files failed: $error. $restoreNote',
      );
    }

    return CleanupResult(
      removedKeys: plan.keys,
      modifiedFiles: [for (final f in written) f.path],
      backup: backup,
    );
  }

  /// Writes through a sibling temporary file and a rename, so a crash
  /// mid-write cannot leave a truncated locale file.
  void _replace(File target, List<int> bytes) {
    final temp = File(
      p.join(target.parent.path, '.${p.basename(target.path)}.l10n_sweep.tmp'),
    );
    try {
      _writer(temp, bytes);
      temp.renameSync(target.path);
    } finally {
      if (temp.existsSync()) {
        try {
          temp.deleteSync();
        } on FileSystemException {
          // Leftover temp files are harmless and ignored by the analyzer.
        }
      }
    }
  }

  static void _defaultWriter(File file, List<int> bytes) =>
      file.writeAsBytesSync(bytes, flush: true);
}
