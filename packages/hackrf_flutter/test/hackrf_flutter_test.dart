import 'package:flutter_test/flutter_test.dart';
import 'package:hackrf_flutter/hackrf_flutter.dart';
import 'package:hackrf_flutter/hackrf_flutter_platform_interface.dart';
import 'package:hackrf_flutter/hackrf_flutter_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockHackrfFlutterPlatform
    with MockPlatformInterfaceMixin
    implements HackrfFlutterPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final HackrfFlutterPlatform initialPlatform = HackrfFlutterPlatform.instance;

  test('$MethodChannelHackrfFlutter is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelHackrfFlutter>());
  });

  test('getPlatformVersion', () async {
    HackrfFlutter hackrfFlutterPlugin = HackrfFlutter();
    MockHackrfFlutterPlatform fakePlatform = MockHackrfFlutterPlatform();
    HackrfFlutterPlatform.instance = fakePlatform;

    expect(await hackrfFlutterPlugin.getPlatformVersion(), '42');
  });
}
