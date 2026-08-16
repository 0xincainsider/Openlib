// ====================================================================
// DETECCIÓN DE PÁGINAS ESPECIALES DE ANNA'S ARCHIVE
// ====================================================================
//
// Compartido por `AnnasArchieve` y `AnnasFetcher` para que ambos clasifiquen
// igual. Las páginas de bloqueo por rate limit llevan branding de DDoS-Guard,
// así que `isRateLimitedHtml` debe comprobarse ANTES que `isChallengeHtml`.

/// True cuando [html] es la página de reto DDoS-Guard: tanto el marcador
/// corto ('DDoS-Guard') como el HTML completo de la página de verificación.
bool isChallengeHtml(String html) => html.contains('DDoS-Guard');

/// Texto del `<title>` de la página, en minúsculas ('' si no existe).
String _titleOf(String lowerHtml) {
  const open = '<title>';
  final start = lowerHtml.indexOf(open);
  if (start < 0) return '';
  final end = lowerHtml.indexOf('</title>', start);
  if (end < 0) return '';
  return lowerHtml.substring(start + open.length, end);
}

/// True cuando [html] es una página de bloqueo por demasiadas peticiones
/// (rate limit).
///
/// Reglas para evitar falsos positivos (el motivo por el que la app bloqueaba
/// búsquedas normales con "Demasiadas peticiones"):
///
/// 1. Si el `<title>` identifica la página real del sitio (siempre lleva
///    "Anna"), NUNCA es una página de bloqueo, aunque su contenido mencione
///    "blocked", "429" o "Access Denied" (títulos de libros, descripciones,
///    tamaños de archivo...).
/// 2. Las palabras de bloqueo solo se buscan en el título + los primeros
///    bytes del documento: las páginas de bloqueo de DDoS-Guard son cortas y
///    ponen el mensaje arriba. Escanear el HTML completo producía falsos
///    positivos con contenido normal.
bool isRateLimitedHtml(String html) {
  final lower = html.toLowerCase();
  final title = _titleOf(lower);

  // Página real del sitio (búsquedas, detalles): nunca es rate limit.
  if (title.contains('anna')) return false;

  // Página de bloqueo: mensaje en el título o al inicio del documento.
  final head = lower.length > 5000 ? lower.substring(0, 5000) : lower;
  return head.contains('too many requests') ||
      head.contains('rate limit') ||
      head.contains('429') ||
      head.contains('access denied') ||
      head.contains('blocked');
}
