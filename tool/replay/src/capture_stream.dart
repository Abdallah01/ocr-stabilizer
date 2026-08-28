// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:convert';

import 'package:ocr_stabilizer/ocr_stabilizer.dart';

/// One `obs` record: the fresh observations of a single capture.
class ObsBatch {
  ObsBatch({
    required this.captureId,
    required this.rawCount,
    required this.blocks,
  });

  final int captureId;
  final int rawCount;

  /// Engine-ready blocks (payload is an opaque shared const).
  final List<DefaultTrackedBlock<Object>> blocks;
}

/// A parsed capture file: the observation stream plus the consumer-side
/// lifecycle events (schema: doc/replay/capture_schema.md).
/// The producer's CSS-pixel viewport, from the meta record's `vp` field
/// (2.1.0). The rig passes it to `StabilizationEngine.updateViewport` so
/// replayed geometry matches what a real consumer configures.
typedef Viewport = ({double width, double height});

class CaptureStream {
  CaptureStream({
    required this.batches,
    required this.events,
    required this.schemaVersion,
    required this.skippedLines,
    this.invalidRecords = 0,
    this.viewport,
  });

  final List<ObsBatch> batches;

  /// `meta.vp` — null when the stream predates the field (the rig then
  /// warns and runs on the engine's default buckets, which is NOT
  /// production geometry).
  final Viewport? viewport;

  /// Non-`obs`, non-`meta` records verbatim (merge/freeze/band_*/cluster_*).
  final List<Map<String, Object?>> events;

  final int? schemaVersion;

  /// Malformed lines skipped (reported, never silently discarded).
  final int skippedLines;

  /// Well-formed `obs` records whose blocks violated an engine invariant
  /// at reconstruction (confidence range, coordinate-space flags) — a
  /// recorder bug signal, kept separate from line-noise [skippedLines].
  final int invalidRecords;

  int get observationCount =>
      batches.fold(0, (sum, b) => sum + b.blocks.length);

  static CaptureStream parse(Iterable<String> lines) {
    final batches = <ObsBatch>[];
    final events = <Map<String, Object?>>[];
    int? version;
    Viewport? viewport;
    var skipped = 0;
    var invalidRecords = 0;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      Map<String, Object?> record;
      try {
        record = jsonDecode(trimmed) as Map<String, Object?>;
      } on FormatException {
        skipped++;
        continue;
      }
      switch (record['t']) {
        case 'meta':
          final v = record['v'];
          version = v is num ? v.toInt() : version;
          if (v is! num) skipped++;
          if (record.containsKey('vp')) {
            final vp = _parseViewport(record['vp']);
            // A present-but-malformed vp is a recorder bug (the field is
            // written by code, not typed by hand): keep it loud.
            if (vp == null) invalidRecords++;
            viewport = vp ?? viewport;
          }
        case 'obs':
          try {
            batches.add(_parseObs(record));
          } on Object {
            // A malformed batch must not abort the whole stream — but a
            // block that *parses* and still throws is an invariant
            // violation (confidence range, containerId/isc), not line
            // noise; count it separately so recorder bugs stay loud.
            invalidRecords++;
          }
        case final String _:
          events.add(record);
        default:
          // Non-string discriminator: never let it reach report code.
          skipped++;
      }
    }
    return CaptureStream(
      batches: batches,
      events: events,
      schemaVersion: version,
      skippedLines: skipped,
      invalidRecords: invalidRecords,
      viewport: viewport,
    );
  }

  /// `vp` must be `[width, height]` of finite, positive CSS px.
  static Viewport? _parseViewport(Object? raw) {
    if (raw is! List || raw.length != 2) return null;
    final w = raw[0];
    final h = raw[1];
    if (w is! num || h is! num) return null;
    final width = w.toDouble();
    final height = h.toDouble();
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      return null;
    }
    return (width: width, height: height);
  }

  static ObsBatch _parseObs(Map<String, Object?> record) => ObsBatch(
        captureId: (record['cap'] as num).toInt(),
        rawCount: (record['raw'] as num?)?.toInt() ?? -1,
        blocks: [
          for (final b in record['blocks'] as List)
            blockFromJson(b as Map<String, Object?>)
        ],
      );
}

/// Shared opaque payload — the engine carries it without reading.
const Object _payload = Object();

/// Reconstruct an engine-ready block from a schema-v1 `obs` block entry.
DefaultTrackedBlock<Object> blockFromJson(Map<String, Object?> b) {
  final rect = (b['rect'] as List).cast<num>();
  final sc = (b['sc'] as List?)?.cast<num>();
  final sf = b['sf'] as List?;
  final cid = b['cid'] as String?;
  final carVotes = _intMap(b['carVotes']);
  return DefaultTrackedBlock<Object>(
    payload: _payload,
    absoluteRect: AbsoluteRect(Rect.fromLTRB(
      rect[0].toDouble(),
      rect[1].toDouble(),
      rect[2].toDouble(),
      rect[3].toDouble(),
    )),
    originalText: b['otext'] as String,
    positionConfidence:
        PositionConfidence.from((b['pconf'] as num).toDouble()),
    textConfidence: TextConfidence.from((b['tconf'] as num).toDouble()),
    sourceQuality: (b['srcQ'] as num?)?.toInt() ?? 0,
    isViewportRelative: b['vr'] as bool? ?? false,
    isInnerScrollerChild: b['isc'] as bool? ?? false,
    innerScrollerTop: (b['iscTop'] as num?)?.toDouble() ?? 0,
    isHorizontalScrollChild: b['hsc'] as bool? ?? false,
    containerId: cid == null ? null : ContainerId(cid),
    isFromStickyElement: b['sticky'] as bool? ?? false,
    stickyFallback: sf == null
        ? StickyFallback.none
        : StickyFallback(
            scrollY: (sf[0] as num).toDouble(),
            scrollX: (sf[1] as num).toDouble(),
            isIc: sf[2] as bool,
            hzScrollerIndex: (sf[3] as num).toInt(),
          ),
    scrollContext: sc == null
        ? ScrollContext.none
        : ScrollContext(
            scrollY: sc[0].toDouble(),
            scrollX: sc[1].toDouble(),
            hzScrollerIndex: sc[2].toInt(),
          ),
    observationCount: (b['obsN'] as num?)?.toInt() ?? 1,
    isProvisional: b['prov'] as bool? ?? false,
    provisionalCapturesRemaining: (b['provN'] as num?)?.toInt() ?? 0,
    classificationVotes: _intMap(b['cvotes']) ?? const {},
    // Absent OR explicitly empty → the phantom {-1: 1} "never seen in a
    // carousel" sentinel (mirrors DefaultTrackedBlock's own default; an
    // empty map would misclassify the first real carousel observation).
    // tvotes is intentionally NOT reconstructed in loader v1 (schema doc).
    carouselIdVotes:
        (carVotes == null || carVotes.isEmpty) ? const {-1: 1} : carVotes,
  );
}

Map<int, int>? _intMap(Object? raw) {
  if (raw == null) return null;
  final m = raw as Map<String, Object?>;
  return {
    for (final e in m.entries) int.parse(e.key): (e.value as num).toInt()
  };
}
