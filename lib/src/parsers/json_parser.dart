import 'json_document.dart';

/// A strict, position-tracking JSON parser with optional JSONC extensions.
///
/// Unlike `dart:convert`, it keeps the offset of every node and member so the
/// file can later be edited surgically. Comments (`//`, `/* */`) and trailing
/// commas are accepted and recorded on the resulting [JsonDocument]; callers
/// decide whether they are acceptable for a given file.
class JsonParser {
  JsonParser._(this._text);

  static const _maxDepth = 512;

  /// Parses [source]. A leading UTF-8 byte order mark is removed.
  ///
  /// Throws [JsonSyntaxException] on malformed input.
  static JsonDocument parse(String source) {
    final text = source.startsWith('﻿') ? source.substring(1) : source;
    final parser = JsonParser._(text);
    final root = parser._parseDocument();
    return JsonDocument(
      text: text,
      root: root,
      hasComments: parser._hasComments,
      hasTrailingCommas: parser._hasTrailingCommas,
      duplicateMembers: parser._duplicates,
    );
  }

  final String _text;
  int _pos = 0;
  int _depth = 0;
  bool _hasComments = false;
  bool _hasTrailingCommas = false;
  final List<({String path, int offset})> _duplicates = [];
  final List<String> _path = [];

  JsonNode _parseDocument() {
    _skipTrivia();
    if (_pos >= _text.length) _fail('File is empty; expected a JSON object');
    final value = _parseValue();
    _skipTrivia();
    if (_pos < _text.length) {
      _fail('Unexpected ${_describe(_pos)} after the end of the JSON value');
    }
    return value;
  }

  JsonNode _parseValue() {
    _skipTrivia();
    if (_pos >= _text.length) _fail('Unexpected end of file; expected a value');
    final c = _text.codeUnitAt(_pos);
    switch (c) {
      case 0x7B: // {
        return _parseObject();
      case 0x5B: // [
        return _parseArray();
      case 0x22: // "
        final start = _pos;
        final value = _parseString();
        return JsonString(start, _pos, value);
      case 0x74: // t
        return _parseLiteral('true', (s, e) => JsonBool(s, e, true));
      case 0x66: // f
        return _parseLiteral('false', (s, e) => JsonBool(s, e, false));
      case 0x6E: // n
        return _parseLiteral('null', JsonNull.new);
      default:
        if (c == 0x2D || (c >= 0x30 && c <= 0x39)) return _parseNumber();
        _fail('Unexpected ${_describe(_pos)}; expected a value');
    }
  }

  JsonObject _parseObject() {
    final start = _pos;
    _enter();
    _pos++; // {
    final members = <JsonMember>[];
    final seen = <String>{};
    _skipTrivia();
    if (_peek() == 0x7D) {
      _pos++;
      _depth--;
      return JsonObject(start, _pos, members);
    }
    while (true) {
      _skipTrivia();
      if (_peek() != 0x22) {
        _fail('Expected a double-quoted member name, found ${_describe(_pos)}');
      }
      final nameStart = _pos;
      final name = _parseString();
      if (!seen.add(name)) {
        _duplicates.add((path: [..._path, name].join('.'), offset: nameStart));
      }
      _skipTrivia();
      if (_peek() != 0x3A) {
        _fail('Expected ":" after member name "$name"');
      }
      _pos++;
      _path.add(name);
      final value = _parseValue();
      _path.removeLast();
      _skipTrivia();
      final next = _peek();
      if (next == 0x2C) {
        final comma = _pos;
        _pos++;
        members.add(
          JsonMember(
            name: name,
            nameStart: nameStart,
            value: value,
            commaOffset: comma,
          ),
        );
        _skipTrivia();
        if (_peek() == 0x7D) {
          _hasTrailingCommas = true;
          _pos++;
          break;
        }
        continue;
      }
      members.add(
        JsonMember(
          name: name,
          nameStart: nameStart,
          value: value,
          commaOffset: null,
        ),
      );
      if (next == 0x7D) {
        _pos++;
        break;
      }
      _fail('Expected "," or "}" after the value of "$name"');
    }
    _depth--;
    return JsonObject(start, _pos, members);
  }

  JsonArray _parseArray() {
    final start = _pos;
    _enter();
    _pos++; // [
    final elements = <JsonNode>[];
    _skipTrivia();
    if (_peek() == 0x5D) {
      _pos++;
      _depth--;
      return JsonArray(start, _pos, elements);
    }
    while (true) {
      elements.add(_parseValue());
      _skipTrivia();
      final next = _peek();
      if (next == 0x2C) {
        _pos++;
        _skipTrivia();
        if (_peek() == 0x5D) {
          _hasTrailingCommas = true;
          _pos++;
          break;
        }
        continue;
      }
      if (next == 0x5D) {
        _pos++;
        break;
      }
      _fail('Expected "," or "]" in array');
    }
    _depth--;
    return JsonArray(start, _pos, elements);
  }

  String _parseString() {
    final open = _pos;
    _pos++; // opening quote
    final buffer = StringBuffer();
    var chunkStart = _pos;
    while (true) {
      if (_pos >= _text.length) {
        _failAt(open, 'Unterminated string');
      }
      final c = _text.codeUnitAt(_pos);
      if (c == 0x22) {
        buffer.write(_text.substring(chunkStart, _pos));
        _pos++;
        return buffer.toString();
      }
      if (c < 0x20) {
        _fail('Control character U+${_hex(c)} must be escaped in a string');
      }
      if (c != 0x5C) {
        _pos++;
        continue;
      }
      buffer.write(_text.substring(chunkStart, _pos));
      _pos++;
      if (_pos >= _text.length) _failAt(open, 'Unterminated string');
      final e = _text.codeUnitAt(_pos);
      switch (e) {
        case 0x22:
          buffer.write('"');
        case 0x5C:
          buffer.write(r'\');
        case 0x2F:
          buffer.write('/');
        case 0x62:
          buffer.write('\b');
        case 0x66:
          buffer.write('\f');
        case 0x6E:
          buffer.write('\n');
        case 0x72:
          buffer.write('\r');
        case 0x74:
          buffer.write('\t');
        case 0x75:
          if (_pos + 4 >= _text.length) {
            _fail(r'Incomplete \u escape sequence');
          }
          final hex = _text.substring(_pos + 1, _pos + 5);
          if (!_hexPattern.hasMatch(hex)) {
            _fail('Invalid escape sequence "\\u$hex"');
          }
          final code = int.parse(hex, radix: 16);
          buffer.writeCharCode(code);
          _pos += 4;
        default:
          _fail('Invalid escape sequence "\\${String.fromCharCode(e)}"');
      }
      _pos++;
      chunkStart = _pos;
    }
  }

  static final _hexPattern = RegExp(r'^[0-9a-fA-F]{4}$');

  static final _numberPattern = RegExp(
    r'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?',
  );

  JsonNumber _parseNumber() {
    final match = _numberPattern.matchAsPrefix(_text, _pos);
    if (match == null) _fail('Invalid number');
    final start = _pos;
    _pos = match.end;
    if (_pos < _text.length && _isIdentifierChar(_text.codeUnitAt(_pos))) {
      _fail('Invalid number');
    }
    return JsonNumber(start, _pos, num.parse(match[0]!));
  }

  JsonNode _parseLiteral(String word, JsonNode Function(int, int) build) {
    if (!_text.startsWith(word, _pos) ||
        (_pos + word.length < _text.length &&
            _isIdentifierChar(_text.codeUnitAt(_pos + word.length)))) {
      _fail('Unexpected ${_describe(_pos)}; expected a value');
    }
    final start = _pos;
    _pos += word.length;
    return build(start, _pos);
  }

  /// Skips whitespace and JSONC comments.
  void _skipTrivia() {
    while (_pos < _text.length) {
      final c = _text.codeUnitAt(_pos);
      if (c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09) {
        _pos++;
      } else if (c == 0x2F && _pos + 1 < _text.length) {
        final n = _text.codeUnitAt(_pos + 1);
        if (n == 0x2F) {
          _hasComments = true;
          final eol = _text.indexOf('\n', _pos);
          _pos = eol == -1 ? _text.length : eol + 1;
        } else if (n == 0x2A) {
          _hasComments = true;
          final close = _text.indexOf('*/', _pos + 2);
          if (close == -1) _fail('Unterminated block comment');
          _pos = close + 2;
        } else {
          return;
        }
      } else {
        return;
      }
    }
  }

  void _enter() {
    if (++_depth > _maxDepth) {
      _fail('Nesting is deeper than $_maxDepth levels');
    }
  }

  int? _peek() => _pos < _text.length ? _text.codeUnitAt(_pos) : null;

  static bool _isIdentifierChar(int c) =>
      (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x5A) ||
      (c >= 0x61 && c <= 0x7A) ||
      c == 0x5F ||
      c == 0x2E;

  String _describe(int offset) {
    if (offset >= _text.length) return 'end of file';
    final c = _text[offset];
    return c.trim().isEmpty ? 'whitespace' : '"$c"';
  }

  static String _hex(int c) =>
      c.toRadixString(16).toUpperCase().padLeft(4, '0');

  Never _fail(String message) => _failAt(_pos, message);

  Never _failAt(int offset, String message) {
    final lineStarts = <int>[0];
    for (var i = 0; i < offset && i < _text.length; i++) {
      if (_text.codeUnitAt(i) == 0x0A) lineStarts.add(i + 1);
    }
    final loc = locate(lineStarts, offset);
    throw JsonSyntaxException(message, offset, loc.line, loc.column);
  }
}
