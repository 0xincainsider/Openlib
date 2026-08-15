// Dart imports:
import 'dart:async';

// Package imports:
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Fetches HTML from Anna's Archive through the persistent in-app WebView
/// (see `AnnasBridge`). The WebView is *navigated* to the URL and the rendered
/// HTML is extracted afterwards: this is a real browser navigation, so
/// DDoS-Guard accepts it (plain `fetch()` calls from the page are challenged,
/// and a plain HTTP client such as dio fails the TLS fingerprint check).
class AnnasFetcher {
  AnnasFetcher._();

  static final AnnasFetcher instance = AnnasFetcher._();

  InAppWebViewController? _controller;
  Completer<String>? _pending;
  Timer? _timeout;

  bool get isReady => _controller != null;

  /// Called by [AnnasBridge] once its WebView is created.
  void attach(InAppWebViewController controller) {
    _controller = controller;
  }

  /// Called by [AnnasBridge] whenever the persistent WebView finishes
  /// loading a page. Completes the pending fetch with the page HTML (or with
  /// the DDoS-Guard challenge marker if the session was lost).
  Future<void> handleLoadStop(
      InAppWebViewController controller, WebUri? url) async {
    if (_pending == null) return;
    try {
      final title =
          await controller.evaluateJavascript(source: 'document.title');
      if (title is String && title.contains('DDoS')) {
        _complete('DDoS-Guard');
        return;
      }
      final html = await controller
          .evaluateJavascript(source: 'document.documentElement.outerHTML');
      _complete(html.toString());
    } catch (e) {
      _completeError(e);
    }
  }

  /// Navigates the persistent WebView to [url] and returns the rendered HTML.
  Future<String> fetchHtml(String url) async {
    final controller = _controller;
    if (controller == null) {
      throw Exception('AnnasFetcher: WebView no disponible');
    }

    if (_pending != null) {
      throw Exception('AnnasFetcher: ya hay una petición en curso');
    }

    final completer = Completer<String>();
    _pending = completer;
    _timeout?.cancel();
    _timeout = Timer(const Duration(seconds: 30), () {
      if (!completer.isCompleted) {
        completer.completeError(
            TimeoutException('Tiempo de espera agotado al obtener $url'));
      }
    });

    await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));

    return completer.future;
  }

  void _complete(String html) {
    _timeout?.cancel();
    final completer = _pending;
    _pending = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(html);
    }
  }

  void _completeError(Object error) {
    _timeout?.cancel();
    final completer = _pending;
    _pending = null;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error);
    }
  }
}
