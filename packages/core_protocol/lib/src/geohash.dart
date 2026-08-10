import 'package:meta/meta.dart';

/// A decoded coordinate.
@immutable
class LatLon {
  const LatLon(this.latitude, this.longitude);

  final double latitude;
  final double longitude;
}

/// The rectangle a geohash cell covers.
@immutable
class GeohashBounds {
  const GeohashBounds({
    required this.latMin,
    required this.latMax,
    required this.lonMin,
    required this.lonMax,
  });

  final double latMin;
  final double latMax;
  final double lonMin;
  final double lonMax;
}

/// Base32 geohash, as used for location channels.
///
/// Ported deliberately rather than invented: a location channel only works if
/// every client computes the same cell name from the same coordinate. An
/// implementation that disagrees with the rest of the world by one bit puts its
/// users in a channel nobody else is in, and does so silently.
///
/// The alphabet omits `a`, `i`, `l` and `o` — the characters people misread —
/// which is why [isValid] rejects them rather than being lenient.
abstract final class Geohash {
  static const String _alphabet = '0123456789bcdefghjkmnpqrstuvwxyz';

  /// The longest cell name anybody uses. Twelve characters is already
  /// centimetres; beyond it the coordinate is noise.
  static const int maxLength = 12;

  /// Whether [value] is a usable cell name.
  static bool isValid(String value) {
    if (value.isEmpty || value.length > maxLength) return false;
    for (final char in value.toLowerCase().split('')) {
      if (!_alphabet.contains(char)) return false;
    }
    return true;
  }

  /// The cell of [precision] characters containing a coordinate.
  ///
  /// Coordinates outside the real world are clamped rather than rejected: a
  /// sensor glitch should put somebody at the pole, not crash the app.
  static String encode(
    double latitude,
    double longitude, {
    required int precision,
  }) {
    if (precision <= 0) return '';

    var latMin = -90.0;
    var latMax = 90.0;
    var lonMin = -180.0;
    var lonMax = 180.0;

    final lat = latitude.clamp(-90.0, 90.0);
    final lon = longitude.clamp(-180.0, 180.0);

    final out = StringBuffer();
    var even = true;
    var bit = 0;
    var value = 0;

    while (out.length < precision) {
      if (even) {
        final mid = (lonMin + lonMax) / 2;
        if (lon >= mid) {
          value |= 1 << (4 - bit);
          lonMin = mid;
        } else {
          lonMax = mid;
        }
      } else {
        final mid = (latMin + latMax) / 2;
        if (lat >= mid) {
          value |= 1 << (4 - bit);
          latMin = mid;
        } else {
          latMax = mid;
        }
      }

      even = !even;
      if (bit < 4) {
        bit++;
      } else {
        out.write(_alphabet[value]);
        bit = 0;
        value = 0;
      }
    }

    return out.toString();
  }

  /// The middle of a cell.
  static LatLon decodeCentre(String geohash) {
    final bounds = decodeBounds(geohash);
    return LatLon(
      (bounds.latMin + bounds.latMax) / 2,
      (bounds.lonMin + bounds.lonMax) / 2,
    );
  }

  /// The rectangle a cell covers.
  ///
  /// Characters outside the alphabet are skipped rather than throwing: this
  /// decodes strings a user typed, and one stray keystroke should narrow the
  /// answer, not crash.
  static GeohashBounds decodeBounds(String geohash) {
    var latMin = -90.0;
    var latMax = 90.0;
    var lonMin = -180.0;
    var lonMax = 180.0;

    var even = true;
    for (final char in geohash.toLowerCase().split('')) {
      final index = _alphabet.indexOf(char);
      if (index < 0) continue;

      for (final mask in const [16, 8, 4, 2, 1]) {
        if (even) {
          final mid = (lonMin + lonMax) / 2;
          if (index & mask != 0) {
            lonMin = mid;
          } else {
            lonMax = mid;
          }
        } else {
          final mid = (latMin + latMax) / 2;
          if (index & mask != 0) {
            latMin = mid;
          } else {
            latMax = mid;
          }
        }
        even = !even;
      }
    }

    return GeohashBounds(
      latMin: latMin,
      latMax: latMax,
      lonMin: lonMin,
      lonMax: lonMax,
    );
  }

  /// The eight cells around one, at the same precision.
  ///
  /// Cells that would sit over a pole are dropped: there is nothing north of
  /// the north pole, and inventing one would subscribe somebody to a channel
  /// that cannot exist. Longitude wraps, because the date line is a line on a
  /// map rather than an edge of the world.
  static List<String> neighbours(String geohash) {
    if (geohash.isEmpty) return const [];

    final precision = geohash.length;
    final bounds = decodeBounds(geohash);
    final centre = decodeCentre(geohash);
    final height = bounds.latMax - bounds.latMin;
    final width = bounds.lonMax - bounds.lonMin;

    double wrapLon(double lon) {
      var wrapped = lon;
      while (wrapped > 180) {
        wrapped -= 360;
      }
      while (wrapped < -180) {
        wrapped += 360;
      }
      return wrapped;
    }

    final candidates = <LatLon>[
      LatLon(centre.latitude + height, centre.longitude), // N
      LatLon(centre.latitude + height, centre.longitude + width), // NE
      LatLon(centre.latitude, centre.longitude + width), // E
      LatLon(centre.latitude - height, centre.longitude + width), // SE
      LatLon(centre.latitude - height, centre.longitude), // S
      LatLon(centre.latitude - height, centre.longitude - width), // SW
      LatLon(centre.latitude, centre.longitude - width), // W
      LatLon(centre.latitude + height, centre.longitude - width), // NW
    ];

    return [
      for (final candidate in candidates)
        if (candidate.latitude <= 90 && candidate.latitude >= -90)
          encode(
            candidate.latitude,
            wrapLon(candidate.longitude),
            precision: precision,
          ),
    ];
  }
}

/// How much of the map one channel covers.
///
/// The precisions are an interoperability contract, not a preference: they
/// decide which channel a user lands in, so they match what other clients use.
enum GeohashLevel {
  building(8, 'This building'),
  block(7, 'This block'),
  neighbourhood(6, 'This neighbourhood'),
  city(5, 'This city'),
  province(4, 'This region'),
  region(2, 'This part of the world');

  const GeohashLevel(this.precision, this.label);

  /// Characters of geohash. More characters is a smaller area — and a more
  /// precise statement about where the user is standing.
  final int precision;

  final String label;
}

/// A public channel for a place.
///
/// Anyone standing in the same cell can join without a code, which is the whole
/// point and also the whole risk: posting in one states, to everybody in it and
/// to whatever relay carries it, roughly where the user is. The level is the
/// user's dial for how roughly.
@immutable
class GeohashChannel {
  const GeohashChannel({required this.level, required this.geohash});

  /// The channel containing a coordinate at a given level.
  factory GeohashChannel.at({
    required double latitude,
    required double longitude,
    required GeohashLevel level,
  }) => GeohashChannel(
    level: level,
    geohash: Geohash.encode(latitude, longitude, precision: level.precision),
  );

  /// Every level for one coordinate, finest first, so the user can pick how
  /// much to reveal.
  static List<GeohashChannel> levelsAt({
    required double latitude,
    required double longitude,
  }) => [
    for (final level in GeohashLevel.values)
      GeohashChannel.at(latitude: latitude, longitude: longitude, level: level),
  ];

  /// Reads back an [id], or null if it is not one.
  static GeohashChannel? parse(String id) {
    final split = id.indexOf('-');
    if (split <= 0 || split == id.length - 1) return null;

    final name = id.substring(0, split);
    final geohash = id.substring(split + 1);
    if (!Geohash.isValid(geohash)) return null;

    for (final level in GeohashLevel.values) {
      if (level.name == name) {
        return GeohashChannel(level: level, geohash: geohash.toLowerCase());
      }
    }
    return null;
  }

  final GeohashLevel level;
  final String geohash;

  /// Stable identifier. Includes the level because the same cell name at two
  /// levels is two different channels.
  String get id => '${level.name}-$geohash';

  @override
  bool operator ==(Object other) =>
      other is GeohashChannel &&
      other.level == level &&
      other.geohash == geohash;

  @override
  int get hashCode => Object.hash(level, geohash);

  @override
  String toString() => 'GeohashChannel($id)';
}
