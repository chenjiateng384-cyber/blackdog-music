import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/song.dart';
import '../services/music_platform.dart';
import 'v4_artwork.dart';

class SongArtwork extends StatefulWidget {
  const SongArtwork({
    required this.song,
    required this.size,
    this.borderRadius = 18,
    this.iconSize = 30,
    this.playing = false,
    this.onMissingArtwork,
    super.key,
  });

  final Song song;
  final double size;
  final double borderRadius;
  final double iconSize;
  final bool playing;
  final VoidCallback? onMissingArtwork;

  @override
  State<SongArtwork> createState() => _SongArtworkState();
}

class _SongArtworkState extends State<SongArtwork> {
  static final MusicPlatform _platform = MusicPlatform();
  static final Map<int, Future<Uint8List?>> _embeddedCache = {};
  late Future<Uint8List?> _embedded;
  bool _requestedOnline = false;

  @override
  void initState() {
    super.initState();
    _loadEmbedded();
  }

  @override
  void didUpdateWidget(covariant SongArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.id != widget.song.id) {
      _requestedOnline = false;
      _loadEmbedded();
    }
  }

  void _loadEmbedded() {
    _embedded = _embeddedCache.putIfAbsent(
      widget.song.id,
      () => _platform.artwork(widget.song.uri),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: widget.song.onlineArtwork != null
            ? _image(widget.song.onlineArtwork!)
            : FutureBuilder<Uint8List?>(
                future: _embedded,
                builder: (context, snapshot) {
                  final bytes = snapshot.data;
                  if (bytes != null && bytes.isNotEmpty) return _image(bytes);
                  if (snapshot.connectionState == ConnectionState.done &&
                      !_requestedOnline) {
                    _requestedOnline = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      widget.onMissingArtwork?.call();
                    });
                  }
                  return _placeholder();
                },
              ),
      ),
    );
  }

  Widget _image(Uint8List bytes) {
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final cacheExtent = (widget.size * pixelRatio).ceil().clamp(64, 1024);
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.memory(
          bytes,
          fit: BoxFit.cover,
          cacheWidth: cacheExtent,
          cacheHeight: cacheExtent,
          filterQuality: FilterQuality.low,
          gaplessPlayback: true,
        ),
        if (widget.playing)
          ColoredBox(
            color: Colors.black38,
            child: const Icon(Icons.graphic_eq_rounded, color: Colors.white),
          ),
      ],
    );
  }

  Widget _placeholder() {
    return Stack(
      fit: StackFit.expand,
      children: [
        const NeutralArtworkPlaceholder(),
        if (widget.playing)
          const Positioned(
            right: 8,
            bottom: 8,
            child: Icon(
              Icons.graphic_eq_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
      ],
    );
  }
}
