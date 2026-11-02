import 'package:path/path.dart' as p;

/// Converts an absolute path into a project-relative path with `/`
/// separators, which is how paths are matched, reported and stored.
String relativePosix(String absolutePath, String projectRoot) =>
    p.relative(absolutePath, from: projectRoot).replaceAll(r'\', '/');

/// Normalises a user-supplied relative path (`./lib/`, `lib\\generated`).
String normalizeRelative(String path) {
  var result = p.posix.normalize(path.replaceAll(r'\', '/'));
  if (result == '.') return '';
  while (result.endsWith('/')) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

/// Matches project-relative paths against directory prefixes and globs.
///
/// * `lib/generated` matches the directory and everything below it.
/// * `**/*.g.dart` matches any generated file. `*` stays within one path
///   segment, `**` crosses segments and `?` matches one character.
class PathMatcher {
  PathMatcher(Iterable<String> patterns) {
    for (final raw in patterns) {
      final pattern = normalizeRelative(raw);
      if (pattern.isEmpty) continue;
      if (pattern.contains(RegExp(r'[*?]'))) {
        _globs.add(RegExp('^${_globToRegex(pattern)}\$'));
      } else {
        _prefixes.add(pattern);
      }
    }
  }

  final List<String> _prefixes = [];
  final List<RegExp> _globs = [];

  bool get isEmpty => _prefixes.isEmpty && _globs.isEmpty;

  bool matches(String relativePath) {
    for (final prefix in _prefixes) {
      if (relativePath == prefix || relativePath.startsWith('$prefix/')) {
        return true;
      }
    }
    for (final glob in _globs) {
      if (glob.hasMatch(relativePath)) return true;
    }
    return false;
  }

  static String _globToRegex(String glob) {
    final buffer = StringBuffer();
    for (var i = 0; i < glob.length; i++) {
      final c = glob[i];
      if (c == '*') {
        final doubleStar = i + 1 < glob.length && glob[i + 1] == '*';
        if (doubleStar) {
          i++;
          final slashFollows = i + 1 < glob.length && glob[i + 1] == '/';
          if (slashFollows) {
            i++;
            buffer.write('(?:.*/)?');
          } else {
            buffer.write('.*');
          }
        } else {
          buffer.write('[^/]*');
        }
      } else if (c == '?') {
        buffer.write('[^/]');
      } else {
        buffer.write(RegExp.escape(c));
      }
    }
    return buffer.toString();
  }
}
