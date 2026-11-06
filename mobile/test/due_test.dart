import 'dart:io';

import 'package:earmark/app_controller.dart';
import 'package:earmark/notes/conversations.dart';
import 'package:earmark/notes/due.dart';
import 'package:earmark/pendant/pendant_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'notes_test.dart' show MemConfig;

class RemindersEngine extends LocalAsr {
  final synced = <List<Map<String, Object?>>>[];
  List<String> completed = [];
  @override
  bool get supported => true;
  @override
  Future<bool> remindersAccess() async => true;
  @override
  Future<List<String>> remindersSync(List<Map<String, Object?>> items) async {
    synced.add(items);
    return completed;
  }
}

void main() {
  // Monday 9 Nov 2026, 10:00
  final mon = DateTime(2026, 11, 9, 10);

  test('deadlines as said become dates', () {
    String? p(String s) => parseDue(s, mon)?.toString();
    expect(p('by Thursday'), Due(DateTime(2026, 11, 12, 9)).toString());
    expect(p('next Thursday'), Due(DateTime(2026, 11, 19, 9)).toString());
    expect(p('tomorrow at 5'), Due(DateTime(2026, 11, 10, 17), timed: true).toString());
    expect(p('day after tomorrow'), Due(DateTime(2026, 11, 11, 9)).toString());
    expect(p('by end of day'), Due(DateTime(2026, 11, 9, 9)).toString());
    expect(p('end of the week'), Due(DateTime(2026, 11, 13, 9)).toString());
    expect(p('next week'), Due(DateTime(2026, 11, 16, 9)).toString());
    expect(p('end of the month'), Due(DateTime(2026, 11, 30, 9)).toString());
    expect(p('in two weeks'), Due(DateTime(2026, 11, 23, 9)).toString());
    expect(p('December 31st'), Due(DateTime(2026, 12, 31, 9)).toString());
    expect(p('15th of March'), Due(DateTime(2027, 3, 15, 9)).toString(), reason: 'already past this year: next year');
    expect(p('at 3:30 pm'), Due(DateTime(2026, 11, 9, 15, 30), timed: true).toString());
    expect(p('by 9am'), Due(DateTime(2026, 11, 10, 9), timed: true).toString(), reason: '9 am has passed: tomorrow');
    expect(p('soon'), isNull);
    expect(p('when possible'), isNull);
  });

  test('my tasks go to Reminders with dates; ticked off there, ticked off here', () async {
    final dir = Directory.systemTemp.createTempSync('rem');
    final engine = RemindersEngine();
    final c = EarmarkController(config: MemConfig(), pendant: PendantService(), asr: engine)
      ..convs = Conversations(File('${dir.path}/c.json'));
    final start = mon.millisecondsSinceEpoch / 1000;
    final v = Conversation(1, start, start + 60, [1], status: 'ready', title: 'Vendor call', tasks: [
      ConvTask(id: '1-0', text: 'Call the bank', owner: 'me', due: 'tomorrow at 5', at: start),
      ConvTask(id: '1-1', text: 'Send the contract', owner: 'Sam', due: 'by Thursday', at: start),
    ]);
    c.convs!.all.add(v);
    c.remindersOn = true;
    await c.syncReminders(force: true);
    final items = engine.synced.single;
    expect(items.map((i) => i['id']), ['1-0'], reason: "only mine; Sam's stays in Earmark");
    expect(items.single['due'], DateTime(2026, 11, 10, 17).millisecondsSinceEpoch / 1000);
    expect(items.single['timed'], isTrue);
    expect('${items.single['notes']}', contains('Vendor call'));
    engine.completed = ['1-0'];
    await c.syncReminders(force: true);
    expect(v.tasks.first.done, isTrue);
    c.dispose();
  });
}
