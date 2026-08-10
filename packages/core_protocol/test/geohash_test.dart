import 'package:core_protocol/core_protocol.dart';
import 'package:test/test.dart';

/// Geohash, as used for location channels.
///
/// The published reference values below are the point of this file: a geohash
/// implementation that disagrees with everyone else's puts its users in a
/// channel nobody else is in, and does so silently.
void main() {
  group('encode', () {
    test('matches the canonical example', () {
      // The example from Gustavo Niemeyer's original description.
      expect(Geohash.encode(57.64911, 10.40744, precision: 11), 'u4pruydqqvj');
    });

    test('agrees with the reference decoder about where it put us', () {
      // Only one published value is asserted above, because a landmark
      // geohash quoted from memory is not a reference — it is the same guess
      // twice. Everything else is checked by round-tripping through the
      // decoder, which fails loudly if either half drifts.
      for (final point in [
        (37.7749, -122.4194),
        (51.5074, -0.1278),
        (-33.8688, 151.2093),
      ]) {
        final bounds = Geohash.decodeBounds(
          Geohash.encode(point.$1, point.$2, precision: 8),
        );
        expect(bounds.latMin, lessThanOrEqualTo(point.$1));
        expect(bounds.latMax, greaterThanOrEqualTo(point.$1));
        expect(bounds.lonMin, lessThanOrEqualTo(point.$2));
        expect(bounds.lonMax, greaterThanOrEqualTo(point.$2));
      }
    });

    test('a shorter precision is a prefix of a longer one', () {
      // The property the whole scheme rests on: a coarser channel contains a
      // finer one, so "the city" and "this block" nest.
      final fine = Geohash.encode(48.8584, 2.2945, precision: 9);

      for (var i = 1; i < 9; i++) {
        expect(
          Geohash.encode(48.8584, 2.2945, precision: i),
          fine.substring(0, i),
        );
      }
    });

    test('handles the poles and the date line', () {
      expect(Geohash.encode(90, 180, precision: 4), isNotEmpty);
      expect(Geohash.encode(-90, -180, precision: 4), isNotEmpty);
      expect(Geohash.encode(0, 0, precision: 4), 's000');
    });

    test('clamps coordinates rather than producing nonsense', () {
      expect(
        Geohash.encode(200, 400, precision: 4),
        Geohash.encode(90, 180, precision: 4),
      );
    });

    test('precision zero or less is empty', () {
      expect(Geohash.encode(1, 1, precision: 0), isEmpty);
      expect(Geohash.encode(1, 1, precision: -3), isEmpty);
    });
  });

  group('decode', () {
    test('round-trips to within the cell', () {
      const lat = 52.3702;
      const lon = 4.8952;
      final hash = Geohash.encode(lat, lon, precision: 9);

      final centre = Geohash.decodeCentre(hash);

      expect(centre.latitude, closeTo(lat, 0.001));
      expect(centre.longitude, closeTo(lon, 0.001));
    });

    test('bounds contain the point that produced them', () {
      final bounds = Geohash.decodeBounds(
        Geohash.encode(35.6895, 139.6917, precision: 7),
      );

      expect(bounds.latMin, lessThanOrEqualTo(35.6895));
      expect(bounds.latMax, greaterThanOrEqualTo(35.6895));
      expect(bounds.lonMin, lessThanOrEqualTo(139.6917));
      expect(bounds.lonMax, greaterThanOrEqualTo(139.6917));
    });

    test('a coarser cell is larger', () {
      final coarse = Geohash.decodeBounds('u4p');
      final fine = Geohash.decodeBounds('u4pru');

      expect(
        coarse.latMax - coarse.latMin,
        greaterThan(fine.latMax - fine.latMin),
      );
    });

    test('ignores characters that are not in the alphabet', () {
      // Decoding must not throw on input a user typed.
      expect(() => Geohash.decodeCentre('u4p!ru'), returnsNormally);
    });
  });

  group('validity', () {
    test('accepts a real geohash', () {
      expect(Geohash.isValid('u4pruydqqvj'), isTrue);
      expect(Geohash.isValid('9Q8YYK8'), isTrue, reason: 'case insensitive');
    });

    test('rejects the letters left out of the alphabet', () {
      // a, i, l and o are excluded from base32 geohash precisely because they
      // are misread. Accepting them would put someone in the wrong channel.
      for (final bad in ['a', 'i', 'l', 'o']) {
        expect(Geohash.isValid('u4pr$bad'), isFalse, reason: bad);
      }
    });

    test('rejects empty and overlong input', () {
      expect(Geohash.isValid(''), isFalse);
      expect(Geohash.isValid('u' * 13), isFalse);
    });
  });

  group('neighbours', () {
    test('finds eight of them', () {
      expect(Geohash.neighbours('u4pruyd'), hasLength(8));
    });

    test('they are all distinct and none is the cell itself', () {
      final found = Geohash.neighbours('gcpvj0');

      expect(found.toSet(), hasLength(8));
      expect(found, isNot(contains('gcpvj0')));
    });

    test('they are all the same precision', () {
      expect(Geohash.neighbours('u4pruyd').every((n) => n.length == 7), isTrue);
    });

    test('wraps around the date line rather than falling off it', () {
      final edge = Geohash.encode(0, 179.999, precision: 4);

      expect(Geohash.neighbours(edge), hasLength(8));
    });

    test('drops the cells that would be over a pole', () {
      // There is nothing north of the north pole, and inventing a cell there
      // would subscribe the user to a channel that cannot exist.
      final top = Geohash.encode(89.9, 0, precision: 4);

      expect(Geohash.neighbours(top).length, lessThan(8));
    });

    test('an empty geohash has no neighbours', () {
      expect(Geohash.neighbours(''), isEmpty);
    });
  });

  group('channels', () {
    test('each level has the precision the network expects', () {
      // These lengths are the interoperability contract: they decide which
      // channel a user lands in.
      expect(GeohashLevel.building.precision, 8);
      expect(GeohashLevel.block.precision, 7);
      expect(GeohashLevel.neighbourhood.precision, 6);
      expect(GeohashLevel.city.precision, 5);
      expect(GeohashLevel.province.precision, 4);
      expect(GeohashLevel.region.precision, 2);
    });

    test('a channel is built from a coordinate and a level', () {
      final channel = GeohashChannel.at(
        latitude: 51.5074,
        longitude: -0.1278,
        level: GeohashLevel.city,
      );

      expect(channel.level, GeohashLevel.city);
      expect(channel.geohash.length, 5);
      expect(channel.geohash, Geohash.encode(51.5074, -0.1278, precision: 5));
    });

    test('channels nest, so the city contains the block', () {
      const lat = 51.5074;
      const lon = -0.1278;
      final city = GeohashChannel.at(
        latitude: lat,
        longitude: lon,
        level: GeohashLevel.city,
      );
      final block = GeohashChannel.at(
        latitude: lat,
        longitude: lon,
        level: GeohashLevel.block,
      );

      expect(block.geohash.startsWith(city.geohash), isTrue);
    });

    test('every level is offered for one coordinate', () {
      final all = GeohashChannel.levelsAt(
        latitude: 40.7128,
        longitude: -74.0060,
      );

      expect(all, hasLength(GeohashLevel.values.length));
      expect(all.map((c) => c.level).toSet(), GeohashLevel.values.toSet());
    });

    test('a channel is equal to another with the same level and cell', () {
      expect(
        const GeohashChannel(level: GeohashLevel.city, geohash: 'gcpvj'),
        const GeohashChannel(level: GeohashLevel.city, geohash: 'gcpvj'),
      );
    });

    test('the id is stable and distinguishes levels', () {
      const city = GeohashChannel(level: GeohashLevel.city, geohash: 'gcpvj');
      const block = GeohashChannel(level: GeohashLevel.block, geohash: 'gcpvj');

      expect(city.id, isNot(block.id));
    });

    test('parses a channel back from its id', () {
      const original = GeohashChannel(
        level: GeohashLevel.neighbourhood,
        geohash: 'gcpvj0',
      );

      expect(GeohashChannel.parse(original.id), original);
    });

    test('refuses an id that is not one', () {
      expect(GeohashChannel.parse('nonsense'), isNull);
      expect(GeohashChannel.parse('city-NOT!VALID'), isNull);
      expect(GeohashChannel.parse(''), isNull);
    });

    test('coarser levels are less precise about where somebody is', () {
      // Stated as a test because it is the entire privacy argument for
      // offering a choice of level at all.
      final building = Geohash.decodeBounds(
        GeohashChannel.at(
          latitude: 1,
          longitude: 1,
          level: GeohashLevel.building,
        ).geohash,
      );
      final region = Geohash.decodeBounds(
        GeohashChannel.at(
          latitude: 1,
          longitude: 1,
          level: GeohashLevel.region,
        ).geohash,
      );

      expect(
        region.latMax - region.latMin,
        greaterThan((building.latMax - building.latMin) * 100),
      );
    });
  });
}
