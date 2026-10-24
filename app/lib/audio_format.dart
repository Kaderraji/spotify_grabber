import 'package:flutter/material.dart';

/// An output format the downloader can produce, with the copy shown to the
/// user: what it is, who it is for, and roughly how big the file gets.
class AudioFormat {
  const AudioFormat({
    required this.id,
    required this.label,
    required this.tagline,
    required this.size,
    required this.icon,
    this.recommended = false,
  });

  final String id;
  final String label;
  final String tagline;
  final String size;
  final IconData icon;
  final bool recommended;

  String get shortLabel => label.split(' (').first;

  static const List<AudioFormat> all = <AudioFormat>[
    AudioFormat(
      id: 'm4a',
      label: 'M4A (AAC)',
      tagline: 'What Spotify itself serves. Balanced quality and size, and '
          'every Android phone plays it.',
      size: '≈ 4 MB per track',
      icon: Icons.graphic_eq,
      recommended: true,
    ),
    AudioFormat(
      id: 'mp3',
      label: 'MP3 (192 kbps)',
      tagline: 'Old faithful. Opens on anything — car stereos, old MP3 '
          'players, every app ever made.',
      size: '≈ 4.5 MB per track',
      icon: Icons.audiotrack,
    ),
    AudioFormat(
      id: 'opus',
      label: 'Opus',
      tagline: 'Half the size at the same quality. Needs a reasonably recent '
          'player (Android 10+ is fine).',
      size: '≈ 2.5 MB per track',
      icon: Icons.compress,
    ),
    AudioFormat(
      id: 'flac',
      label: 'FLAC (lossless)',
      tagline: 'Nothing thrown away — the source codec kept intact, for '
          'good headphones and archiving.',
      size: '≈ 30 MB per track',
      icon: Icons.surround_sound,
    ),
  ];

  static AudioFormat byId(String? id) => all.firstWhere(
        (format) => format.id == id,
        orElse: () => all.first,
      );
}
