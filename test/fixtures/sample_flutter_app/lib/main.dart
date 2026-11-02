import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import 'generated/locale_keys.g.dart';
import 'screens/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await EasyLocalization.ensureInitialized();
  runApp(
    EasyLocalization(
      supportedLocales: const [Locale('en'), Locale('ur')],
      path: 'assets/translations',
      fallbackLocale: const Locale('en'),
      child: const SampleApp(),
    ),
  );
}

class SampleApp extends StatelessWidget {
  const SampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: LocaleKeys.app_name.tr(),
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
      home: const HomeScreen(),
    );
  }
}
