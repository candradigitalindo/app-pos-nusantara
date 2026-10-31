import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/product_photo_cache.dart';
import 'menu_avatar.dart';

/// Product image with the same sizing and fallback as the menu avatar.
class ProductPhoto extends StatefulWidget {
  final String name;
  final String photoUrl;
  final double? size;
  final double radius;
  final Future<File?> Function(String url)? loadFile;

  const ProductPhoto({
    super.key,
    required this.name,
    required this.photoUrl,
    this.size = 44,
    this.radius = 10,
    this.loadFile,
  });

  const ProductPhoto.fill({
    super.key,
    required this.name,
    required this.photoUrl,
    this.radius = 16,
    this.loadFile,
  }) : size = null;

  @override
  State<ProductPhoto> createState() => _ProductPhotoState();
}

class _ProductPhotoState extends State<ProductPhoto> {
  late Future<File?> _file;
  StreamSubscription<String>? _stored;

  @override
  void initState() {
    super.initState();
    _file = _load();
    _stored = ProductPhotoCache.instance.onStored.listen((url) {
      if (mounted && url == widget.photoUrl) {
        setState(() {
          _file = ProductPhotoCache.instance.cachedFile(url);
        });
      }
    });
  }

  @override
  void dispose() {
    _stored?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(ProductPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photoUrl != widget.photoUrl ||
        oldWidget.loadFile != widget.loadFile) {
      _file = _load();
    }
  }

  Future<File?> _load() async {
    if (widget.photoUrl.trim().isEmpty) return null;
    try {
      return await (widget.loadFile ??
          ProductPhotoCache.instance.fileFor)(widget.photoUrl);
    } catch (_) {
      return null;
    }
  }

  Widget _fallback() => widget.size == null
      ? MenuAvatar.fill(name: widget.name, radius: widget.radius)
      : MenuAvatar(name: widget.name, size: widget.size, radius: widget.radius);

  @override
  Widget build(BuildContext context) => SizedBox(
        width: widget.size ?? double.infinity,
        height: widget.size ?? double.infinity,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.radius),
          child: FutureBuilder<File?>(
            key: ValueKey(widget.photoUrl),
            future: _file,
            builder: (context, snapshot) {
              // Never retain a previous URL's image while its replacement is
              // loading; FutureBuilder may otherwise retain the old data.
              if (snapshot.connectionState != ConnectionState.done ||
                  snapshot.data == null) {
                return _fallback();
              }
              return LayoutBuilder(builder: (context, constraints) {
                final ratio = MediaQuery.devicePixelRatioOf(context);
                int pixels(double dimension) =>
                    ((dimension.isFinite ? dimension : 128) * ratio)
                        .ceil()
                        .clamp(1, 768)
                        .toInt();
                return Image(
                  image: ResizeImage(FileImage(snapshot.data!),
                      width: pixels(constraints.maxWidth),
                      height: pixels(constraints.maxHeight),
                      policy: ResizeImagePolicy.fit),
                  key: ValueKey(widget.photoUrl),
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  semanticLabel: widget.name,
                  errorBuilder: (_, __, ___) => _fallback(),
                );
              });
            },
          ),
        ),
      );
}
