/// A position inside a file on disk.
class SourceLocation implements Comparable<SourceLocation> {
  const SourceLocation(this.path, this.line, this.column);

  /// Path relative to the project root, using forward slashes.
  final String path;

  /// 1-based line number.
  final int line;

  /// 1-based column number.
  final int column;

  Map<String, Object?> toJson() => {
    'path': path,
    'line': line,
    'column': column,
  };

  @override
  int compareTo(SourceLocation other) {
    final byPath = path.compareTo(other.path);
    if (byPath != 0) return byPath;
    final byLine = line.compareTo(other.line);
    if (byLine != 0) return byLine;
    return column.compareTo(other.column);
  }

  @override
  bool operator ==(Object other) =>
      other is SourceLocation &&
      other.path == path &&
      other.line == line &&
      other.column == column;

  @override
  int get hashCode => Object.hash(path, line, column);

  @override
  String toString() => '$path:$line:$column';
}
