// How the pendant behaves: its light, microphone level, what each button gesture does and
// whether it vibrates. The same settings as on the Mac (they are kept in step), and they work
// without it.

/// What a button gesture does.
enum ButtonAction {
  earmark('Earmark'),
  pause('Pause'),
  none('Nothing');

  final String label;
  const ButtonAction(this.label);
  static ButtonAction parse(Object? v, ButtonAction fallback) =>
      ButtonAction.values.where((a) => a.name == v).firstOrNull ?? fallback;
}

class PendantPrefs {
  /// 0-100; 0 turns the light off. While paused it is always off.
  final int led;
  /// 0-8, or -1 to leave the pendant's own setting alone.
  final int micGain;
  final ButtonAction tap;
  final ButtonAction doubleTap;
  /// press and hold about a second, then let go (3 s turns the pendant off)
  final ButtonAction hold;
  final bool haptics;

  const PendantPrefs({
    this.led = 100,
    this.micGain = -1,
    this.tap = ButtonAction.earmark,
    this.doubleTap = ButtonAction.pause,
    this.hold = ButtonAction.none,
    this.haptics = true,
  });

  PendantPrefs copyWith({int? led, int? micGain, ButtonAction? tap, ButtonAction? doubleTap, ButtonAction? hold, bool? haptics}) =>
      PendantPrefs(
        led: (led ?? this.led).clamp(0, 100),
        micGain: (micGain ?? this.micGain).clamp(-1, 8),
        tap: tap ?? this.tap,
        doubleTap: doubleTap ?? this.doubleTap,
        hold: hold ?? this.hold,
        haptics: haptics ?? this.haptics,
      );

  /// In the Mac's own names (config.json).
  Map<String, Object> toJson() => {
        'led_brightness': led,
        'mic_gain': micGain,
        'tap_action': tap.name,
        'double_tap_action': doubleTap.name,
        'hold_action': hold.name,
        'haptics': haptics,
      };

  static PendantPrefs fromJson(Map m, [PendantPrefs base = const PendantPrefs()]) {
    int? i(Object? v) => v is num ? v.toInt() : null;
    // an older Mac has on/off switches instead of actions
    final oldTap = m['single_tap_earmark'], oldDouble = m['double_tap_pause'];
    return base.copyWith(
      led: i(m['led_brightness']),
      micGain: i(m['mic_gain']),
      tap: m.containsKey('tap_action')
          ? ButtonAction.parse(m['tap_action'], base.tap)
          : oldTap is bool ? (oldTap ? ButtonAction.earmark : ButtonAction.none) : null,
      doubleTap: m.containsKey('double_tap_action')
          ? ButtonAction.parse(m['double_tap_action'], base.doubleTap)
          : oldDouble is bool ? (oldDouble ? ButtonAction.pause : ButtonAction.none) : null,
      hold: m.containsKey('hold_action') ? ButtonAction.parse(m['hold_action'], base.hold) : null,
      haptics: m['haptics'] is bool ? m['haptics'] as bool : null,
    );
  }

  @override
  bool operator ==(Object other) => other is PendantPrefs && '${other.toJson()}' == '${toJson()}';
  @override
  int get hashCode => '${toJson()}'.hashCode;
}
