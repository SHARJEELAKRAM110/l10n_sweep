@Tags(['performance'])
library;

import 'package:test/test.dart';

import '../helpers.dart';

/// Guards against accidental quadratic behaviour on large projects.
void main() {
  test('analyzes a large project in reasonable time', () {
    const keyCount = 20000;
    const fileCount = 400;
    final json = StringBuffer('{\n');
    for (var i = 0; i < keyCount; i++) {
      json.write(
        '  "section${i ~/ 10}": {"key$i": "Value $i @:section0.key0"}',
      );
      json.write(i == keyCount - 1 ? '\n' : ',\n');
    }
    json.write('}\n');
    final dart = <String, String>{};
    for (var f = 0; f < fileCount; f++) {
      final buffer = StringBuffer('const keys$f = [\n');
      for (var i = 0; i < 5; i++) {
        buffer.writeln("  'section${f * 5 + i}.key${(f * 5 + i) * 10}',");
      }
      buffer
        ..writeln('];')
        ..writeln('class Screen$f {')
        ..writeln('  Widget build(BuildContext context) => Column(children: [')
        ..writeln('    for (final k in keys$f) Text(k.tr()),')
        ..writeln("    Text('section$f.key${f * 10 + 1}'.tr()),")
        ..writeln("    Text(context.tr('section$f.key${f * 10 + 2}')),")
        ..writeln('  ]);')
        ..writeln('}');
      dart['lib/screen_$f.dart'] = buffer.toString();
    }
    final stopwatch = Stopwatch()..start();
    final report = analyzeMemory(dart: dart, json: enJson(json.toString()));
    stopwatch.stop();
    expect(report.keys, hasLength(keyCount));
    expect(report.unusedKeys, isNotEmpty);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 30)));
    printOnFailure('Analysis took ${stopwatch.elapsedMilliseconds} ms');
  });
}
