// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Opens Anna's Archive in a visible in-app WebView so the user can solve the
/// DDoS-Guard/hCaptcha challenge once. Android WebViews share the same cookie
/// store, so the session established here is automatically reused by the
/// persistent bridge WebView (`AnnasBridge`) that serves the app's requests.
/// Pops with `true` once the real site has loaded.
class CaptchaPage extends StatefulWidget {
  const CaptchaPage({super.key, required this.url});

  final String url;

  @override
  State<CaptchaPage> createState() => _CaptchaPageState();
}

class _CaptchaPageState extends State<CaptchaPage> {
  bool _exiting = false;

  Future<void> _exit() async {
    if (_exiting) return;
    _exiting = true;
    if (mounted) {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _onLoadStop(
      InAppWebViewController controller, WebUri? url) async {
    // Detect when the challenge has been solved: the DDoS-Guard page title is
    // "DDoS-Guard"; the real site loads with "Anna's Archive" as the title.
    try {
      final title =
          await controller.evaluateJavascript(source: 'document.title');
      if (title is String &&
          title.contains('Anna') &&
          !title.contains('DDoS')) {
        await _exit();
      }
    } catch (_) {
      // The fallback button below always allows the user to continue.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: const Text("Solve Captcha"),
        titleTextStyle: Theme.of(context).textTheme.displayLarge,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text(
                "Resuelve el captcha para confirmar que no eres un robot. "
                "Cuando la página cargue, la app continuará automáticamente.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.tertiary,
                ),
              ),
            ),
            Expanded(
              child: InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(widget.url)),
                onLoadStop: _onLoadStop,
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.secondary,
                    textStyle: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                    ),
                  ),
                  onPressed: _exit,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 9),
                    child: Text('Ya resolví el captcha, continuar'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
