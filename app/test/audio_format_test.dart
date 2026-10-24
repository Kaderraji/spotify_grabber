import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_grabber/audio_format.dart';

void main() {
  test('every format has an id, a label and a description', () {
    for (final format in AudioFormat.all) {
      expect(format.id, isNotEmpty);
      expect(format.label, isNotEmpty);
      expect(format.tagline.length, greaterThan(20));
      expect(format.size, contains('MB'));
    }
  });

  test('ids are unique and one format is the recommended default', () {
    final ids = AudioFormat.all.map((format) => format.id).toSet();
    expect(ids, hasLength(AudioFormat.all.length));
    expect(AudioFormat.all.where((format) => format.recommended), hasLength(1));
    expect(AudioFormat.all.first.recommended, isTrue);
  });

  test('looks formats up by id and falls back to the default', () {
    expect(AudioFormat.byId('mp3').label, startsWith('MP3'));
    expect(AudioFormat.byId('flac').label, startsWith('FLAC'));
    expect(AudioFormat.byId('nonsense').id, AudioFormat.all.first.id);
    expect(AudioFormat.byId(null).id, AudioFormat.all.first.id);
  });

  test('short label drops the codec brackets', () {
    expect(AudioFormat.byId('m4a').shortLabel, 'M4A');
    expect(AudioFormat.byId('mp3').shortLabel, 'MP3');
    expect(AudioFormat.byId('flac').shortLabel, 'FLAC');
  });
}
