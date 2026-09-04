import "dart:typed_data";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:hooks_riverpod/hooks_riverpod.dart";

import "package:test_app/core/providers.dart";
import "package:test_app/main.dart";

class _EmptyListAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      "[]",
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  testWidgets("renders pdf quiz shell", (WidgetTester tester) async {
    final dio = Dio()..httpClientAdapter = _EmptyListAdapter();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [dioProvider.overrideWithValue(dio)],
        child: const PdfQuizApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text("PDF Quiz System"), findsOneWidget);
    expect(find.text("Upload PDF"), findsOneWidget);
  });
}
