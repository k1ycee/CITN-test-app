import "package:flutter_test/flutter_test.dart";
import "package:test_app/views/dashboard/quiz_dashboard_page.dart";

void main() {
  test("shows the prompt when a new pending id appears", () {
    expect(shouldShowAnswerKeyPrompt(null, 5), isTrue);
    expect(shouldShowAnswerKeyPrompt(5, 7), isTrue);
  });

  test("does not show the prompt when there is nothing pending or it is unchanged", () {
    expect(shouldShowAnswerKeyPrompt(null, null), isFalse);
    expect(shouldShowAnswerKeyPrompt(5, 5), isFalse);
  });
}
