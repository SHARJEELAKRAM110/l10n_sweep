import 'dart:io';

import 'package:l10n_sweep/src/version.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('packageVersion matches pubspec.yaml', () {
    final pubspec = loadYaml(File('pubspec.yaml').readAsStringSync()) as Map;
    expect(packageVersion, pubspec['version']);
  });
}
