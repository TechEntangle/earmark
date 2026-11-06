// Recordings kept safely on the phone until the Mac has them.
//
// Frames are appended to the current chunk file as they arrive (flushed every few seconds),
// so an app crash or a dead phone battery loses at most a few seconds. A chunk closes after
// [chunkSeconds] of audio, or when frames stop arriving in real time (pause, disconnect).
// Closed chunks are uploaded oldest first and deleted only after the Mac confirms them.
//
// File name: <seq>_<startEpochMicros>.chunk  (seq increases forever per install)
// Contents : repeated [u16 BE length][Opus frame]  (the Mac's upload format, see
//            mac/earmark/appsync.py), so a chunk is uploaded byte for byte.
import 'dart:io';
import 'dart:typed_data';

const frameMicros = 20000;

class Chunk {
  final File file;
  final int seq;
  final int startMicros;
  Chunk(this.file, this.seq, this.startMicros);
  double get startSeconds => startMicros / 1e6;
  int get bytes => file.existsSync() ? file.lengthSync() : 0;
}

class ChunkStore {
  final Directory dir;
  final int chunkSeconds;
  final int Function() nowMicros;
  int _nextSeq = 1;
  RandomAccessFile? _sink;
  File? _file;
  int _frames = 0;
  int _startMicros = 0;
  int _lastFrameMicros = 0;

  /// Uploaded chunks are kept here for playing back (for [keepDays]), not deleted.
  final int keepDays;
  Directory get keptDir => Directory('${dir.path}/kept');

  ChunkStore(this.dir, {this.chunkSeconds = 30, int Function()? nowMicros, this.keepDays = 30})
      : nowMicros = nowMicros ?? (() => DateTime.now().microsecondsSinceEpoch) {
    dir.createSync(recursive: true);
    keptDir.createSync(recursive: true);
    final cutoff = (this.nowMicros() - keepDays * 86400 * 1000000);
    for (final f in keptDir.listSync().whereType<File>()) {
      final start = int.tryParse(f.uri.pathSegments.last.split('_').last.split('.').first);
      if (start != null && start < cutoff) f.deleteSync();
    }
    final saved = int.tryParse(_seqFile.existsSync() ? _seqFile.readAsStringSync().trim() : '');
    if (saved != null) _nextSeq = saved;
    for (final c in _list(includeOpen: true)) {
      if (c.seq >= _nextSeq) _nextSeq = c.seq + 1;
    }
    // a chunk that was open when the app stopped is complete as far as it goes
    for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.open'))) {
      final done = f.path.substring(0, f.path.length - 5);
      if (f.lengthSync() > 0) {
        f.renameSync(done);
      } else {
        f.deleteSync();
      }
    }
  }

  File get _seqFile => File('${dir.path}/next_seq');

  /// The Mac remembers the last chunk it accepted from this phone; never reuse a number at or
  /// below it (for example after reinstalling the app), or new audio would look like a repeat.
  void ensureSeqAbove(int lastAccepted) {
    if (_nextSeq <= lastAccepted) {
      _nextSeq = lastAccepted + 1;
      _seqFile.writeAsStringSync('$_nextSeq');
    }
  }

  /// Seconds of audio in the chunk being written now.
  double get openSeconds => _frames * frameMicros / 1e6;

  /// Add one frame. A gap of more than a second since the last frame starts a new chunk,
  /// so every chunk is continuous audio with a correct start time.
  void add(Uint8List frame) {
    final now = nowMicros();
    if (_sink != null && now - _lastFrameMicros > 1000000) close();
    if (_sink == null) {
      _startMicros = now - frameMicros;
      final f = File('${dir.path}/${_nextSeq}_$_startMicros.chunk.open');
      _nextSeq++;
      _seqFile.writeAsStringSync('$_nextSeq');
      _file = f;
      _sink = f.openSync(mode: FileMode.writeOnlyAppend);
      _frames = 0;
    }
    // one small write per frame (50 a second): each frame is in the file as soon as it arrives
    final rec = Uint8List(2 + frame.length);
    ByteData.sublistView(rec).setUint16(0, frame.length, Endian.big);
    rec.setRange(2, rec.length, frame);
    _sink!.writeFromSync(rec);
    _frames++;
    _lastFrameMicros = now;
    if (_frames * frameMicros >= chunkSeconds * 1000000) close();
  }

  /// Finish the current chunk so it can be uploaded.
  void close() {
    final s = _sink, f = _file;
    _sink = null;
    _file = null;
    _frames = 0;
    if (s == null || f == null) return;
    s.flushSync();
    s.closeSync();
    if (f.existsSync() && f.lengthSync() > 0) {
      f.renameSync(f.path.substring(0, f.path.length - 5));
    } else if (f.existsSync()) {
      f.deleteSync();
    }
  }

  /// Closed chunks waiting for the Mac, oldest first.
  List<Chunk> pending() => _list(includeOpen: false);

  double pendingSeconds() {
    var b = 0;
    for (final c in pending()) {
      b += c.bytes;
    }
    return b / 70 * 0.02; // ~70 bytes per 20 ms frame incl. header
  }

  /// The Mac has it: keep it on the phone for playing back (until [keepDays]).
  void markUploaded(Chunk c) {
    if (!c.file.existsSync()) return;
    if (keepDays <= 0) {
      c.file.deleteSync();
    } else {
      c.file.renameSync('${keptDir.path}/${c.file.uri.pathSegments.last}');
    }
  }

  /// A chunk's audio, sent or not (null when it is gone).
  File? fileFor(int seq, int startMicros) {
    for (final d in [dir, keptDir]) {
      final f = File('${d.path}/${seq}_$startMicros.chunk');
      if (f.existsSync()) return f;
    }
    return null;
  }

  List<Chunk> _list({required bool includeOpen}) {
    final out = <Chunk>[];
    for (final f in dir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      final open = name.endsWith('.chunk.open');
      if (!name.endsWith('.chunk') && !(includeOpen && open)) continue;
      final base = name.split('.').first;
      final parts = base.split('_');
      if (parts.length != 2) continue;
      final seq = int.tryParse(parts[0]), start = int.tryParse(parts[1]);
      if (seq == null || start == null) continue;
      out.add(Chunk(f, seq, start));
    }
    out.sort((a, b) => a.seq.compareTo(b.seq));
    return out;
  }
}
