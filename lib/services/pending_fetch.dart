// Dart imports:
import 'dart:async';

/// Slot único de petición HTML pendiente del WebView puente.
///
/// Garantiza que el slot SIEMPRE se libera — al completar, al fallar o por
/// timeout — de modo que un timeout de red no puede dejar al fetcher
/// bloqueado para siempre. Ese bloqueo era parte del bucle del captcha:
/// tras un timeout, el slot quedaba sin limpiar y todas las peticiones
/// posteriores fallaban con "ya hay una petición en curso".
///
/// Además maneja la gracia de auto-resolución del reto DDoS-Guard: cuando un
/// loadStop muestra el reto ([seeChallenge]), la petición NO se completa en
/// ese instante — el reto JS de DDoS-Guard se auto-resuelve en unos segundos
/// (recarga → nuevo loadStop). Si llega la página real durante la gracia
/// ([completeReal]), se completa con ella; si la gracia expira sin resolución,
/// se invoca [onExpire] para que el llamador complete con el estado actual.
class PendingFetch {
  Completer<String>? _completer;
  Future<String>? _future;
  Timer? _timeout;
  Timer? _graceTimer;

  /// True mientras hay una petición en curso sin completar.
  bool get isActive => _completer?.isCompleted == false;

  /// Registra una petición pendiente. Devuelve `false` (y no registra nada)
  /// si ya hay una petición activa.
  bool begin({required Duration timeout, required String timeoutMessage}) {
    if (isActive) return false;
    final completer = Completer<String>();
    _completer = completer;
    _future = completer.future;
    _timeout = Timer(
        timeout, () => completeError(TimeoutException(timeoutMessage)));
    return true;
  }

  /// El resultado de la petición en curso. Lanza [StateError] si no hay
  /// petición registrada.
  Future<String> get future {
    final future = _future;
    if (future == null) {
      throw StateError('PendingFetch: no hay petición pendiente');
    }
    return future;
  }

  /// Marca el último loadStop como reto DDoS-Guard: inicia una gracia de
  /// [grace] para que el reto JS pueda auto-resolverse. Si ya hay una gracia
  /// activa (reto tras reto), no la reinicia. NO completa la petición: al
  /// expirar la gracia se invoca [onExpire] (solo si la petición sigue
  /// activa) para que el llamador decida con qué HTML completar.
  void seeChallenge({
    required Duration grace,
    required void Function() onExpire,
  }) {
    _graceTimer ??= Timer(grace, () {
      _graceTimer = null;
      if (isActive) onExpire();
    });
  }

  /// Marca el último loadStop como página real: cancela la gracia pendiente
  /// y completa la petición con [html].
  void completeReal(String html) {
    _graceTimer?.cancel();
    _graceTimer = null;
    complete(html);
  }

  /// Completa la petición con el HTML obtenido y libera el slot.
  void complete(String html) => _release((c) => c.complete(html));

  /// Falla la petición con [error] y libera el slot.
  void completeError(Object error) => _release((c) => c.completeError(error));

  void _release(void Function(Completer<String>) finish) {
    _timeout?.cancel();
    _graceTimer?.cancel();
    _graceTimer = null;
    final completer = _completer;
    _completer = null;
    if (completer != null && !completer.isCompleted) {
      finish(completer);
    }
  }
}
