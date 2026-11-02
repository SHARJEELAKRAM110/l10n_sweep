import 'dart:io';

import 'package:l10n_sweep/cli.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await L10nSweepCli().run(arguments);
}
