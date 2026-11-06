// How the pendant behaves: its light, microphone level, what the button does and whether it
// vibrates. The same settings as on the Mac (they are kept in step), and they work without it.

class PendantPrefs {
  /// 0-100; 0 turns the light off. While paused it is always off.
  final int led;
  /// 0-8, or -1 to leave the pendant's own setting alone.
  final int micGain;
  final bool singleTapEarmark;
  final bool doubleTapPause;
  final bool haptics;

  const PendantPrefs({
    this.led = 100,
    this.micGain = -1,
    this.singleTapEarmark = true,
    this.doubleTapPause = true,
    this.haptics = true,
  });

  PendantPrefs copyWith({int? led, int? micGain, bool? singleTapEarmark, bool? doubleTapPause, bool? haptics}) =>
      PendantPrefs(
        led: (led ?? this.led).clamp(0, 100),
        micGain: (micGain ?? this.micGain).clamp(-1, 8),
        singleTapEarmark: singleTapEarmark ?? this.singleTapEarmark,
        doubleTapPause: doubleTapPause ?? this.doubleTapPause,
        haptics: haptics ?? this.haptics,
      );

  /// In the Mac's own names (config.json).
  Map<String, Object> toJson() => {
        'led_brightness': led,
        'mic_gain': micGain,
        'single_tap_earmark': singleTapEarmark,
        'double_tap_pause': doubleTapPause,
        'haptics': haptics,
      };

  static PendantPrefs fromJson(Map m, [PendantPrefs base = const PendantPrefs()]) {
    int? i(Object? v) => v is num ? v.toInt() : null;
    bool? b(Object? v) => v is bool ? v : null;
    return base.copyWith(
      led: i(m['led_brightness']),
      micGain: i(m['mic_gain']),
      singleTapEarmark: b(m['single_tap_earmark']),
      doubleTapPause: b(m['double_tap_pause']),
      haptics: b(m['haptics']),
    );
  }

  @override
  bool operator ==(Object other) => other is PendantPrefs && '${other.toJson()}' == '${toJson()}';
  @override
  int get hashCode => '${toJson()}'.hashCode;
}
