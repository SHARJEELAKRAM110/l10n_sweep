import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../generated/locale_keys.g.dart';
import '../widgets/localized_text.dart';

const _tabKeys = ['tabs.home', 'tabs.settings'];

enum Section { news, events }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _count = 0;
  Section _section = Section.news;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(LocaleKeys.home_title.tr())),
      body: Column(
        children: [
          Text('profile.title'.tr()),
          Text('items_count'.plural(_count)),
          Text('greeting'.tr(namedArgs: {'name': 'Ayesha'})),
          const LocalizedText('settings.language'),
          Text(translate('errors.network', args: ['500'])),
          Text('sections.${_section.name}'.tr()),
          for (final key in _tabKeys) Text(key.tr()),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => setState(() => _count++),
        tooltip: context.tr('actions.increment'),
        child: const Icon(Icons.add),
      ),
    );
  }
}
