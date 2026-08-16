// Dart imports:
import 'dart:async';

// Package imports:
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

// Project imports:
import 'package:openlib/services/html_detection.dart' as detect;
import 'package:openlib/services/pending_fetch.dart';

/// Resultado de comprobar la sesión tras resolver el captcha.
enum SessionCheck {
  /// La URL cargó contenido real: se puede reintentar la petición.
  ok,

  /// La URL sigue mostrando el reto DDoS-Guard/hCaptcha: el captcha no
  /// quedó resuelto o la sesión no se estableció.
  challenge,

  /// La URL devolvió bloqueo por demasiadas peticiones: hay que esperar,
  /// no reintentar en seguida.
  rateLimited,
}

/// Clasifica el HTML devuelto por el puente tras resolver el captcha.
///
/// El bloqueo por rate limit es una página con branding de DDoS-Guard, así
/// que se comprueba ANTES que el reto de verificación (mismo orden que en
/// `AnnasArchieve.searchBooks`).
SessionCheck classifySessionHtml(String html) {
  if (detect.isRateLimitedHtml(html)) return SessionCheck.rateLimited;
  if (detect.isChallengeHtml(html)) return SessionCheck.challenge;
  return SessionCheck.ok;
}

/// True cuando el loadStop del WebView es un reto DDoS-Guard, detectado por
/// el título de la página o por el contenido HTML (el título puede estar
/// vacío durante el reto).
bool isLoadStopChallenge({required Object? title, required String html}) {
  return (title is String && title.contains('DDoS')) ||
      detect.isChallengeHtml(html);
}

/// Fetches HTML from Anna's Archive through the persistent in-app WebView
/// (see `AnnasBridge`). The WebView is *navigated* to the URL and the rendered
/// HTML is extracted afterwards: this is a real browser navigation, so
/// DDoS-Guard accepts it (plain `fetch()` calls from the page are challenged,
/// and a plain HTTP client such as dio fails the TLS fingerprint check).
class AnnasFetcher {
  AnnasFetcher._();

  static final AnnasFetcher instance = AnnasFetcher._();

  /// Ventana de espera para que el reto JS de DDoS-Guard se auto-resuelva
  /// antes de declarar la petición como bloqueada por reto.
  static const Duration _challengeGrace = Duration(seconds: 8);

  InAppWebViewController? _controller;
  final PendingFetch _pending = PendingFetch();

  bool get isReady => _controller != null;

  /// True cuando [html] es la página de reto DDoS-Guard (marcador corto o
  /// HTML completo de la página de verificación).
  static bool isChallengeHtml(String html) => detect.isChallengeHtml(html);

  /// Called by [AnnasBridge] once its WebView is created.
  void attach(InAppWebViewController controller) {
    _controller = controller;
  }

  /// Called by [AnnasBridge] whenever the persistent WebView finishes
  /// loading a page. Completes the pending fetch with the page HTML (or, tras
  /// la gracia, con el HTML del reto si la sesión se perdió).
  Future<void> handleLoadStop(
      InAppWebViewController controller, WebUri? url) async {
    if (!_pending.isActive) return;
    try {
      final title =
          await controller.evaluateJavascript(source: 'document.title');
      if (title is String && title.contains('DDoS')) {
        // Reto DDoS-Guard. NO completamos todavía: el reto JS se auto-resuelve
        // en unos segundos (recarga → nuevo loadStop) y completar en el primer
        // loadStop rompía el flujo — la app veía "reto" aunque segundos
        // después la página real habría cargado.
        _pending.seeChallenge(
            grace: _challengeGrace, onExpire: _completeWithCurrentHtml);
        return;
      }
      final html = await controller
          .evaluateJavascript(source: 'document.documentElement.outerHTML');
      final htmlString = html.toString();
      if (detect.isChallengeHtml(htmlString)) {
        // El título no lo delató (puede estar vacío durante el reto), pero el
        // contenido sí: misma gracia de auto-resolución.
        _pending.seeChallenge(
            grace: _challengeGrace, onExpire: _completeWithCurrentHtml);
        return;
      }
      _pending.completeReal(htmlString);
    } catch (e) {
      _pending.completeError(e);
    }
  }

  /// Completa la petición con el HTML actual de la WebView cuando expira la
  /// gracia del reto. Si el reto se auto-resolvió en el sitio (sin recarga),
  /// el HTML actual ya es la página real; si no, es el HTML del reto/bloqueo
  /// y el llamador lo clasifica.
  Future<void> _completeWithCurrentHtml() async {
    final controller = _controller;
    if (!_pending.isActive || controller == null) return;
    try {
      final html = await controller
          .evaluateJavascript(source: 'document.documentElement.outerHTML');
      _pending.complete(html.toString());
    } catch (e) {
      _pending.completeError(e);
    }
  }

  /// Navigates the persistent WebView to [url] and returns the rendered HTML.
  Future<String> fetchHtml(String url) async {
    final controller = _controller;
    if (controller == null) {
      throw Exception('AnnasFetcher: WebView no disponible');
    }

    if (!_pending.begin(
        timeout: const Duration(seconds: 30),
        timeoutMessage: 'Tiempo de espera agotado al obtener $url')) {
      throw Exception('AnnasFetcher: ya hay una petición en curso');
    }

    try {
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    } catch (e) {
      _pending.completeError(e);
    }

    return _pending.future;
  }

  /// Navega el WebView a [url] y espera a que cargue la página real (no el
  /// reto DDoS-Guard). Se llama después de resolver el captcha con la MISMA
  /// URL que falló.
  ///
  /// Devuelve [SessionCheck.ok] si la URL carga contenido real (el reintento
  /// que sigue puede proceder), [SessionCheck.challenge] si el reto persiste
  /// y [SessionCheck.rateLimited] si la URL está bloqueada por demasiadas
  /// peticiones (hay que esperar, no reintentar en seguida).
  Future<SessionCheck> refreshSession({required String url}) async {
    final controller = _controller;
    if (controller == null) return SessionCheck.challenge;
    if (!_pending.begin(
        timeout: const Duration(seconds: 20),
        timeoutMessage: 'Tiempo de espera agotado al refrescar sesión')) {
      return SessionCheck.challenge;
    }

    try {
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
      final html = await _pending.future;
      return classifySessionHtml(html);
    } catch (_) {
      return SessionCheck.challenge;
    }
  }
}
