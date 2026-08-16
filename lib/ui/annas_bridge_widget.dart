// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

// Project imports:
import 'package:openlib/services/annas_archieve.dart';
import 'package:openlib/services/annas_fetcher.dart';

/// Invisible persistent WebView that keeps an Anna's Archive session alive
/// (DDoS-Guard cookies + real browser TLS stack) and serves HTML fetches to
/// [AnnasFetcher]. Rendered offscreen (1x1, fully transparent) so it never
/// interferes with the UI. Place it inside a Stack in the root screen.
class AnnasBridge extends StatefulWidget {
  const AnnasBridge({super.key});

  @override
  State<AnnasBridge> createState() => _AnnasBridgeState();
}

class _AnnasBridgeState extends State<AnnasBridge> {
  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      // Kept technically visible (no Opacity 0) so the Android WebView is not
      // throttled; it is placed offscreen in the parent Stack.
      child: SizedBox(
        width: 1,
        height: 1,
        child: InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri(AnnasArchieve.baseUrl)),
          // Sin caché: cada fetch revalida las cookies con el servidor. Sin esto,
          // tras resolver el captcha el WebView puede servir la página de reto
          // cacheada y el bucle "Verification required" nunca se rompe.
          initialSettings: InAppWebViewSettings(
            cacheMode: CacheMode.LOAD_NO_CACHE,
          ),
          onWebViewCreated: (controller) {
            AnnasFetcher.instance.attach(controller);
          },
          onLoadStop: (controller, url) {
            AnnasFetcher.instance.handleLoadStop(controller, url);
          },
        ),
      ),
    );
  }
}
