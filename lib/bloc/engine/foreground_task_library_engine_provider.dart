import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'dart:isolate';
import 'dart:io';
import 'package:intiface_central/bloc/configuration/intiface_configuration_cubit.dart';
import 'package:intiface_central/bloc/engine/engine_messages.dart';
import 'package:intiface_central/src/rust/api/runtime.dart';
import 'package:intiface_central/bloc/engine/engine_provider.dart';
import 'package:intiface_central/bloc/engine/library_engine_provider.dart';
import 'package:intiface_central/src/rust/frb_generated.dart';
import 'package:intiface_central/util/mdns_platform_service.dart';
import 'package:intiface_central/util/intiface_util.dart';
import 'package:loggy/loggy.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

String _kMainBackdoorPortName = "intifaceCentralBackdoorMain";
String _kMainServerPortName = "intifaceCentralServerMain";
String _kMainShutdownPortName = "intifaceCentralShutdownMain";
const _kStartupAttemptIdKey = "intifaceCentralStartupAttemptId";
const foregroundShutdownResultTimeout = Duration(seconds: 30);
const foregroundStartupResultTimeout = Duration(seconds: 30);

typedef AsyncVoidCallback = Future<void> Function();
typedef ShutdownResultSender =
    FutureOr<void> Function(ForegroundShutdownResult result);
typedef StartupAttemptIdReader = Future<int> Function();
typedef StartupAttemptIdWriter = Future<void> Function(int attemptId);
typedef PortLookup = SendPort? Function(String name);
typedef ForegroundServiceStarter = Future<ServiceRequestResult> Function();
typedef ForegroundServiceRunning = Future<bool> Function();

class ForegroundShutdownRequest {
  const ForegroundShutdownRequest(this.attemptId);

  final int attemptId;

  Map<String, Object?> toMessage() => <String, Object?>{
    'type': 'intifaceForegroundShutdownRequest',
    'attemptId': attemptId,
  };

  static ForegroundShutdownRequest? fromMessage(Object? message) {
    if (message is! Map ||
        message['type'] != 'intifaceForegroundShutdownRequest' ||
        message['attemptId'] is! int) {
      return null;
    }
    return ForegroundShutdownRequest(message['attemptId'] as int);
  }
}

class ForegroundShutdownResult {
  const ForegroundShutdownResult.success(this.attemptId) : error = null;
  const ForegroundShutdownResult.error(this.attemptId, this.error);

  final int attemptId;
  final String? error;
  bool get isSuccess => error == null;

  Map<String, Object?> toMessage() => <String, Object?>{
    'type': 'intifaceForegroundShutdown',
    'attemptId': attemptId,
    'error': error,
  };

  static ForegroundShutdownResult? fromMessage(Object? message) {
    if (message is! Map ||
        message['type'] != 'intifaceForegroundShutdown' ||
        message['attemptId'] is! int) {
      return null;
    }
    final attemptId = message['attemptId'] as int;
    final error = message['error'];
    return error == null
        ? ForegroundShutdownResult.success(attemptId)
        : ForegroundShutdownResult.error(attemptId, error.toString());
  }
}

class ForegroundStartupResult {
  const ForegroundStartupResult.success(this.attemptId) : error = null;
  const ForegroundStartupResult.error(this.attemptId, this.error);

  final int attemptId;
  final String? error;
  bool get isSuccess => error == null;

  Map<String, Object?> toMessage() => <String, Object?>{
    'type': 'intifaceForegroundStartup',
    'attemptId': attemptId,
    'error': error,
  };

  static ForegroundStartupResult? fromMessage(Object? message) {
    if (message is! Map ||
        message['type'] != 'intifaceForegroundStartup' ||
        message['attemptId'] is! int) {
      return null;
    }
    final attemptId = message['attemptId'] as int;
    final error = message['error'];
    return error == null
        ? ForegroundStartupResult.success(attemptId)
        : ForegroundStartupResult.error(attemptId, error.toString());
  }
}

class ForegroundStartupException implements Exception {
  const ForegroundStartupException(this.message);

  final String message;

  @override
  String toString() => 'Foreground engine startup failed: $message';
}

class ForegroundShutdownException implements Exception {
  const ForegroundShutdownException(this.message);

  final String message;

  @override
  String toString() => 'Foreground engine shutdown failed: $message';
}

class ForegroundAttempt {
  ForegroundAttempt(this.id, this.future);

  final int id;
  final Future<void> future;
}

class _ActiveAttempt {
  _ActiveAttempt(this.id) : completer = Completer<void>();

  final int id;
  final Completer<void> completer;
  Timer? timer;
}

class ForegroundStartupCompletion {
  ForegroundStartupCompletion({this.timeout = foregroundStartupResultTimeout});

  final Duration timeout;
  _ActiveAttempt? _active;

  ForegroundAttempt begin(int attemptId) {
    final current = _active;
    if (current != null) {
      return ForegroundAttempt(current.id, current.completer.future);
    }
    final created = _ActiveAttempt(attemptId);
    _active = created;
    created.timer = Timer(timeout, () {
      if (identical(_active, created) && !created.completer.isCompleted) {
        created.completer.completeError(
          const ForegroundStartupException(
            'timed out waiting for foreground startup result',
          ),
        );
        _clear(created);
      }
    });
    return ForegroundAttempt(created.id, created.completer.future);
  }

  bool get isInFlight => _active != null;
  int? get activeAttemptId => _active?.id;

  bool complete(ForegroundStartupResult result) {
    final active = _active;
    if (active == null ||
        active.id != result.attemptId ||
        active.completer.isCompleted) {
      return false;
    }
    if (result.isSuccess) {
      active.completer.complete();
    } else {
      active.completer.completeError(ForegroundStartupException(result.error!));
    }
    _clear(active);
    return true;
  }

  void _clear(_ActiveAttempt active) {
    if (!identical(_active, active)) return;
    active.timer?.cancel();
    _active = null;
  }
}

class ForegroundShutdownCompletion {
  ForegroundShutdownCompletion({
    required AsyncVoidCallback stopService,
    this.timeout = foregroundShutdownResultTimeout,
  }) : _stopService = stopService;

  final AsyncVoidCallback _stopService;
  final Duration timeout;
  _ActiveAttempt? _active;

  ForegroundAttempt begin(int attemptId) {
    final current = _active;
    if (current != null) {
      return ForegroundAttempt(current.id, current.completer.future);
    }
    final created = _ActiveAttempt(attemptId);
    _active = created;
    created.timer = Timer(timeout, () {
      if (identical(_active, created) && !created.completer.isCompleted) {
        created.completer.completeError(
          const ForegroundShutdownException(
            'timed out waiting for foreground shutdown result',
          ),
        );
        _clear(created);
      }
    });
    return ForegroundAttempt(created.id, created.completer.future);
  }

  bool get isInFlight => _active != null;
  int? get activeAttemptId => _active?.id;

  Future<bool> complete(ForegroundShutdownResult result) async {
    final active = _active;
    if (active == null ||
        active.id != result.attemptId ||
        active.completer.isCompleted) {
      return false;
    }
    if (!result.isSuccess) {
      active.completer.completeError(
        ForegroundShutdownException(result.error!),
      );
      _clear(active);
      return true;
    }
    try {
      await _stopService();
      if (!active.completer.isCompleted) active.completer.complete();
    } catch (error, stackTrace) {
      if (!active.completer.isCompleted) {
        active.completer.completeError(
          ForegroundShutdownException('failed to stop service: $error'),
          stackTrace,
        );
      }
    } finally {
      _clear(active);
    }
    return true;
  }

  void _clear(_ActiveAttempt active) {
    if (!identical(_active, active)) return;
    active.timer?.cancel();
    _active = null;
  }
}

class ForegroundShutdownHandler {
  ForegroundShutdownHandler({
    required NativeEngineLifecycle nativeLifecycle,
    required AsyncVoidCallback cleanup,
    required ShutdownResultSender sendResult,
  }) : _nativeLifecycle = nativeLifecycle,
       _cleanup = cleanup,
       _sendResult = sendResult;

  final NativeEngineLifecycle _nativeLifecycle;
  final AsyncVoidCallback _cleanup;
  final ShutdownResultSender _sendResult;
  Future<void>? _inFlight;
  ForegroundShutdownResult? _terminalResult;

  Future<void> shutdown(int attemptId) {
    final current = _inFlight;
    if (current != null) {
      // Keep A's future unchanged for its caller, but always reconcile B after
      // A settles. The error handler is intentionally attached here so the
      // queued continuation does not become a detached unhandled future.
      return current.then<void>(
        (_) => shutdown(attemptId),
        onError: (Object _, StackTrace stackTrace) => shutdown(attemptId),
      );
    }
    final terminal = _terminalResult;
    if (terminal != null && terminal.attemptId != attemptId) {
      _terminalResult = terminal.isSuccess
          ? ForegroundShutdownResult.success(attemptId)
          : ForegroundShutdownResult.error(attemptId, terminal.error!);
    }
    late final Future<void> attempt;
    attempt = _runAndReset(attemptId, () => attempt);
    _inFlight = attempt;
    return attempt;
  }

  Future<void> _runAndReset(
    int attemptId,
    Future<void> Function() identity,
  ) async {
    try {
      await _run(attemptId);
    } finally {
      final attempt = identity();
      if (identical(_inFlight, attempt)) _inFlight = null;
    }
  }

  Future<void> _run(int attemptId) async {
    var result = _terminalResult;
    if (result == null) {
      final errors = <String>[];
      try {
        await _nativeLifecycle.stop();
      } catch (error) {
        errors.add('native stop: $error');
      }
      try {
        await _cleanup();
      } catch (error) {
        errors.add('multicast cleanup: $error');
      }
      result = errors.isEmpty
          ? ForegroundShutdownResult.success(attemptId)
          : ForegroundShutdownResult.error(attemptId, errors.join('; '));
      _terminalResult = result;
    }

    try {
      await _sendResult(result);
    } catch (error) {
      throw ForegroundShutdownException(
        'failed to send shutdown result: $error',
      );
    }
  }
}

// The callback function should always be a top-level function.
@pragma('vm:entry-point')
void startCallback() {
  // The setTaskHandler function must be called to handle the task in the background.
  FlutterForegroundTask.setTaskHandler(IntifaceEngineTaskHandler());
}

class IntifaceEngineTaskHandler extends TaskHandler {
  final ReceivePort _serverMessageReceivePort;
  final ReceivePort _backdoorMessageReceivePort;
  final ReceivePort _shutdownReceivePort;
  Stream<String>? _stream;
  final NativeEngineLifecycle _nativeLifecycle;
  final StartupAttemptIdReader _startupAttemptIdReader;
  late final ForegroundShutdownHandler _shutdownHandler;
  bool _mdnsMulticastLockAcquired = false;

  void _sendProviderLog(String level, String outgoingMessage) {
    var message = EngineProviderLog();
    message.timestamp = DateTime.now().toString();
    message.level = level;
    message.message = outgoingMessage;
    var engineMessage = EngineMessage();
    engineMessage.engineProviderLog = message;
    FlutterForegroundTask.sendDataToMain(jsonEncode(engineMessage));
  }

  Future<void> _acquireMdnsMulticastLock() async {
    if (_mdnsMulticastLockAcquired) {
      return;
    }
    try {
      _mdnsMulticastLockAcquired = await MdnsPlatformService.instance
          .acquireMdnsMulticastLock();
      if (_mdnsMulticastLockAcquired) {
        _sendProviderLog("INFO", "Acquired mDNS multicast lock");
      } else {
        _sendProviderLog("WARN", "mDNS multicast lock was not acquired");
      }
    } catch (e) {
      _sendProviderLog("ERROR", "Failed to acquire mDNS multicast lock: $e");
    }
  }

  Future<void> _releaseMdnsMulticastLock() async {
    if (!_mdnsMulticastLockAcquired) {
      return;
    }
    _mdnsMulticastLockAcquired = false;
    try {
      final released = await MdnsPlatformService.instance
          .releaseMdnsMulticastLock();
      if (released) {
        _sendProviderLog("INFO", "Released mDNS multicast lock");
      } else {
        _sendProviderLog(
          "WARN",
          "mDNS multicast lock release reported failure",
        );
      }
    } catch (e) {
      _sendProviderLog("ERROR", "Failed to release mDNS multicast lock: $e");
      rethrow;
    }
  }

  IntifaceEngineTaskHandler({
    NativeEngineLifecycle? nativeLifecycle,
    StartupAttemptIdReader? startupAttemptIdReader,
  }) : _nativeLifecycle = nativeLifecycle ?? const RustNativeEngineLifecycle(),
       _startupAttemptIdReader =
           startupAttemptIdReader ??
           (() async {
             final attemptId = await FlutterForegroundTask.getData<int>(
               key: _kStartupAttemptIdKey,
             );
             if (attemptId == null) {
               throw StateError('missing foreground startup attempt ID');
             }
             return attemptId;
           }),
       _serverMessageReceivePort = ReceivePort(),
       _backdoorMessageReceivePort = ReceivePort(),
       _shutdownReceivePort = ReceivePort() {
    _shutdownHandler = ForegroundShutdownHandler(
      nativeLifecycle: _nativeLifecycle,
      cleanup: _releaseMdnsMulticastLock,
      sendResult: (result) =>
          FlutterForegroundTask.sendDataToMain(result.toMessage()),
    );
    final serverSendPort = _serverMessageReceivePort.sendPort;
    final backdoorSendPort = _backdoorMessageReceivePort.sendPort;
    final shutdownSendPort = _shutdownReceivePort.sendPort;
    // Defensively remove any stale mappings before registering. registerPortWithName()
    // returns false without overwriting if a name is already taken, so without this
    // a restarted service would silently fail to register its ports.
    IsolateNameServer.removePortNameMapping(_kMainServerPortName);
    IsolateNameServer.removePortNameMapping(_kMainBackdoorPortName);
    IsolateNameServer.removePortNameMapping(_kMainShutdownPortName);
    IsolateNameServer.registerPortWithName(
      serverSendPort,
      _kMainServerPortName,
    );
    IsolateNameServer.registerPortWithName(
      backdoorSendPort,
      _kMainBackdoorPortName,
    );
    IsolateNameServer.registerPortWithName(
      shutdownSendPort,
      _kMainShutdownPortName,
    );
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    int attemptId;
    try {
      attemptId = await _startupAttemptIdReader();
    } catch (error) {
      _sendProviderLog("ERROR", "Cannot read startup attempt ID: $error");
      return;
    }
    try {
      await _startEngine();
      FlutterForegroundTask.sendDataToMain(
        ForegroundStartupResult.success(attemptId).toMessage(),
      );
    } catch (error) {
      _sendProviderLog("ERROR", "Engine startup failed: $error");
      try {
        await _releaseMdnsMulticastLock();
      } catch (_) {}
      FlutterForegroundTask.sendDataToMain(
        ForegroundStartupResult.error(attemptId, error.toString()).toMessage(),
      );
    }
  }

  Future<void> _startEngine() async {
    _sendProviderLog("Info", "Trying to start engine in foreground service.");
    await RustLib.init();

    // Due to the way the foregrounding package we're using works, we can't store the options across the foregrounding
    // process boundary. Trying to encode to/decode from JSON also isn't easily possible because EngineOptionsExternal
    // is a FFI generated class. Therefore we just bring up what is considered to be a readonly version of our config
    // repo in order to build the engine options, then we just drop it when done.
    //
    // Under the covers, flutter_foreground_task is just using SharedPreferences for its data commands anyways, so this
    // is basically doing what it does, while not having to deal with shuffling things around.
    _sendProviderLog("INFO", "Creating config repo");
    var configRepo = await IntifaceConfigurationCubit.create();
    _sendProviderLog("INFO", "Building arguments");

    // Since we're on another process we'll have to reinitialize our paths.
    await IntifacePaths.init();

    // Ok, NOW we can build our engine options.
    var engineOptions = await configRepo.getEngineOptions();
    _sendProviderLog("INFO", "Starting engine");
    if (Platform.isAndroid && engineOptions.broadcastServerMdns) {
      await _acquireMdnsMulticastLock();
    }

    _sendProviderLog(
      "INFO",
      "Starting library internal engine with the following arguments: $engineOptions",
    );
    _stream = runEngine(args: engineOptions);
    _sendProviderLog("INFO", "Engine started");
    _stream!.listen((element) {
      try {
        // Send first
        FlutterForegroundTask.sendDataToMain(element);
        // EngineStopped must be forwarded before frontend closure, but it is
        // user-visible event ordering only. Native stop completion is the
        // authoritative restart-safe teardown boundary.
        jsonDecode(element);
      } catch (e) {
        // There's a chance the message may not decode it could possibly be from the backend server. So just no-op here.
      }
    });
    _serverMessageReceivePort.listen((element) async {
      await sendRuntimeMsg(msgJson: element);
    });
    _backdoorMessageReceivePort.listen((element) async {
      await sendBackendServerMessage(msg: element);
    });
    _shutdownReceivePort.listen((element) async {
      final request = ForegroundShutdownRequest.fromMessage(element);
      if (request == null) {
        _sendProviderLog("WARN", "Ignoring invalid engine shutdown request");
        return;
      }
      _sendProviderLog(
        "INFO",
        "Engine shutdown request ${request.attemptId} received",
      );
      try {
        await _shutdownHandler.shutdown(request.attemptId);
      } catch (error) {
        _sendProviderLog(
          "ERROR",
          "Engine shutdown acknowledgement failed: $error",
        );
      }
    });
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    // Send data to the main isolate.
    //sendPort?.send(timestamp);
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool whatever) async {
    _sendProviderLog("INFO", "Shutting down foreground task");
    // If the app was swiped away without the normal shutdown protocol,
    // stop the active native generation directly. A successful stop is the
    // restart-safe boundary; EngineStopped observation is not used here.
    if (await _nativeLifecycle.runtimeStarted()) {
      _sendProviderLog(
        "INFO",
        "Engine still running in onDestroy, stopping directly",
      );
      try {
        await _nativeLifecycle.stop();
      } finally {
        await _releaseMdnsMulticastLock();
      }
    } else {
      await _releaseMdnsMulticastLock();
    }
    // Only remove port mappings that still point to OUR ports. If a new
    // ForegroundService instance started before onDestroy() fires, it already
    // removed our mappings and registered its own. Unconditionally removing
    // here would steal the new instance's ports, making its shutdown port
    // unreachable and leaving shutdown result waiters unresolved.
    if (IsolateNameServer.lookupPortByName(_kMainServerPortName) ==
        _serverMessageReceivePort.sendPort) {
      IsolateNameServer.removePortNameMapping(_kMainServerPortName);
    }
    if (IsolateNameServer.lookupPortByName(_kMainBackdoorPortName) ==
        _backdoorMessageReceivePort.sendPort) {
      IsolateNameServer.removePortNameMapping(_kMainBackdoorPortName);
    }
    if (IsolateNameServer.lookupPortByName(_kMainShutdownPortName) ==
        _shutdownReceivePort.sendPort) {
      IsolateNameServer.removePortNameMapping(_kMainShutdownPortName);
    }
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == "stopServerButton") {
      FlutterForegroundTask.stopService();
    } else {
      // Called when the notification button on the Android platform is pressed.
      _sendProviderLog("ERROR", "Button id $id not recognized");
    }
  }
}

class ForegroundTaskLibraryEngineProvider implements EngineProvider {
  ForegroundTaskLibraryEngineProvider({
    NativeEngineLifecycle? nativeLifecycle,
    AsyncVoidCallback? stopService,
    Duration shutdownTimeout = foregroundShutdownResultTimeout,
    Duration startupTimeout = foregroundStartupResultTimeout,
    PortLookup? portLookup,
    StartupAttemptIdWriter? startupAttemptIdWriter,
  }) : _nativeLifecycle = nativeLifecycle ?? const RustNativeEngineLifecycle(),
       _stopService =
           stopService ??
           (() async {
             await FlutterForegroundTask.stopService();
           }),
       _portLookup = portLookup ?? IsolateNameServer.lookupPortByName,
       _startupAttemptIdWriter =
           startupAttemptIdWriter ??
           ((attemptId) async {
             final saved = await FlutterForegroundTask.saveData(
               key: _kStartupAttemptIdKey,
               value: attemptId,
             );
             if (!saved) {
               throw StateError(
                 'failed to persist foreground startup attempt ID',
               );
             }
           }),
       _startupCompletion = ForegroundStartupCompletion(
         timeout: startupTimeout,
       ),
       _shutdownCompletion = ForegroundShutdownCompletion(
         timeout: shutdownTimeout,
         stopService:
             stopService ??
             (() async {
               await FlutterForegroundTask.stopService();
             }),
       );

  final NativeEngineLifecycle _nativeLifecycle;
  final AsyncVoidCallback _stopService;
  final PortLookup _portLookup;
  final StartupAttemptIdWriter _startupAttemptIdWriter;
  final ForegroundStartupCompletion _startupCompletion;
  final ForegroundShutdownCompletion _shutdownCompletion;
  StreamController<String> _processMessageStream = StreamController();
  SendPort? _serverSendPort;
  SendPort? _backdoorSendPort;
  SendPort? _shutdownSendPort;
  int _nextAttemptId = 0;
  // Completed by the explicit task-isolate startup result. start() and a
  // racing stop() join this bounded attempt; every terminal path resets it.

  @override
  Future<void> start({required EngineOptionsExternal options}) async {
    _processMessageStream.close();
    _processMessageStream = StreamController();
    final attemptId = ++_nextAttemptId;
    final startup = _startupCompletion.begin(attemptId);
    try {
      await _startupAttemptIdWriter(attemptId);
      await _startForegroundTask();
      await startup.future;
    } catch (error) {
      _startupCompletion.complete(
        ForegroundStartupResult.error(attemptId, error.toString()),
      );
      await _reconcileFailedStartup();
      rethrow;
    }
  }

  Future<void> _reconcileFailedStartup() async {
    final errors = <String>[];
    try {
      await _stopService();
    } catch (error) {
      errors.add('service stop: $error');
    }
    try {
      if (await _nativeLifecycle.runtimeStarted()) {
        await _nativeLifecycle.stop();
      }
    } catch (error) {
      errors.add('native stop: $error');
    }
    if (errors.isNotEmpty) {
      throw ForegroundStartupException(
        'startup reconciliation failed: ${errors.join('; ')}',
      );
    }
  }

  @override
  Future<bool> runtimeStarted() => _nativeLifecycle.runtimeStarted();

  @override
  Future<void> stop() async {
    logInfo(
      "ForegroundProvider.stop() called: _shutdownSendPort=${_shutdownSendPort != null ? 'SET' : 'NULL'}",
    );
    if (_startupCompletion.isInFlight) {
      logWarning(
        "ForegroundProvider.stop(): startup still in flight, awaiting its result",
      );
      final startupId = _startupCompletion.activeAttemptId!;
      await _startupCompletion.begin(startupId).future;
    }
    if (_shutdownCompletion.isInFlight) {
      logInfo(
        "ForegroundProvider.stop(): shutdown already in flight, awaiting existing result",
      );
      final shutdownId = _shutdownCompletion.activeAttemptId!;
      await _shutdownCompletion.begin(shutdownId).future;
      return;
    }
    final attemptId = ++_nextAttemptId;
    final shutdown = _shutdownCompletion.begin(attemptId);
    final shutdownPort = _shutdownSendPort;
    if (shutdownPort == null) {
      _shutdownCompletion.complete(
        ForegroundShutdownResult.error(
          attemptId,
          'foreground shutdown port is unavailable',
        ),
      );
    } else {
      shutdownPort.send(ForegroundShutdownRequest(attemptId).toMessage());
      logInfo(
        "Engine foreground stop request $attemptId sent, awaiting completion",
      );
    }
    await shutdown.future;
    _shutdownSendPort = null;
    _serverSendPort = null;
    _backdoorSendPort = null;
    logInfo("Engine foreground stop $attemptId completed");
  }

  @override
  void send(String msg) {
    _serverSendPort!.send(msg);
  }

  @override
  void sendBackdoorMessage(String msg) {
    _backdoorSendPort!.send(msg);
  }

  Future<ServiceRequestResult> _startForegroundTask() async {
    // Register BEFORE the isRunning check so we can receive the shutdown-complete
    // bool sent by the old FGS over _onReceiveTaskData.
    _registerReceivePort();

    var isRunning = await FlutterForegroundTask.isRunningService;
    logInfo("_startForegroundTask: isRunningService=$isRunning");
    if (isRunning) {
      final oldShutdownPort = IsolateNameServer.lookupPortByName(
        _kMainShutdownPortName,
      );
      if (oldShutdownPort != null) {
        if (_shutdownCompletion.isInFlight) {
          // stop() already sent the shutdown signal to the old FGS — just wait for it.
          // Sending a second signal could target the wrong native generation.
          logInfo(
            "_startForegroundTask: stop() already in flight, awaiting its completion",
          );
          final activeId = _shutdownCompletion.activeAttemptId!;
          await _shutdownCompletion.begin(activeId).future;
          logInfo("_startForegroundTask: in-flight stop completed");
        } else {
          // Truly stale FGS from a previous app session — no stop() in flight.
          // Use the graceful shutdown protocol: the handler awaits native
          // teardown and multicast cleanup, returns an explicit result, then
          // the main isolate stops the service before completing waiters.
          logInfo(
            "_startForegroundTask: found stale FGS shutdown port, requesting graceful stop",
          );
          final attemptId = ++_nextAttemptId;
          final staleShutdown = _shutdownCompletion.begin(attemptId);
          oldShutdownPort.send(
            ForegroundShutdownRequest(attemptId).toMessage(),
          );
          await staleShutdown.future;
          logInfo("_startForegroundTask: stale FGS stopped gracefully");
        }
      } else {
        // Edge case: service is running but its ports are gone (e.g. crashed).
        // Force-stop the service, then stop the Rust runtime directly if still up.
        logWarning(
          "_startForegroundTask: stale FGS has no shutdown port, forcing stop",
        );
        await FlutterForegroundTask.stopService();
        if (Platform.isAndroid) {
          await MdnsPlatformService.instance.releaseMdnsMulticastLock();
        }
        if (await _nativeLifecycle.runtimeStarted()) {
          await _nativeLifecycle.stop();
        }
        logInfo("_startForegroundTask: forced stop complete");
      }
    }
    logInfo("_startForegroundTask: calling startService()");
    var reqResult = await FlutterForegroundTask.startService(
      notificationTitle: 'Intiface Engine is running',
      notificationText: 'Tap to return to the app',
      notificationButtons: [
        const NotificationButton(id: 'stopServerButton', text: 'Stop Server'),
      ],
      callback: startCallback,
    );

    return reqResult;
  }

  void _onReceiveTaskData(Object message) {
    if (message is String) {
      _processMessageStream.add(message);
      return;
    }

    final startupResult = ForegroundStartupResult.fromMessage(message);
    if (startupResult != null) {
      _completeStartup(startupResult);
      return;
    }
    final shutdownResult = ForegroundShutdownResult.fromMessage(message);
    if (shutdownResult != null) {
      _completeShutdown(shutdownResult);
    }
  }

  void _completeStartup(ForegroundStartupResult result) {
    if (_startupCompletion.activeAttemptId != result.attemptId) {
      logWarning(
        "Ignoring stale startup result for attempt ${result.attemptId}",
      );
      return;
    }
    if (!result.isSuccess) {
      _startupCompletion.complete(result);
      return;
    }
    _serverSendPort = _portLookup(_kMainServerPortName);
    _backdoorSendPort = _portLookup(_kMainBackdoorPortName);
    _shutdownSendPort = _portLookup(_kMainShutdownPortName);
    if (_serverSendPort == null ||
        _backdoorSendPort == null ||
        _shutdownSendPort == null) {
      _startupCompletion.complete(
        ForegroundStartupResult.error(
          result.attemptId,
          'foreground task started without all communication ports',
        ),
      );
      return;
    }
    _startupCompletion.complete(result);
  }

  Future<void> _completeShutdown(ForegroundShutdownResult result) async {
    final matched = await _shutdownCompletion.complete(result);
    if (!matched) {
      logWarning(
        "Ignoring stale shutdown result for attempt ${result.attemptId}",
      );
      return;
    }
    if (result.isSuccess) {
      logInfo(
        "Shutdown ${result.attemptId} completed; foreground task stopped.",
      );
    } else {
      logError(
        "Native foreground shutdown ${result.attemptId} failed: ${result.error}",
      );
    }
  }

  // Narrow headless-test seam for lifecycle protocol coordination.
  ForegroundAttempt beginStartupForTest() =>
      _startupCompletion.begin(++_nextAttemptId);
  Future<void> reconcileFailedStartupForTest() => _reconcileFailedStartup();
  void receiveTaskDataForTest(Object message) => _onReceiveTaskData(message);
  void installPortsForTest({
    required SendPort server,
    required SendPort backdoor,
    required SendPort shutdown,
  }) {
    _serverSendPort = server;
    _backdoorSendPort = backdoor;
    _shutdownSendPort = shutdown;
  }

  void _registerReceivePort() {
    // Remove the task if it already exists, just to make sure to clear things out.
    FlutterForegroundTask.removeTaskDataCallback(_onReceiveTaskData);
    FlutterForegroundTask.addTaskDataCallback(_onReceiveTaskData);
  }

  @override
  Stream<String> get engineRawMessageStream => _processMessageStream.stream;
}
