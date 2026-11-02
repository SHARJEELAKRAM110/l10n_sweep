# Changelog

All notable changes to this project are documented here. The project follows
[Semantic Versioning](https://semver.org).

## 0.1.0

Initial release.

- `analyze`: classifies every easy_localization key as used, dynamically
  referenced, potentially unused, unused or excluded, using Dart AST analysis.
  Follows constants, generated `LocaleKeys`, fields, getters, collections,
  wrapper functions, wrapper widgets and `extension on String` members.
- Conservative handling of dynamic keys: interpolated keys become patterns,
  and translation calls whose key cannot be determined prevent any key from
  being reported as definitely unused.
- `// l10n_sweep:keys <pattern>` and `// l10n_sweep:ignore` source comments.
- Plural and gender groups, linked translations (`@:key`) and flat dotted keys.
- Multi-locale support: missing keys, extra keys and per-locale unused counts
  relative to a primary locale.
- `clean`: interactive selection, `--dry-run`, and `--yes` for definitely
  unused keys only. Edits preserve formatting byte-for-byte, are verified by
  re-parsing, are backed up, and are applied all-or-nothing.
- `restore`: restore locale files from a backup.
- Warns about translated text being translated again (`'key'.tr().tr()`).
- `report`: JSON and Markdown reports for CI and pull requests.
- `doctor`: checks project setup and reports unsupported patterns.
- `init`: generates `l10n_sweep.yaml` from the detected project structure.
- CI flags: `--fail-on-unused`, `--fail-on-missing`, `--fail-on-uncertain`,
  `--fail-on-undefined`.
