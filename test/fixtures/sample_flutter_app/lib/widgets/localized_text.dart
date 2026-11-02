import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

/// A wrapper widget that translates its key.
class LocalizedText extends StatelessWidget {
  const LocalizedText(this.textKey, {super.key, this.style});

  final String textKey;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Text(textKey.tr(), style: style);
}

/// A helper function that translates a key with arguments.
String translate(String key, {List<String>? args}) => key.tr(args: args);
