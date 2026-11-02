/// A JSON syntax tree that remembers where every node lives in the source.
///
/// Offsets let the cleanup engine delete individual members by editing the
/// original text, so formatting, comments and untouched values survive
/// byte-for-byte.
library;

/// Base class for all nodes. [start] is inclusive and [end] exclusive.
sealed class JsonNode {
  JsonNode(this.start, this.end);

  final int start;
  final int end;

  /// The exact source text of this node.
  String sourceIn(String text) => text.substring(start, end);
}

class JsonObject extends JsonNode {
  JsonObject(super.start, super.end, this.members);

  final List<JsonMember> members;

  Iterable<JsonMember> membersNamed(String name) =>
      members.where((m) => m.name == name);
}

class JsonArray extends JsonNode {
  JsonArray(super.start, super.end, this.elements);

  final List<JsonNode> elements;
}

class JsonString extends JsonNode {
  JsonString(super.start, super.end, this.value);

  final String value;
}

class JsonNumber extends JsonNode {
  JsonNumber(super.start, super.end, this.value);

  final num value;
}

class JsonBool extends JsonNode {
  JsonBool(super.start, super.end, this.value);

  final bool value;
}

class JsonNull extends JsonNode {
  JsonNull(super.start, super.end);
}

/// A `"name": value` pair inside a [JsonObject].
class JsonMember {
  JsonMember({
    required this.name,
    required this.nameStart,
    required this.value,
    required this.commaOffset,
  });

  final String name;

  /// Offset of the opening quote of the member name.
  final int nameStart;
  final JsonNode value;

  /// Offset of the comma that follows this member, if any.
  final int? commaOffset;

  int get start => nameStart;
  int get end => value.end;
}

/// A parsed JSON (or JSONC) file.
class JsonDocument {
  JsonDocument({
    required this.text,
    required this.root,
    required this.hasComments,
    required this.hasTrailingCommas,
    required this.duplicateMembers,
  });

  /// Source text without a leading byte order mark.
  final String text;
  final JsonNode root;
  final bool hasComments;
  final bool hasTrailingCommas;

  /// Member names that appear more than once in the same object, with the
  /// offset of each repeated occurrence.
  final List<({String path, int offset})> duplicateMembers;

  late final List<int> _lineStarts = _computeLineStarts(text);

  /// Converts an offset into a 1-based (line, column) pair.
  ({int line, int column}) locationOf(int offset) =>
      locate(_lineStarts, offset);
}

List<int> _computeLineStarts(String text) {
  final starts = <int>[0];
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) starts.add(i + 1);
  }
  return starts;
}

/// Binary-searches [lineStarts] for the line containing [offset].
({int line, int column}) locate(List<int> lineStarts, int offset) {
  var low = 0;
  var high = lineStarts.length - 1;
  while (low < high) {
    final mid = (low + high + 1) >> 1;
    if (lineStarts[mid] <= offset) {
      low = mid;
    } else {
      high = mid - 1;
    }
  }
  return (line: low + 1, column: offset - lineStarts[low] + 1);
}

/// Thrown when a translation file is not valid JSON.
class JsonSyntaxException implements Exception {
  JsonSyntaxException(this.message, this.offset, this.line, this.column);

  final String message;
  final int offset;
  final int line;
  final int column;

  @override
  String toString() => '$message (line $line, column $column)';
}
