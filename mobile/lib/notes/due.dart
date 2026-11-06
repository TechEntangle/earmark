// Deadlines as they were said ("by Thursday", "tomorrow at 5", "end of the month") → a date.
// Only clear phrases are turned into dates; anything vague stays text only.

class Due {
  final DateTime at;
  /// a time of day was said (then the reminder gets an alert at that time)
  final bool timed;
  const Due(this.at, {this.timed = false});
  @override
  String toString() => 'Due($at, timed: $timed)';
}

const _days = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];
const _months = ['january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december'];

/// [said] relative to [now] (when the conversation happened).
Due? parseDue(String said, DateTime now) {
  final s = said.toLowerCase().replaceAll(RegExp(r'[,.]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.isEmpty) return null;
  final today = DateTime(now.year, now.month, now.day);
  DateTime? day;

  if (RegExp(r'\b(today|tonight|this evening|this afternoon|end of (the )?day|eod)\b').hasMatch(s)) {
    day = today;
  } else if (RegExp(r'\bday after tomorrow\b').hasMatch(s)) {
    day = today.add(const Duration(days: 2));
  } else if (RegExp(r'\b(tomorrow|tmrw)\b').hasMatch(s)) {
    day = today.add(const Duration(days: 1));
  } else if (RegExp(r'\b(end of (the |this )?week|this week|eow)\b').hasMatch(s)) {
    day = _next(today, DateTime.friday, allowToday: true);
  } else if (RegExp(r'\bnext week\b').hasMatch(s)) {
    day = _next(today, DateTime.monday); // the coming Monday
  } else if (RegExp(r'\b(end of (the |this )?month|eom)\b').hasMatch(s)) {
    day = DateTime(today.year, today.month + 1, 0);
  } else {
    final m = RegExp(r'\bin (\d+|a|one|two|three|four|five) (day|days|week|weeks)\b').firstMatch(s);
    if (m != null) {
      final n = int.tryParse(m[1]!) ?? const {'a': 1, 'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5}[m[1]!]!;
      day = today.add(Duration(days: m[2]!.startsWith('week') ? 7 * n : n));
    }
  }
  if (day == null) {
    for (var i = 0; i < 7; i++) {
      final m = RegExp('\\b(next )?${_days[i]}\\b').firstMatch(s);
      if (m != null) {
        day = _next(today, i + 1);
        if (m[1] != null && day.difference(today).inDays < 7 && day.weekday > today.weekday) {
          day = day.add(const Duration(days: 7)); // "next Thursday" said on a Monday: the one after
        }
        break;
      }
    }
  }
  if (day == null) {
    // "15 December", "December 15", "15th Dec", "31/12"
    for (var i = 0; i < 12; i++) {
      final mon = _months[i], short = mon.substring(0, 3);
      final m = RegExp('\\b(\\d{1,2})(?:st|nd|rd|th)? (?:of )?(?:$mon|$short)\\b|\\b(?:$mon|$short) (\\d{1,2})(?:st|nd|rd|th)?\\b').firstMatch(s);
      if (m != null) {
        final d = int.parse(m[1] ?? m[2]!);
        var y = today.year;
        if (DateTime(y, i + 1, d).isBefore(today)) y++;
        day = DateTime(y, i + 1, d);
        break;
      }
    }
    final m = RegExp(r'\b(\d{1,2})/(\d{1,2})\b').firstMatch(s);
    if (day == null && m != null) {
      final d = int.parse(m[1]!), mo = int.parse(m[2]!);
      if (mo >= 1 && mo <= 12 && d >= 1 && d <= 31) {
        var y = today.year;
        if (DateTime(y, mo, d).isBefore(today)) y++;
        day = DateTime(y, mo, d);
      }
    }
  }

  // a time of day: "at 5", "5 pm", "17:30", "by 3:15pm", "noon"
  int? hour, minute;
  final tm = RegExp(r'\b(?:at |by |before )?(\d{1,2})(?::(\d{2}))? ?(am|pm)\b|\b(?:at |by |before )(\d{1,2})(?::(\d{2}))?\b|\b(\d{1,2}):(\d{2})\b').firstMatch(s);
  if (RegExp(r'\bnoon\b|\bmidday\b').hasMatch(s)) {
    hour = 12;
    minute = 0;
  } else if (tm != null) {
    if (tm[1] != null) {
      hour = int.parse(tm[1]!) % 12 + (tm[3] == 'pm' ? 12 : 0);
      minute = int.tryParse(tm[2] ?? '') ?? 0;
    } else if (tm[4] != null) {
      hour = int.parse(tm[4]!);
      minute = int.tryParse(tm[5] ?? '') ?? 0;
      if (hour >= 1 && hour <= 7) hour += 12; // "at 5" means the afternoon
    } else {
      hour = int.parse(tm[6]!);
      minute = int.parse(tm[7]!);
    }
    if (hour > 23 || minute > 59) hour = minute = null;
  }
  if (day == null && hour == null) return null;
  if (day == null) {
    day = today;
    if (DateTime(today.year, today.month, today.day, hour!, minute!).isBefore(now)) {
      day = today.add(const Duration(days: 1));
    }
  }
  if (hour != null) return Due(DateTime(day.year, day.month, day.day, hour, minute!), timed: true);
  return Due(DateTime(day.year, day.month, day.day, 9));
}

DateTime _next(DateTime from, int weekday, {bool allowToday = false}) {
  var d = from;
  if (!allowToday || d.weekday != weekday) {
    d = d.add(const Duration(days: 1));
    while (d.weekday != weekday) {
      d = d.add(const Duration(days: 1));
    }
  }
  return d;
}
