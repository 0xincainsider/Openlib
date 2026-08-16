// Dart imports:
import 'dart:async';

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:flutter_riverpod/flutter_riverpod.dart';

// Project imports:
import 'package:openlib/services/annas_archieve.dart';
import 'package:openlib/services/annas_fetcher.dart';
import 'package:openlib/state/state.dart'
    show captchaCooldownUntilProvider, captchaCooldownRemaining;
import 'package:openlib/ui/captcha_page.dart';

/// Shown when Anna's Archive responds with its DDoS-Guard/hCaptcha challenge
/// (see [CaptchaRequiredException]). Lets the user solve the captcha once in
/// the in-app WebView and then retries the failed request.
///
/// [url] es la URL que falló con el reto (la búsqueda o el detalle), NO la
/// home: el reto debe resolverse y validarse en esa misma URL. Abrir la home
/// casi nunca mostraba el captcha (la home no suele estar bloqueada) y el
/// reintento volvía a fallar en la URL de búsqueda: el bucle infinito
/// "Verification required".
///
/// Enforces a shared cooldown between retries: DDoS-Guard rate-limits rapid
/// requests, so hammering the "Solve Captcha" button ends in a "too many
/// requests" block. After solving, the session is re-established on the
/// bridge WebView before the retry, so a stale challenge page can never loop
/// back into this screen.
///
/// Tras el solve, [refreshSession] clasifica la sesión en tres estados:
/// [SessionCheck.ok] (reintentar), [SessionCheck.challenge] (el reto no se
/// resolvió; cooldown corto) y [SessionCheck.rateLimited] (bloqueo por
/// demasiadas peticiones; cooldown largo y mensaje de espera, NO el
/// engañoso "la sesión no se confirmó").
class CaptchaErrorWidget extends ConsumerStatefulWidget {
  const CaptchaErrorWidget(
      {super.key, required this.url, required this.onRetry});

  /// URL que falló con el reto DDoS-Guard.
  final String url;

  final VoidCallback onRetry;

  @override
  ConsumerState<CaptchaErrorWidget> createState() => _CaptchaErrorWidgetState();
}

class _CaptchaErrorWidgetState extends ConsumerState<CaptchaErrorWidget> {
  /// Tiempo mínimo entre reintentos tras un reto no resuelto (evita el rate
  /// limit de DDoS-Guard).
  static const Duration _cooldown = Duration(seconds: 20);

  /// Tiempo de espera cuando la URL está bloqueada por demasiadas peticiones:
  /// reintentar antes solo empeora el bloqueo.
  static const Duration _rateLimitCooldown = Duration(seconds: 60);

  Timer? _ticker;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _startTickerIfNeeded();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _startTickerIfNeeded() {
    _ticker?.cancel();
    if (captchaCooldownRemaining(ref.read(captchaCooldownUntilProvider)) ==
        Duration.zero) {
      return;
    }
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (captchaCooldownRemaining(ref.read(captchaCooldownUntilProvider)) ==
          Duration.zero) {
        _ticker?.cancel();
      }
    });
  }

  Future<void> _solveAndContinue() async {
    if (_busy) return;
    if (captchaCooldownRemaining(ref.read(captchaCooldownUntilProvider)) !=
        Duration.zero) {
      return;
    }

    // El reto se resuelve en la URL que falló, no en la home: así el captcha
    // aparece siempre que la petición está bloqueada.
    final String solveUrl = AnnasArchieve.captchaSolveUrl(widget.url);

    final solved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (BuildContext context) => CaptchaPage(url: solveUrl),
      ),
    );
    if (solved != true || !mounted) return;

    setState(() => _busy = true);

    // Re-establece la sesión en la WebView puente con las cookies del solve,
    // validando la MISMA URL que se reintentará. Sin esto, el reintento
    // arranca desde el reto obsoleto y vuelve a fallar.
    final SessionCheck sessionCheck =
        await AnnasFetcher.instance.refreshSession(url: solveUrl);

    if (!mounted) return;
    setState(() => _busy = false);

    // Cooldown compartido entre reintentos: corto si el reto persiste, largo
    // si la URL está rate-limitada (reintentar antes solo empeora el bloqueo).
    final Duration cooldown = switch (sessionCheck) {
      SessionCheck.rateLimited => _rateLimitCooldown,
      _ => _cooldown,
    };
    ref.read(captchaCooldownUntilProvider.notifier).state =
        DateTime.now().add(cooldown);
    _startTickerIfNeeded();

    if (sessionCheck == SessionCheck.ok) {
      widget.onRetry();
      return;
    }

    final String message = sessionCheck == SessionCheck.rateLimited
        ? "Demasiadas peticiones a Anna's Archive. Espera unos minutos antes de volver a intentarlo."
        : 'El captcha no se resolvió todavía. Espera unos segundos y vuelve a intentarlo.';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Duration remaining =
        captchaCooldownRemaining(ref.watch(captchaCooldownUntilProvider));
    final bool locked = remaining > Duration.zero || _busy;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.verified_user_outlined,
              size: 80,
              color: Theme.of(context).colorScheme.tertiary,
            ),
            const SizedBox(height: 16),
            Text(
              "Verification required",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.secondary,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              "Anna's Archive asks to confirm you are not a robot. "
              "Solve the captcha once and the app will continue on its own.",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.tertiary.withAlpha(170),
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.secondary,
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                ),
              ),
              onPressed: locked ? null : _solveAndContinue,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 21, vertical: 9),
                child: Text(
                  _busy
                      ? 'Comprobando sesión...'
                      : locked
                          ? 'Espera ${remaining.inSeconds}s para reintentar'
                          : 'Solve Captcha',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
