import 'source_location.dart';

/// Severity of an [AnalysisIssue].
enum IssueSeverity { info, warning, error }

/// A problem or notice discovered while analysing a project.
class AnalysisIssue {
  const AnalysisIssue({
    required this.severity,
    required this.code,
    required this.message,
    this.location,
  });

  const AnalysisIssue.error(String code, String message, {SourceLocation? at})
    : this(
        severity: IssueSeverity.error,
        code: code,
        message: message,
        location: at,
      );

  const AnalysisIssue.warning(String code, String message, {SourceLocation? at})
    : this(
        severity: IssueSeverity.warning,
        code: code,
        message: message,
        location: at,
      );

  const AnalysisIssue.info(String code, String message, {SourceLocation? at})
    : this(
        severity: IssueSeverity.info,
        code: code,
        message: message,
        location: at,
      );

  final IssueSeverity severity;

  /// Stable machine-readable identifier, for example `invalid_json`.
  final String code;
  final String message;
  final SourceLocation? location;

  Map<String, Object?> toJson() => {
    'severity': severity.name,
    'code': code,
    'message': message,
    if (location != null) 'location': location!.toJson(),
  };

  @override
  String toString() {
    final where = location == null ? '' : '$location: ';
    return '$where$message';
  }
}
