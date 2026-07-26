import 'dart:async';
import 'package:intiface_central/src/rust/api/runtime.dart';
import 'package:intiface_central/bloc/engine/engine_provider.dart';
import 'package:loggy/loggy.dart';

abstract interface class NativeEngineLifecycle {
  Future<void> stop();
  Future<bool> runtimeStarted();
}

class RustNativeEngineLifecycle implements NativeEngineLifecycle {
  const RustNativeEngineLifecycle();

  @override
  Future<void> stop() => stopEngine();

  @override
  Future<bool> runtimeStarted() => rustRuntimeStarted();
}

class LibraryEngineProvider implements EngineProvider {
  LibraryEngineProvider({NativeEngineLifecycle? nativeLifecycle})
    : _nativeLifecycle = nativeLifecycle ?? const RustNativeEngineLifecycle();

  final NativeEngineLifecycle _nativeLifecycle;
  StreamController<String> _processMessageStream = StreamController();
  Stream<String>? _stream;

  @override
  Future<void> start({required EngineOptionsExternal options}) async {
    _processMessageStream.close();
    _processMessageStream = StreamController();
    logInfo(
      "Starting library internal engine with the following arguments: $options",
    );
    try {
      _stream = runEngine(args: options);
    } catch (e) {
      logError("Engine start failed!");
      await stop();
      return;
    }
    logInfo("Engine started");
    _stream!
        .listen((element) {
          try {
            _processMessageStream.add(element);
          } catch (e) {
            logError("Error adding message to stream: $e");
            stop();
          }
        })
        .onError((e) => logError(e.anyhow));
  }

  @override
  Future<bool> runtimeStarted() => _nativeLifecycle.runtimeStarted();

  @override
  Future<void> stop() async {
    try {
      await _nativeLifecycle.stop();
      logInfo("Engine stopped");
    } catch (error) {
      logError("Engine stop failed: $error");
      rethrow;
    }
  }

  @override
  void send(String msg) {
    sendRuntimeMsg(msgJson: msg);
  }

  @override
  void sendBackdoorMessage(String msg) {
    //logInfo("Outgoing: $msg");
    sendBackendServerMessage(msg: msg);
  }

  @override
  Stream<String> get engineRawMessageStream => _processMessageStream.stream;
}
