import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

const _alphabet =
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#\$%*+,-.:;=?@[]^_{|}~';

String _base83(int value, int length) {
  var result = '';
  for (var index = length - 1; index >= 0; index--) {
    result += _alphabet[(value ~/ math.pow(83, index).toInt()) % 83];
  }
  return result;
}

int _read83(String value) {
  var result = 0;
  for (final character in value.split('')) {
    final digit = _alphabet.indexOf(character);
    if (digit < 0) throw const FormatException('Invalid BlurHash');
    result = result * 83 + digit;
  }
  return result;
}

double _linear(int value) {
  final color = value / 255;
  return color <= .04045
      ? color / 12.92
      : math.pow((color + .055) / 1.055, 2.4).toDouble();
}

int _srgb(double value) {
  final color = value.clamp(0.0, 1.0);
  final result = color <= .0031308
      ? color * 12.92
      : 1.055 * math.pow(color, 1 / 2.4) - .055;
  return (result * 255).round().clamp(0, 255);
}

double _signedPow(double value, double power) =>
    value.sign * math.pow(value.abs(), power).toDouble();

typedef BlurhashPixels = ({Uint8List rgba, int width, int height});

String encodeBlurhashPixels(BlurhashPixels pixels) {
  final componentsX = pixels.width >= pixels.height ? 4 : 3;
  final componentsY = pixels.width >= pixels.height ? 3 : 4;
  final colors = <List<double>>[];
  for (var componentY = 0; componentY < componentsY; componentY++) {
    for (var componentX = 0; componentX < componentsX; componentX++) {
      final color = [0.0, 0.0, 0.0];
      final normalization = componentX == 0 && componentY == 0 ? 1.0 : 2.0;
      for (var y = 0; y < pixels.height; y++) {
        for (var x = 0; x < pixels.width; x++) {
          final basis =
              normalization *
              math.cos(math.pi * componentX * x / pixels.width) *
              math.cos(math.pi * componentY * y / pixels.height);
          final offset = (y * pixels.width + x) * 4;
          final alpha = pixels.rgba[offset + 3] / 255;
          for (var channel = 0; channel < 3; channel++) {
            color[channel] +=
                basis *
                _linear(
                  (pixels.rgba[offset + channel] * alpha + 255 * (1 - alpha))
                      .round(),
                );
          }
        }
      }
      colors.add(
        color.map((value) => value / (pixels.width * pixels.height)).toList(),
      );
    }
  }
  final maximum = colors
      .skip(1)
      .expand((color) => color)
      .fold(0.0, (max, value) => math.max(max, value.abs()));
  final quantizedMaximum = (maximum * 166 - .5).floor().clamp(0, 82);
  final scale = (quantizedMaximum + 1) / 166;
  final dc =
      (_srgb(colors.first[0]) << 16) +
      (_srgb(colors.first[1]) << 8) +
      _srgb(colors.first[2]);
  var hash =
      _base83((componentsX - 1) + (componentsY - 1) * 9, 1) +
      _base83(quantizedMaximum, 1) +
      _base83(dc, 4);
  for (final color in colors.skip(1)) {
    final quantized = color
        .map(
          (value) =>
              (_signedPow(value / scale, .5) * 9 + 9.5).floor().clamp(0, 18),
        )
        .toList();
    hash += _base83(
      quantized[0] * 19 * 19 + quantized[1] * 19 + quantized[2],
      2,
    );
  }
  return hash;
}

/// Decode an untrusted hash into a small PNG. Malformed hashes fall back to the
/// ordinary loading surface, with bounded dimensions and component counts.
Uint8List? decodeBlurhash(String hash) {
  try {
    if (hash.length < 6 || hash.length > 166) return null;
    final flag = _read83(hash[0]);
    if (flag > 80) return null;
    final componentsX = flag % 9 + 1;
    final componentsY = flag ~/ 9 + 1;
    if (hash.length != 4 + 2 * componentsX * componentsY) return null;
    final scale = (_read83(hash[1]) + 1) / 166;
    final dc = _read83(hash.substring(2, 6));
    if (dc > 0xffffff) return null;
    final colors = <List<double>>[
      [_linear(dc >> 16), _linear((dc >> 8) & 255), _linear(dc & 255)],
    ];
    for (var index = 1; index < componentsX * componentsY; index++) {
      final value = _read83(hash.substring(4 + index * 2, 6 + index * 2));
      if (value >= 19 * 19 * 19) return null;
      colors.add([
        _signedPow((value ~/ (19 * 19) - 9) / 9, 2) * scale,
        _signedPow((value ~/ 19 % 19 - 9) / 9, 2) * scale,
        _signedPow((value % 19 - 9) / 9, 2) * scale,
      ]);
    }
    final pixels = Uint8List(32 * 32 * 4);
    for (var y = 0; y < 32; y++) {
      for (var x = 0; x < 32; x++) {
        final color = [0.0, 0.0, 0.0];
        for (var j = 0; j < componentsY; j++) {
          for (var i = 0; i < componentsX; i++) {
            final basis =
                math.cos(math.pi * x * i / 32) * math.cos(math.pi * y * j / 32);
            for (var channel = 0; channel < 3; channel++) {
              color[channel] += colors[i + j * componentsX][channel] * basis;
            }
          }
        }
        final offset = (y * 32 + x) * 4;
        for (var channel = 0; channel < 3; channel++) {
          pixels[offset + channel] = _srgb(color[channel]);
        }
        pixels[offset + 3] = 255;
      }
    }
    return img.encodePng(
      img.Image.fromBytes(
        width: 32,
        height: 32,
        bytes: pixels.buffer,
        numChannels: 4,
      ),
    );
  } on FormatException {
    return null;
  }
}

Future<String?> encodeImageBlurhash(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final scale = 32 / math.max(descriptor.width, descriptor.height);
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (descriptor.width * scale).round()),
      targetHeight: math.max(1, (descriptor.height * scale).round()),
    );
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    if (data == null) return null;
    return await compute(encodeBlurhashPixels, (
      rgba: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      width: image.width,
      height: image.height,
    ));
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}
