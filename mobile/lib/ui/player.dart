// Playing back a conversation from the audio kept on this phone.
import 'dart:async';
import 'dart:io';

import 'package:earmark_asr/earmark_asr.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../app_controller.dart';
import '../notes/conversations.dart';
import 'theme.dart';

/// Wraps the native player (swappable in tests).
class AudioBackend {
  bool get supported => EarmarkAudio.supported;
  Future<double> prepare(List<String> paths, List<double> offsets, String out) => EarmarkAudio.prepare(paths, offsets, out);
  Future<PlayerState> play(String path, {double? at}) => EarmarkAudio.play(path, at: at);
  Future<PlayerState> pause() => EarmarkAudio.pause();
  Future<PlayerState> stop() => EarmarkAudio.stop();
  Future<PlayerState> seek(double at) => EarmarkAudio.seek(at);
  Future<PlayerState> state() => EarmarkAudio.state();
  Future<PlayerState> speed(double x) => EarmarkAudio.speed(x);
}

class ConvPlayer extends ChangeNotifier {
  final EarmarkController c;
  final Conversation v;
  final AudioBackend audio;
  ConvPlayer(this.c, this.v, {AudioBackend? audio}) : audio = audio ?? AudioBackend();

  String? _path;
  bool preparing = false;
  bool playing = false;
  double position = 0, duration = 0;
  /// playback speed (pitch kept)
  double speed = 1;
  static const speeds = [1.0, 1.25, 1.5, 2.0];

  /// The next speed, round the list.
  Future<void> cycleSpeed() async {
    speed = speeds[(speeds.indexOf(speed) + 1) % speeds.length];
    notifyListeners();
    try {
      _apply(await audio.speed(speed));
    } catch (_) {}
  }
  String? error;
  Timer? _poll;

  /// The conversation's audio files and where each starts (seconds from its start).
  (List<String>, List<double>) files() => c.audioFor(v);

  bool get available => audio.supported && files().$1.isNotEmpty;

  /// The conversation's audio as one WAV file (for sharing).
  Future<String?> file() => _prepare();

  Future<String?> _prepare() async {
    if (_path != null) return _path;
    final (paths, offsets) = files();
    if (paths.isEmpty) {
      error = 'The audio is no longer on this phone.';
      notifyListeners();
      return null;
    }
    preparing = true;
    notifyListeners();
    try {
      Directory dir;
      try {
        dir = await getTemporaryDirectory();
      } catch (_) {
        dir = Directory.systemTemp; // tests
      }
      final out = '${dir.path}/conversation_${v.id}_${paths.length}_v2.wav';
      if (!File(out).existsSync()) {
        duration = await audio.prepare(paths, offsets, out);
      }
      _path = out;
      return out;
    } catch (e) {
      error = "Couldn't play this recording: $e";
      return null;
    } finally {
      preparing = false;
      notifyListeners();
    }
  }

  Future<void> toggle() => playing ? pause() : playFrom(null);

  Future<void> playFrom(double? at) async {
    final p = await _prepare();
    if (p == null) return;
    _apply(await audio.play(p, at: at));
    _poll ??= Timer.periodic(const Duration(milliseconds: 250), (_) async {
      _apply(await audio.state());
      if (!playing) {
        _poll?.cancel();
        _poll = null;
      }
    });
  }

  Future<void> pause() async => _apply(await audio.pause());

  Future<void> seek(double at) async {
    if (_path == null) return playFrom(at);
    _apply(await audio.seek(at));
  }

  void _apply(PlayerState s) {
    playing = s.playing;
    position = s.position;
    if (s.duration > 0) duration = s.duration;
    notifyListeners();
  }

  @override
  void dispose() {
    _poll?.cancel();
    if (_path != null) unawaited(audio.stop());
    super.dispose();
  }
}

String _mmss(double s) {
  final t = s.round();
  return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}';
}

class PlayerBar extends StatelessWidget {
  final ConvPlayer p;
  const PlayerBar({super.key, required this.p});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: p,
        builder: (context, _) {
          final t = context.t;
          final dur = p.duration > 0 ? p.duration : p.v.seconds;
          return Container(
            key: const Key('playerBar'),
            padding: const EdgeInsets.fromLTRB(6, 4, 14, 4),
            decoration: BoxDecoration(color: t.surface, border: Border.all(color: t.line), borderRadius: BorderRadius.circular(16)),
            child: Row(children: [
              SizedBox(
                width: 48, height: 48,
                child: p.preparing
                    ? const Padding(padding: EdgeInsets.all(14), child: CircularProgressIndicator(strokeWidth: 2))
                    : IconButton(
                        key: const Key('playBtn'),
                        tooltip: p.playing ? 'Pause' : 'Play',
                        onPressed: p.toggle,
                        icon: Icon(p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 30, color: t.ink),
                      ),
              ),
              Expanded(
                child: p.error != null
                    ? Text(p.error!, style: TextStyle(fontSize: 13, color: t.due))
                    : SliderTheme(
                        data: SliderTheme.of(context).copyWith(trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
                        child: Slider(
                          value: p.position.clamp(0, dur).toDouble(),
                          max: dur <= 0 ? 1 : dur,
                          onChanged: (x) => p.seek(x),
                        ),
                      ),
              ),
              Text('${_mmss(p.position)} / ${_mmss(dur)}',
                  style: TextStyle(fontSize: 12.5, color: t.ink2, fontFeatures: const [FontFeature.tabularFigures()])),
              TextButton(
                key: const Key('speedBtn'),
                style: TextButton.styleFrom(minimumSize: const Size(44, 36), padding: const EdgeInsets.symmetric(horizontal: 6)),
                onPressed: p.cycleSpeed,
                child: Text('${p.speed == p.speed.roundToDouble() ? p.speed.round() : p.speed}×',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: t.ink2)),
              ),
            ]),
          );
        },
      );
}
