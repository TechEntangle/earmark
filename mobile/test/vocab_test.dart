import 'package:earmark/notes/vocab.dart';
import 'package:flutter_test/flutter_test.dart';

const voc = 'RAKBANK\nrack bank, rag bank = RAKBANK\nTushar\nTTX Pro\n# a comment\n';

void main() {
  test('terms and the line for the notes model', () {
    final v = Vocabulary.parse(voc);
    expect(v.terms, ['RAKBANK', 'Tushar', 'TTX Pro']);
    expect(v.promptLine, contains('RAKBANK, Tushar, TTX Pro'));
    expect(Vocabulary.parse('').promptLine, '');
  });

  test('words are corrected and keep their timing (same as the Mac)', () {
    final v = Vocabulary.parse(voc);
    final (t1, w1) = v.fix('I spoke to rack bank today.', [
      [0.0, .3, 'I'], [.3, .6, 'spoke'], [.6, .8, 'to'], [.8, 1.0, 'rack'], [1.0, 1.2, 'bank'], [1.2, 1.5, 'today.'],
    ]);
    expect(t1, 'I spoke to RAKBANK today.');
    expect(w1[3], [.8, 1.2, 'RAKBANK']);
    final (t2, _) = v.fix('', [
      [0, 1, 'rak'], [1, 2, 'bank'], [2, 3, 'and'], [3, 4, 'ttx'], [4, 5, 'pro,'], [5, 6, 'tushar.'],
    ]);
    expect(t2, 'RAKBANK and TTX Pro, Tushar.');
    expect(v.fix('no words list here, rakbank', []).$1, 'no words list here, RAKBANK');
    expect(Vocabulary.parse('Al').fix('a l', [[0, 1, 'a'], [1, 2, 'l']]).$1, 'a l', reason: 'short terms match exactly only');
  });
}
