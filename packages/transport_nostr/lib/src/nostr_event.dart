import 'dart:convert';
import 'dart:typed_data';

/// A Nostr event.
///
/// Only what this app needs. Nostr is used here purely as a dumb store-and-
/// forward channel for frames that could not cross the mesh, so most of the
/// protocol — profiles, feeds, reactions — is irrelevant and deliberately
/// absent.
class NostrEvent {
  const NostrEvent({
    required this.id,
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    required this.tags,
    required this.content,
    required this.sig,
  });

  /// NIP-59 gift wrap. The outer layer everyone can see, whose author is a
  /// throwaway key and whose content is opaque.
  static const int kindGiftWrap = 1059;

  /// Ephemeral event: relays are asked not to store it. Best-effort — a relay
  /// is free to ignore that, which is why nothing sensitive is ever outside
  /// the wrap.
  static const int kindEphemeral = 20000;

  final String id;
  final String pubkey;
  final int createdAt;
  final int kind;
  final List<List<String>> tags;
  final String content;
  final String sig;

  /// The canonical serialisation an event id is computed over, per NIP-01.
  ///
  /// The field order and the absence of whitespace are part of the spec: any
  /// deviation produces a different id and every relay rejects the event.
  static String canonical({
    required String pubkey,
    required int createdAt,
    required int kind,
    required List<List<String>> tags,
    required String content,
  }) => jsonEncode([0, pubkey, createdAt, kind, tags, content]);

  Map<String, Object?> toJson() => {
    'id': id,
    'pubkey': pubkey,
    'created_at': createdAt,
    'kind': kind,
    'tags': tags,
    'content': content,
    'sig': sig,
  };

  /// Returns null for anything that is not a well-formed event, which relays
  /// do send: notices, errors, and events from other applications entirely.
  static NostrEvent? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final pubkey = raw['pubkey'];
    final createdAt = raw['created_at'];
    final kind = raw['kind'];
    final content = raw['content'];
    final sig = raw['sig'];

    if (id is! String ||
        pubkey is! String ||
        createdAt is! int ||
        kind is! int ||
        content is! String ||
        sig is! String) {
      return null;
    }

    final tags = <List<String>>[];
    final rawTags = raw['tags'];
    if (rawTags is List) {
      for (final tag in rawTags) {
        if (tag is List) tags.add(tag.map((e) => '$e').toList());
      }
    }

    return NostrEvent(
      id: id,
      pubkey: pubkey,
      createdAt: createdAt,
      kind: kind,
      tags: tags,
      content: content,
      sig: sig,
    );
  }

  /// First value of the first tag named [name], if present.
  String? tag(String name) {
    for (final tag in tags) {
      if (tag.length >= 2 && tag[0] == name) return tag[1];
    }
    return null;
  }
}

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List unhex(String value) {
  final out = Uint8List(value.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(value.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
