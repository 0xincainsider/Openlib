// Flutter imports:
import 'package:flutter/material.dart';

// Project imports:
import 'package:openlib/services/annas_archieve.dart';
import 'package:openlib/ui/captcha_page.dart';

/// Shown when Anna's Archive responds with its DDoS-Guard/hCaptcha challenge
/// (see [CaptchaRequiredException]). Lets the user solve the captcha once in
/// the in-app WebView and then retries the failed request.
class CaptchaErrorWidget extends StatelessWidget {
  const CaptchaErrorWidget({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
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
              onPressed: () async {
                final solved = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (BuildContext context) =>
                        const CaptchaPage(url: AnnasArchieve.baseUrl),
                  ),
                );
                if (solved == true) {
                  onRetry();
                }
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 21, vertical: 9),
                child: Text('Solve Captcha'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
