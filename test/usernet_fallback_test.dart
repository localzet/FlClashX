import 'package:flclashx/services/usernet_fallback.dart';
import 'package:flclashx/services/usernet_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('auto requires repeated failures before using fabric', () {
    final controller = UserNetFallbackController(
      mode: UserNetTransportMode.auto,
      policy: const UserNetFallbackPolicy(
        failuresBeforeFabric: 3,
        switchCooldown: Duration.zero,
      ),
    );

    expect(controller.recordDirectProbe(succeeded: false), UserNetPath.direct);
    expect(controller.recordDirectProbe(succeeded: false), UserNetPath.direct);
    expect(controller.recordDirectProbe(succeeded: false), UserNetPath.fabric);
  });

  test('fabric returns to direct only after stable recovery and cooldown', () {
    final start = DateTime.utc(2026);
    final controller = UserNetFallbackController(
      mode: UserNetTransportMode.auto,
      policy: const UserNetFallbackPolicy(
        failuresBeforeFabric: 1,
        successesBeforeDirect: 2,
        switchCooldown: Duration(seconds: 30),
      ),
    );

    expect(
      controller.recordDirectProbe(succeeded: false, now: start),
      UserNetPath.fabric,
    );
    expect(
      controller.recordDirectProbe(
        succeeded: true,
        now: start.add(const Duration(seconds: 10)),
      ),
      UserNetPath.fabric,
    );
    expect(
      controller.recordDirectProbe(
        succeeded: true,
        now: start.add(const Duration(seconds: 20)),
      ),
      UserNetPath.fabric,
    );
    expect(
      controller.recordDirectProbe(
        succeeded: true,
        now: start.add(const Duration(seconds: 31)),
      ),
      UserNetPath.direct,
    );
  });

  test('forced mode ignores probe results', () {
    final direct = UserNetFallbackController(
      mode: UserNetTransportMode.direct,
    );
    final fabric = UserNetFallbackController(
      mode: UserNetTransportMode.fabric,
    );

    expect(direct.recordDirectProbe(succeeded: false), UserNetPath.direct);
    expect(fabric.recordDirectProbe(succeeded: true), UserNetPath.fabric);
  });
}
