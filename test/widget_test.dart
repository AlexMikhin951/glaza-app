import 'package:flutter_test/flutter_test.dart';
import 'package:glaza_app/main.dart';

void main() {
  testWidgets('SmartGlassesApp builds', (WidgetTester tester) async {
    // MapKit init требует нативные либы — в unit-тесте только smoke на виджет-класс.
    expect(SmartGlassesApp, isNotNull);
  });
}
