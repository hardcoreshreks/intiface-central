import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:intiface_central/bloc/engine/foreground_task_library_engine_provider.dart';
import 'package:intiface_central/bloc/engine/library_engine_provider.dart';

class FakeNativeLifecycle implements NativeEngineLifecycle {
  FakeNativeLifecycle({Future<void> Function()? stop, this.started = true})
    : _stop = stop ?? (() async {});

  final Future<void> Function() _stop;
  bool started;
  int stopCalls = 0;

  @override
  Future<bool> runtimeStarted() async => started;

  @override
  Future<void> stop() {
    stopCalls++;
    return _stop();
  }
}

void main() {
  test('library_provider_stop_awaits_native_completion', () async {
    final nativeStop = Completer<void>();
    final provider = LibraryEngineProvider(
      nativeLifecycle: FakeNativeLifecycle(stop: () => nativeStop.future),
    );

    var completed = false;
    final stop = provider.stop().then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    nativeStop.complete();
    await stop;
    expect(completed, isTrue);
  });

  test('library_provider_stop_error_is_propagated', () async {
    final provider = LibraryEngineProvider(
      nativeLifecycle: FakeNativeLifecycle(
        stop: () => Future<void>.error(StateError('native stop failed')),
      ),
    );

    await expectLater(provider.stop(), throwsA(isA<StateError>()));
  });

  test('foreground_provider_does_not_ack_before_native_stop', () async {
    final nativeStop = Completer<void>();
    final sent = <ForegroundShutdownResult>[];
    final handler = ForegroundShutdownHandler(
      nativeLifecycle: FakeNativeLifecycle(stop: () => nativeStop.future),
      cleanup: () async {},
      sendResult: sent.add,
    );

    final shutdown = handler.shutdown(1);
    await Future<void>.delayed(Duration.zero);
    expect(sent, isEmpty);

    nativeStop.complete();
    await shutdown;
    expect(sent, hasLength(1));
    expect(sent.single.isSuccess, isTrue);
  });

  test(
    'foreground_provider_stop_error_fails_waiters_without_success_ack',
    () async {
      final sent = <ForegroundShutdownResult>[];
      final handler = ForegroundShutdownHandler(
        nativeLifecycle: FakeNativeLifecycle(
          stop: () => Future<void>.error(StateError('cleanup timeout')),
        ),
        cleanup: () async {},
        sendResult: sent.add,
      );

      await handler.shutdown(1);
      expect(sent, hasLength(1));
      expect(sent.single.isSuccess, isFalse);

      final completion = ForegroundShutdownCompletion(stopService: () async {});
      final waiterExpectation = expectLater(
        completion.begin(1).future,
        throwsA(isA<ForegroundShutdownException>()),
      );
      await completion.complete(sent.single);
      await waiterExpectation;
    },
  );

  test('foreground_provider_cleanup_error_sends_error_result', () async {
    final sent = <ForegroundShutdownResult>[];
    final handler = ForegroundShutdownHandler(
      nativeLifecycle: FakeNativeLifecycle(),
      cleanup: () => Future<void>.error(StateError('multicast cleanup failed')),
      sendResult: sent.add,
    );

    await handler.shutdown(1);
    expect(sent.single.isSuccess, isFalse);
    expect(sent.single.error, contains('multicast cleanup failed'));
  });

  test('foreground_provider_completes_only_after_service_stop', () async {
    final serviceStop = Completer<void>();
    final completion = ForegroundShutdownCompletion(
      stopService: () => serviceStop.future,
    );
    var completed = false;
    final waiter = completion.begin(1).future.then((_) => completed = true);

    final resultDelivery = completion.complete(
      const ForegroundShutdownResult.success(1),
    );
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    serviceStop.complete();
    await resultDelivery;
    await waiter;
    expect(completed, isTrue);
  });

  test('foreground_provider_service_stop_error_fails_waiter', () async {
    final completion = ForegroundShutdownCompletion(
      stopService: () => Future<void>.error(StateError('service stop failed')),
    );
    final waiterExpectation = expectLater(
      completion.begin(1).future,
      throwsA(isA<ForegroundShutdownException>()),
    );

    await completion.complete(const ForegroundShutdownResult.success(1));
    await waiterExpectation;
  });

  test('handler send-result failure permits retry', () async {
    var sends = 0;
    final lifecycle = FakeNativeLifecycle();
    final handler = ForegroundShutdownHandler(
      nativeLifecycle: lifecycle,
      cleanup: () async {},
      sendResult: (_) {
        sends++;
        if (sends == 1) throw StateError('transport failed');
      },
    );

    await expectLater(
      handler.shutdown(1),
      throwsA(isA<ForegroundShutdownException>()),
    );
    await handler.shutdown(1);
    expect(sends, 2);
    expect(lifecycle.stopCalls, 1);
  });

  test('queued request retries after prior send failure', () async {
    final cleanupGate = Completer<void>();
    final sentIds = <int>[];
    final lifecycle = FakeNativeLifecycle();
    var cleanupCalls = 0;
    final handler = ForegroundShutdownHandler(
      nativeLifecycle: lifecycle,
      cleanup: () async {
        cleanupCalls++;
        await cleanupGate.future;
      },
      sendResult: (result) async {
        sentIds.add(result.attemptId);
        if (result.attemptId == 20) {
          throw StateError('A transport failed');
        }
      },
    );

    final first = handler.shutdown(20);
    final second = handler.shutdown(21);
    cleanupGate.complete();

    await expectLater(first, throwsA(isA<ForegroundShutdownException>()));
    await second;
    expect(sentIds, [20, 21]);
    expect(lifecycle.stopCalls, 1);
    expect(cleanupCalls, 1);
  });

  test('handler serializes and retags concurrent request attempts', () async {
    final firstSend = Completer<void>();
    final sentIds = <int>[];
    final lifecycle = FakeNativeLifecycle();
    final handler = ForegroundShutdownHandler(
      nativeLifecycle: lifecycle,
      cleanup: () async {},
      sendResult: (result) async {
        sentIds.add(result.attemptId);
        if (result.attemptId == 10) await firstSend.future;
      },
    );

    final first = handler.shutdown(10);
    final second = handler.shutdown(11);
    await Future<void>.delayed(Duration.zero);
    expect(sentIds, [10]);
    firstSend.complete();
    await Future.wait([first, second]);
    expect(sentIds, [10, 11]);
    expect(lifecycle.stopCalls, 1);
  });

  test('lost shutdown result times out, resets, and permits retry', () async {
    final completion = ForegroundShutdownCompletion(
      stopService: () async {},
      timeout: const Duration(milliseconds: 10),
    );

    await expectLater(
      completion.begin(1).future,
      throwsA(isA<ForegroundShutdownException>()),
    );
    expect(completion.isInFlight, isFalse);

    final retry = completion.begin(2);
    await completion.complete(const ForegroundShutdownResult.success(2));
    await retry.future;
  });

  test('startup error resolves racing stop and resets attempt', () async {
    final provider = ForegroundTaskLibraryEngineProvider(
      startupTimeout: const Duration(milliseconds: 50),
    );
    final startupExpectation = expectLater(
      provider.beginStartupForTest().future,
      throwsA(isA<ForegroundStartupException>()),
    );
    final stopExpectation = expectLater(
      provider.stop(),
      throwsA(isA<ForegroundStartupException>()),
    );
    provider.receiveTaskDataForTest(
      const ForegroundStartupResult.error(
        1,
        'task isolate init failed',
      ).toMessage(),
    );

    await Future.wait([startupExpectation, stopExpectation]);
    final retry = provider.beginStartupForTest();
    provider.receiveTaskDataForTest(
      const ForegroundStartupResult.error(2, 'retry failed').toMessage(),
    );
    await expectLater(retry.future, throwsA(isA<ForegroundStartupException>()));
  });

  test('lost startup result times out and resets attempt', () async {
    final completion = ForegroundStartupCompletion(
      timeout: const Duration(milliseconds: 10),
    );

    await expectLater(
      completion.begin(1).future,
      throwsA(isA<ForegroundStartupException>()),
    );
    expect(completion.isInFlight, isFalse);

    final retry = completion.begin(2);
    completion.complete(const ForegroundStartupResult.error(2, 'retry failed'));
    await expectLater(retry.future, throwsA(isA<ForegroundStartupException>()));
  });

  test('stop timeout retry sends twice and late A cannot complete B', () async {
    final shutdownPort = ReceivePort();
    final unusedPort = ReceivePort();
    addTearDown(shutdownPort.close);
    addTearDown(unusedPort.close);
    final requests = <ForegroundShutdownRequest>[];
    final subscription = shutdownPort.listen((message) {
      final request = ForegroundShutdownRequest.fromMessage(message);
      if (request != null) requests.add(request);
    });
    addTearDown(subscription.cancel);
    final provider = ForegroundTaskLibraryEngineProvider(
      shutdownTimeout: const Duration(milliseconds: 15),
      stopService: () async {},
    );
    provider.installPortsForTest(
      server: unusedPort.sendPort,
      backdoor: unusedPort.sendPort,
      shutdown: shutdownPort.sendPort,
    );

    await expectLater(
      provider.stop(),
      throwsA(isA<ForegroundShutdownException>()),
    );
    expect(requests, hasLength(1));
    final attemptA = requests.single.attemptId;

    var retryCompleted = false;
    final retry = provider.stop().then((_) => retryCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(requests, hasLength(2));
    final attemptB = requests.last.attemptId;
    expect(attemptB, greaterThan(attemptA));

    provider.receiveTaskDataForTest(
      ForegroundShutdownResult.success(attemptA).toMessage(),
    );
    await Future<void>.delayed(Duration.zero);
    expect(retryCompleted, isFalse);

    provider.receiveTaskDataForTest(
      ForegroundShutdownResult.success(attemptB).toMessage(),
    );
    await retry;
    expect(retryCompleted, isTrue);
  });

  test('startup late A result cannot complete B', () async {
    var serviceStops = 0;
    final lifecycle = FakeNativeLifecycle();
    final provider = ForegroundTaskLibraryEngineProvider(
      nativeLifecycle: lifecycle,
      startupTimeout: const Duration(milliseconds: 10),
      stopService: () async => serviceStops++,
    );

    final attemptA = provider.beginStartupForTest();
    await expectLater(
      attemptA.future,
      throwsA(isA<ForegroundStartupException>()),
    );
    await provider.reconcileFailedStartupForTest();
    expect(serviceStops, 1);
    expect(lifecycle.stopCalls, 1);

    final attemptB = provider.beginStartupForTest();
    expect(attemptB.id, greaterThan(attemptA.id));
    provider.receiveTaskDataForTest(
      ForegroundStartupResult.error(attemptA.id, 'late A').toMessage(),
    );
    var bCompleted = false;
    final bExpectation = expectLater(
      attemptB.future.whenComplete(() => bCompleted = true),
      throwsA(isA<ForegroundStartupException>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(bCompleted, isFalse);

    provider.receiveTaskDataForTest(
      ForegroundStartupResult.error(attemptB.id, 'matching B').toMessage(),
    );
    await bExpectation;
  });

  test(
    'duplicate stop service-stop exception reaches both waiters and one request',
    () async {
      final shutdownPort = ReceivePort();
      final unusedPort = ReceivePort();
      addTearDown(shutdownPort.close);
      addTearDown(unusedPort.close);
      final requests = <ForegroundShutdownRequest>[];
      final subscription = shutdownPort.listen((message) {
        final request = ForegroundShutdownRequest.fromMessage(message);
        if (request != null) requests.add(request);
      });
      addTearDown(subscription.cancel);
      final provider = ForegroundTaskLibraryEngineProvider(
        stopService: () =>
            Future<void>.error(StateError('service stop failed')),
      );
      provider.installPortsForTest(
        server: unusedPort.sendPort,
        backdoor: unusedPort.sendPort,
        shutdown: shutdownPort.sendPort,
      );

      final firstExpectation = expectLater(
        provider.stop(),
        throwsA(isA<ForegroundShutdownException>()),
      );
      final secondExpectation = expectLater(
        provider.stop(),
        throwsA(isA<ForegroundShutdownException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(requests, hasLength(1));
      provider.receiveTaskDataForTest(
        ForegroundShutdownResult.success(requests.single.attemptId).toMessage(),
      );
      await Future.wait([firstExpectation, secondExpectation]);
      expect(requests, hasLength(1));
    },
  );

  test('duplicate_foreground_stop_joins_same_result', () async {
    final shutdownPort = ReceivePort();
    final unusedPort = ReceivePort();
    addTearDown(shutdownPort.close);
    addTearDown(unusedPort.close);
    var sends = 0;
    final subscription = shutdownPort.listen((_) => sends++);
    addTearDown(subscription.cancel);
    var serviceStopCalls = 0;
    final provider = ForegroundTaskLibraryEngineProvider(
      stopService: () async => serviceStopCalls++,
    );
    provider.installPortsForTest(
      server: unusedPort.sendPort,
      backdoor: unusedPort.sendPort,
      shutdown: shutdownPort.sendPort,
    );

    var firstCompleted = false;
    var secondCompleted = false;
    final first = provider.stop().then((_) => firstCompleted = true);
    final second = provider.stop().then((_) => secondCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(sends, 1);
    expect(firstCompleted, isFalse);
    expect(secondCompleted, isFalse);

    provider.receiveTaskDataForTest(
      const ForegroundShutdownResult.success(1).toMessage(),
    );
    await Future.wait([first, second]);
    expect(sends, 1);
    expect(serviceStopCalls, 1);
  });
}
