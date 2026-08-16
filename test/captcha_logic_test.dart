// Package imports:
import 'package:flutter_test/flutter_test.dart';

// Project imports:
import 'package:openlib/services/annas_archieve.dart';
import 'package:openlib/services/annas_fetcher.dart';
import 'package:openlib/state/state.dart';

void main() {
  group('isRateLimitedPage', () {
    test('detecta página de bloqueo por demasiadas peticiones', () {
      expect(
        AnnasArchieve.isRateLimitedPage(
            '<html><body>Too many requests. Please try again later.</body></html>'),
        isTrue,
      );
      expect(
        AnnasArchieve.isRateLimitedPage(
            '<html>DDoS-Guard: rate limit exceeded</html>'),
        isTrue,
      );
      expect(
        AnnasArchieve.isRateLimitedPage('<html>HTTP 429</html>'),
        isTrue,
      );
      expect(
        AnnasArchieve.isRateLimitedPage(
            '<html><head><title>429 Too Many Requests</title></head><body>blocked</body></html>'),
        isTrue,
      );
    });

    test('la página de reto DDoS-Guard NO es rate limit', () {
      // La página de reto real es corta, con título "DDoS-Guard" y sin
      // palabras de rate limit: debe caer en el flujo de captcha, no de
      // bloqueo (comprobado contra el sitio: HTTP 403, <title>DDoS-Guard</title>).
      expect(
        AnnasArchieve.isRateLimitedPage(
            '<html><head><title>DDoS-Guard</title></head><body>Please wait while your request is being verified...</body></html>'),
        isFalse,
      );
    });

    test('no confunde una página normal con rate limit', () {
      expect(
        AnnasArchieve.isRateLimitedPage(
            '<html><title>Anna\'s Archive Search</title>libros</html>'),
        isFalse,
      );
    });

    test('no da falso positivo con contenido normal que menciona las keywords', () {
      // La página real del sitio lleva "Anna" en el título: aunque su
      // contenido contenga palabras de bloqueo (títulos de libros, números
      // 429 en descripciones...), nunca es una página de rate limit.
      expect(
        AnnasArchieve.isRateLimitedPage(
            '<html><head><title>Anna\'s Archive Search</title></head>'
            '<body><h2>Access Denied</h2> (libro) <p>blocked by the author</p> '
            'ISBN 4291... archivo de 429 KB</body></html>'),
        isFalse,
      );
      expect(
        AnnasArchieve.isRateLimitedPage(
            '<html><title>Results for blocked - Anna\'s Archive</title></html>'),
        isFalse,
      );
    });
  });

  group('isDdosGuardChallenge', () {
    test('detecta el reto DDoS-Guard', () {
      expect(
        AnnasArchieve.isDdosGuardChallenge(
            '<html>DDoS-Guard challenge, please wait</html>'),
        isTrue,
      );
    });
  });

  group('captchaCooldownRemaining', () {
    test('sin cooldown activo devuelve cero', () {
      expect(captchaCooldownRemaining(null), Duration.zero);
      expect(
        captchaCooldownRemaining(DateTime.now().subtract(const Duration(seconds: 5))),
        Duration.zero,
      );
    });

    test('con cooldown futuro devuelve el tiempo restante', () {
      final remaining = captchaCooldownRemaining(
          DateTime.now().add(const Duration(seconds: 20)));
      expect(remaining, greaterThan(Duration.zero));
      expect(remaining.inSeconds, inInclusiveRange(19, 20));
    });
  });

  group('captchaSolveUrl', () {
    test('usa la URL que falló con el reto, no la home', () {
      const failed = 'https://annas-archive.gl/search?q=libro';
      expect(AnnasArchieve.captchaSolveUrl(failed), failed);
    });

    test('cae a la home cuando no hay URL fallida', () {
      expect(AnnasArchieve.captchaSolveUrl(''), AnnasArchieve.baseUrl);
      expect(AnnasArchieve.captchaSolveUrl(null), AnnasArchieve.baseUrl);
    });
  });

  group('isChallengeHtml', () {
    test('reconoce el marcador corto y el HTML completo del reto', () {
      expect(AnnasFetcher.isChallengeHtml('DDoS-Guard'), isTrue);
      expect(
        AnnasFetcher.isChallengeHtml('<html>DDoS-Guard challenge</html>'),
        isTrue,
      );
    });

    test('no confunde una página real con el reto', () {
      expect(
        AnnasFetcher.isChallengeHtml(
            '<html><title>Anna\'s Archive Search</title></html>'),
        isFalse,
      );
    });
  });

  group('isLoadStopChallenge', () {
    test('título DDoS-Guard marca el reto aunque el html parezca normal', () {
      expect(
        isLoadStopChallenge(title: 'DDoS-Guard', html: '<html></html>'),
        isTrue,
      );
    });

    test('título vacío pero html con branding del reto también lo marca', () {
      expect(
        isLoadStopChallenge(
            title: '', html: '<html>DDoS-Guard challenge</html>'),
        isTrue,
      );
    });

    test('una página real no es un reto', () {
      expect(
        isLoadStopChallenge(
            title: 'Anna\'s Archive', html: '<html>resultados</html>'),
        isFalse,
      );
    });
  });

  group('classifySessionHtml', () {
    test('página real -> ok', () {
      expect(
        classifySessionHtml('<html><title>Anna\'s Archive</title></html>'),
        SessionCheck.ok,
      );
    });

    test('reto DDoS-Guard -> challenge', () {
      expect(classifySessionHtml('DDoS-Guard'), SessionCheck.challenge);
      expect(
        classifySessionHtml('<html>DDoS-Guard challenge</html>'),
        SessionCheck.challenge,
      );
    });

    test('página de rate limit -> rateLimited aunque lleve branding DDoS-Guard', () {
      expect(
        classifySessionHtml('<html>DDoS-Guard: too many requests</html>'),
        SessionCheck.rateLimited,
      );
      expect(
        classifySessionHtml('<html>Access denied by rate limit</html>'),
        SessionCheck.rateLimited,
      );
    });
  });
}
