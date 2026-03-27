import "package:flutter_test/flutter_test.dart";

import "package:test_app/main.dart";

void main() {
  testWidgets("renders pdf quiz shell", (WidgetTester tester) async {
    await tester.pumpWidget(const PdfQuizApp());
    expect(find.text("PDF Quiz System"), findsOneWidget);
    expect(find.text("Upload PDF"), findsOneWidget);
  });
}
