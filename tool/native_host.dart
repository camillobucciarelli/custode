import 'dart:io';

import 'native_host_macos_container.dart';
import 'native_host_protocol.dart';

Future<void> main() async {
  // macOS: assert app-group membership with containermanagerd before any
  // store I/O, so Sequoia treats this process as a group member and raw
  // file access below never blocks on a TCC prompt. No-op elsewhere,
  // fail-soft on macOS. See native_host_macos_container.dart.
  ensureMacosGroupContainerRegistered();

  final reader = NativeMessageStreamReader(stdin);

  while (true) {
    final Map<String, Object?>? request;
    try {
      request = await reader.readMessage();
    } on NativeHostProtocolException catch (error) {
      _logProtocolError(error);
      stdout.add(
        encodeNativeMessage(
          nativeHostErrorResponse(
            type: 'error',
            code: error.code,
            message: error.publicMessage,
          ),
        ),
      );
      await stdout.flush();
      if (!error.canContinue) {
        return;
      }
      continue;
    } catch (_) {
      stderr.writeln('[Custode native host] internal_error');
      stdout.add(
        encodeNativeMessage(
          nativeHostErrorResponse(
            type: 'error',
            code: 'internal_error',
            message: 'Native host failed to process the request.',
          ),
        ),
      );
      await stdout.flush();
      return;
    }

    if (request == null) {
      return;
    }

    final response = await handleNativeHostRequest(request);
    stdout.add(encodeNativeMessage(response));
    await stdout.flush();
  }
}

void _logProtocolError(NativeHostProtocolException error) {
  stderr.writeln('[Custode native host] protocol_error code=${error.code}');
}
