import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../version.dart';

/// Raised when a backup cannot be created or restored.
class BackupException implements Exception {
  BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A backup created before a cleanup.
class BackupInfo {
  const BackupInfo({
    required this.id,
    required this.directory,
    required this.createdAt,
    required this.files,
    required this.removedKeys,
  });

  final String id;
  final String directory;
  final DateTime createdAt;

  /// Project-relative paths of the backed up files.
  final List<String> files;
  final List<String> removedKeys;
}

/// Stores copies of locale files before they are modified and restores them.
///
/// Layout: `<backup_path>/<id>/manifest.json` plus the original files at
/// their project-relative paths under `<backup_path>/<id>/files/`.
class BackupManager {
  BackupManager({required this.projectRoot, required this.backupPath});

  final String projectRoot;

  /// Backup directory relative to [projectRoot].
  final String backupPath;

  static const _manifest = 'manifest.json';

  String get _root => p.join(projectRoot, backupPath);

  /// Copies [originals] (relative path → exact bytes) into a new backup.
  BackupInfo create(
    Map<String, List<int>> originals, {
    List<String> removedKeys = const [],
    DateTime? now,
  }) {
    final created = now ?? DateTime.now();
    final baseId = _formatId(created);
    var id = baseId;
    var suffix = 1;
    while (Directory(p.join(_root, id)).existsSync()) {
      id = '$baseId-${suffix++}';
    }
    final dir = Directory(p.join(_root, id));
    try {
      dir.createSync(recursive: true);
      originals.forEach((relative, bytes) {
        final target = File(p.join(dir.path, 'files', relative));
        target.parent.createSync(recursive: true);
        target.writeAsBytesSync(bytes, flush: true);
        final written = target.readAsBytesSync();
        if (!_sameBytes(written, bytes)) {
          throw BackupException('backup of $relative could not be verified');
        }
      });
      final manifest = {
        'tool': 'l10n_sweep',
        'version': packageVersion,
        'id': id,
        'created_at': created.toUtc().toIso8601String(),
        'files': [
          for (final entry in originals.entries)
            {'path': entry.key, 'bytes': entry.value.length},
        ],
        'removed_keys': removedKeys,
      };
      File(p.join(dir.path, _manifest)).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(manifest),
        flush: true,
      );
    } on FileSystemException catch (e) {
      throw BackupException(
        'Could not create backup in ${dir.path}: ${e.message}',
      );
    }
    return BackupInfo(
      id: id,
      directory: dir.path,
      createdAt: created,
      files: originals.keys.toList(),
      removedKeys: removedKeys,
    );
  }

  /// Lists backups, newest first.
  List<BackupInfo> list() {
    final root = Directory(_root);
    if (!root.existsSync()) return const [];
    final result = <BackupInfo>[];
    for (final dir in root.listSync().whereType<Directory>()) {
      final info = _read(dir);
      if (info != null) result.add(info);
    }
    result.sort((a, b) {
      final byTime = b.createdAt.compareTo(a.createdAt);
      return byTime != 0 ? byTime : b.id.compareTo(a.id);
    });
    return result;
  }

  /// Restores the files of backup [id] (or the newest backup when `null`).
  /// Returns the restored backup.
  BackupInfo restore([String? id]) {
    final backups = list();
    if (backups.isEmpty) throw BackupException('No backups found in $_root.');
    final backup = id == null
        ? backups.first
        : backups.where((b) => b.id == id).firstOrNull;
    if (backup == null) {
      throw BackupException(
        'Backup "$id" not found. Available: '
        '${backups.map((b) => b.id).join(', ')}',
      );
    }
    final contents = <String, List<int>>{};
    for (final relative in backup.files) {
      final source = File(p.join(backup.directory, 'files', relative));
      if (!source.existsSync()) {
        throw BackupException('Backup "${backup.id}" is missing $relative.');
      }
      contents[relative] = source.readAsBytesSync();
    }
    for (final entry in contents.entries) {
      final target = File(p.join(projectRoot, entry.key));
      target.parent.createSync(recursive: true);
      target.writeAsBytesSync(entry.value, flush: true);
    }
    return backup;
  }

  BackupInfo? _read(Directory dir) {
    final manifest = File(p.join(dir.path, _manifest));
    if (!manifest.existsSync()) return null;
    try {
      final json = jsonDecode(manifest.readAsStringSync());
      if (json is! Map<String, Object?>) return null;
      final files = json['files'];
      final removed = json['removed_keys'];
      return BackupInfo(
        id: json['id'] as String? ?? p.basename(dir.path),
        directory: dir.path,
        createdAt:
            DateTime.tryParse(json['created_at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        files: [
          if (files is List)
            for (final f in files)
              if (f is Map && f['path'] is String) f['path'] as String,
        ],
        removedKeys: [
          if (removed is List)
            for (final k in removed)
              if (k is String) k,
        ],
      );
    } on FormatException {
      return null;
    }
  }

  static String _formatId(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}-'
        '${t.millisecond.toString().padLeft(3, '0')}';
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
