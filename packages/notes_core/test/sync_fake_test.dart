import 'package:test/test.dart';

import 'harness.dart';
import 'scenarios.dart';

void main() {
  group('Synchronisation (serveur simulé)', () {
    defineScenarios(() => FakeBackend());
  });
}
