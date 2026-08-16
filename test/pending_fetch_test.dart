// Dart imports:
import 'dart:async';

// Package imports:
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

// Project imports:
import 'package:openlib/services/pending_fetch.dart';

void main() {
  group('PendingFetch', () {
    test('completa y libera el slot', () async {
      final pf = PendingFetch();
      expect(
        pf.begin(timeout: const Duration(seconds: 5), timeoutMessage: 'x'),
        isTrue,
      );
      final future = pf.future;
      pf.complete('html');
      await expectLater(future, completion('html'));
      expect(pf.isActive, isFalse);
    });

    test('un timeout libera el slot y permite una petición nueva', () async {
      final pf = PendingFetch();
      expect(
        pf.begin(
          timeout: const Duration(milliseconds: 20),
          timeoutMessage: 'timeout',
        ),
        isTrue,
      );
      await expectLater(pf.future, throwsA(isA<TimeoutException>()));
      expect(pf.isActive, isFalse);
      // Si el timeout no liberara el slot, esto devolvería false y el flujo
      // de captcha quedaría bloqueado para siempre ("ya hay una petición en
      // curso" en todos los reintentos posteriores).
      expect(
        pf.begin(timeout: const Duration(seconds: 5), timeoutMessage: 'y'),
        isTrue,
      );
    });

    test('rechaza una segunda petición mientras hay una activa', () async {
      final pf = PendingFetch();
      expect(
        pf.begin(timeout: const Duration(seconds: 5), timeoutMessage: 'a'),
        isTrue,
      );
      expect(
        pf.begin(timeout: const Duration(seconds: 5), timeoutMessage: 'b'),
        isFalse,
      );
      pf.complete('x');
      await expectLater(pf.future, completion('x'));
    });

    test('completeError libera el slot', () async {
      final pf = PendingFetch();
      pf.begin(timeout: const Duration(seconds: 5), timeoutMessage: 'e');
      final future = pf.future;
      pf.completeError(Exception('boom'));
      await expectLater(future, throwsA(isA<Exception>()));
      expect(pf.isActive, isFalse);
    });
  });

  group('PendingFetch challenge grace', () {
    test('tras ver un reto, una página real completa con su html', () async {
      final pf = PendingFetch();
      pf.begin(timeout: const Duration(seconds: 30), timeoutMessage: 't');
      final future = pf.future;
      var expired = false;

      pf.seeChallenge(
        grace: const Duration(seconds: 8),
        onExpire: () => expired = true,
      );
      expect(pf.isActive, isTrue);

      // El reto JS de DDoS-Guard se auto-resuelve: llega la página real.
      pf.completeReal('<html>resultados reales</html>');

      await expectLater(future, completion('<html>resultados reales</html>'));
      expect(expired, isFalse);
      expect(pf.isActive, isFalse);
    });

    test('si el reto persiste, la gracia expira sin completar antes', () {
      fakeAsync((async) {
        final pf = PendingFetch();
        pf.begin(timeout: const Duration(seconds: 30), timeoutMessage: 't');
        var expired = false;

        pf.seeChallenge(
          grace: const Duration(seconds: 8),
          onExpire: () => expired = true,
        );
        async.elapse(const Duration(seconds: 9));

        expect(expired, isTrue);
        // Sigue pendiente: quien expira decide con qué HTML completar.
        expect(pf.isActive, isTrue);

        pf.complete('<html>reto no resuelto</html>');
        async.flushMicrotasks();
        expect(pf.isActive, isFalse);
      });
    });

    test('completeReal cancela la gracia pendiente', () {
      fakeAsync((async) {
        final pf = PendingFetch();
        pf.begin(timeout: const Duration(seconds: 30), timeoutMessage: 't');
        var expired = false;

        pf.seeChallenge(
          grace: const Duration(seconds: 8),
          onExpire: () => expired = true,
        );
        pf.completeReal('<html>real</html>');
        async.elapse(const Duration(seconds: 9));

        expect(expired, isFalse);
      });
    });

    test('ver varios retos seguidos no reinicia la gracia', () {
      fakeAsync((async) {
        final pf = PendingFetch();
        pf.begin(timeout: const Duration(seconds: 30), timeoutMessage: 't');
        var expires = 0;

        pf.seeChallenge(
          grace: const Duration(seconds: 8),
          onExpire: () => expires++,
        );
        async.elapse(const Duration(seconds: 4));
        pf.seeChallenge(
          grace: const Duration(seconds: 8),
          onExpire: () => expires++,
        );
        async.elapse(const Duration(seconds: 5)); // 4+5=9 > 8 desde la primera

        expect(expires, 1);
      });
    });
  });
}
