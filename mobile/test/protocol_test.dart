import 'dart:async';
import 'dart:typed_data';

import 'package:earmark/pendant/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FrameAssembler', () {
    test('one frame per notification', () {
      final out = <Uint8List>[];
      final a = FrameAssembler(out.add);
      a.add([1, 0, 0, 10, 11, 12]);
      a.add([2, 0, 0, 20, 21]);
      a.flush();
      expect(out.map((f) => f.toList()), [
        [10, 11, 12],
        [20, 21]
      ]);
    });

    test('a frame split over several notifications is rebuilt', () {
      final out = <Uint8List>[];
      final a = FrameAssembler(out.add);
      a.add([1, 0, 0, 1, 2]);
      a.add([1, 0, 1, 3, 4]);
      a.add([1, 0, 2, 5]);
      a.add([2, 0, 0, 9]);
      a.flush();
      expect(out.map((f) => f.toList()), [
        [1, 2, 3, 4, 5],
        [9]
      ]);
    });

    test('ignores empty packets', () {
      final out = <Uint8List>[];
      final a = FrameAssembler(out.add)..add([1, 0, 0]);
      a.flush();
      expect(out, isEmpty);
    });
  });

  test('button events decode (int32 little endian)', () {
    expect(decodeButton([1, 0, 0, 0]), ButtonEvent.tap);
    expect(decodeButton([2, 0, 0, 0]), ButtonEvent.doubleTap);
    expect(decodeButton([3, 0, 0, 0]), ButtonEvent.longPress);
    expect(decodeButton([9, 0, 0, 0]), ButtonEvent.unknown);
    expect(decodeButton([1]), ButtonEvent.unknown);
  });

  test('clock bytes are u32 little endian epoch seconds', () {
    final b = clockBytes(DateTime.fromMillisecondsSinceEpoch(0x01020304 * 1000));
    expect(b, [4, 3, 2, 1]);
  });

  group('TapInterpreter', () {
    late DateTime now;
    late List<String> got;
    late Map<int, void Function()> timers;
    var nextId = 0;
    late TapInterpreter t;
    setUp(() {
      now = DateTime(2026, 11, 6, 9);
      got = [];
      timers = {};
      t = TapInterpreter(
        onSingle: (at) => got.add('single@${at.second}'),
        onDouble: () => got.add('double'),
        schedule: (d, f) {
          final id = nextId++;
          timers[id] = f;
          return id;
        },
        cancel: (id) => timers.remove(id),
        now: () => now,
      );
    });
    void fire() {
      final f = List.of(timers.values);
      timers.clear();
      for (final x in f) {
        x();
      }
    }

    test('a single tap is an earmark, after the pairing window', () {
      t.handle(ButtonEvent.tap);
      expect(got, isEmpty);
      fire();
      expect(got, ['single@0']);
    });

    test('two relaxed taps within a second are a double tap', () {
      t.handle(ButtonEvent.tap);
      now = now.add(const Duration(milliseconds: 600));
      t.handle(ButtonEvent.tap);
      fire();
      expect(got, ['double']);
    });

    test('two taps far apart are two earmarks', () {
      t.handle(ButtonEvent.tap);
      fire();
      now = now.add(const Duration(seconds: 3));
      t.handle(ButtonEvent.tap);
      fire();
      expect(got, ['single@0', 'single@3']);
    });

    test('the firmware double tap acts at once and cancels a pending tap', () {
      t.handle(ButtonEvent.tap);
      t.handle(ButtonEvent.doubleTap);
      fire();
      expect(got, ['double']);
    });

    test('down/up/long press do nothing', () {
      for (final e in [ButtonEvent.down, ButtonEvent.up, ButtonEvent.longPress]) {
        t.handle(e);
      }
      fire();
      expect(got, isEmpty);
    });
  });

  test('vibration patterns', () {
    expect(Buzz.recording.length, 3);
    expect(Buzz.paused.single.$1, 3);
    expect(Buzz.earmark.single.$1, 2);
    expect(Buzz.durationMs(3), 500);
  });

  // keep the analyzer happy about unused async import in some SDKs
  unawaited(Future.value());
}
