import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The path-hash id of a database (`sha256:` of the trimmed path): what the
/// desktop browser cache is published under, and the legacy / unregistered
/// form of the mobile and Apple autofill id (see `autofillDatabaseIdsFor`).
String databaseIdForPath(String databasePath) {
  return 'sha256:${sha256.convert(utf8.encode(databasePath.trim()))}';
}

/// The host of [rawValue], lowercased and collapsed onto its bare form.
///
/// Set [stripPrefixes] to `false` to get the host *as served*, keeping the
/// `www.`/`m.`/`mobile.` label. Only security predicates need that form.
String? normalizedHost(String? rawValue, {bool stripPrefixes = true}) {
  final value = rawValue?.trim() ?? '';
  if (value.isEmpty) {
    return null;
  }
  if (isNativeAppValue(value)) {
    return null;
  }
  final uri = Uri.tryParse(valueWithDefaultScheme(value));
  final rawHost = (uri != null && uri.host.isNotEmpty)
      ? uri.host
      : value.split('/').first.split(':').first;
  return cleanHost(rawHost, stripPrefixes: stripPrefixes);
}

String valueWithDefaultScheme(String value) {
  if (value.contains('://')) {
    return value;
  }
  if (value.startsWith('//')) {
    return 'https:$value';
  }
  return 'https://$value';
}

String? cleanHost(String? rawHost, {bool stripPrefixes = true}) {
  var host = rawHost?.trim().toLowerCase() ?? '';
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  while (host.endsWith('.')) {
    host = host.substring(0, host.length - 1);
  }
  if (stripPrefixes) {
    for (final prefix in const ['www.', 'm.', 'mobile.']) {
      if (host.startsWith(prefix)) {
        host = host.substring(prefix.length);
        break;
      }
    }
  }
  if (host.isEmpty || host.length > 253 || host.contains(RegExp(r'[\s/@:]'))) {
    return null;
  }
  return host;
}

bool isNativeAppValue(String value) {
  final normalized = value.trim().toLowerCase();
  return normalized.startsWith('androidapp:') ||
      normalized.startsWith('iosbundleid:');
}
