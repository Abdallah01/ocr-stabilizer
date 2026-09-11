// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// #150 differential harness: a per-capture digest of EVERYTHING the
// engine returns and holds, replayed over the committed corpus under a
// fixed table of engine configurations, so a refactor of
// `stabilization_engine.dart` that changes any number, any text winner,
// any event or any tracked block — on any capture of any stream under any
// arm — goes red before it is merged.
//
// The A/B reports (`ab_report.dart`) pin statistics (merge counts, bucketed
// displacement means); a change that moves one block by one pixel on one
// capture can hide inside a rounded mean. This harness pins the raw
// state instead: the canonical JSON of each capture's
// `StabilizationResult` plus the engine's tracked set and band telemetry,
// hashed (FNV-1a 64, inline — the package has no crypto dependency and
// does not want one for a tool) so the committed `.diff.json` files stay
// small. A mismatch names the stream, the arm and the capture; the
// `dump` command of `tool/replay/differential.dart` prints that capture's
// canonical JSON so the two checkouts can be diffed line by line.

import 'dart:convert';

import 'package:ocr_stabilizer/ocr_stabilizer.dart';

import 'capture_stream.dart';
import 'replay_session.dart';

/// One named engine configuration the harness replays every stream under.
class DifferentialArm {
  const DifferentialArm(
    this.name, {
    required this.model,
    required this.stepResponse,
    this.floorPx,
    this.reanchorMinBlocks,
    this.adoptAgreeing = false,
    this.band = const BandFallbackConfig(),
    this.retention = const RetentionConfig(),
  });

  final String name;
  final PositionMergeModel model;
  final StepResponse stepResponse;
  final double? floorPx;
  final int? reanchorMinBlocks;
  final bool adoptAgreeing;
  final BandFallbackConfig band;
  final RetentionConfig retention;
}

/// The arm table. The first four are `abReport()`'s default arms, named
/// and configured identically, so the digest covers exactly what the
/// committed `.ab.json` numbers were produced from. The rest reach code
/// the A/B arms never run:
/// - `agreementCoherentAdopt` — the engine's OWN default configuration
///   since 2.4.0 (`adoptAgreeing: true`), i.e. what every consumer on the
///   defaults runs; the A/B base arms deliberately pin the pre-2.4.0
///   shape (see `replay()`'s doc).
/// - `agreementCoherentFloor` / `agreementCoherentReanchor` — the two
///   experimental coherent-shift levers, at the values the #119
///   experiments used (390 px floor, re-anchor at 1), so the branches a
///   `CoherentShiftDetector` extraction must carry are exercised.
/// - `bandObserveOnly` / `bandAdmit` — the band-relaxed fallback in both
///   live modes on top of the shipping configuration; every committed
///   A/B stream runs with the band OFF, so without these arms a
///   `Matcher` extraction could change the band branch unseen.
/// - `retention2` — the shipping configuration with unmatched cached
///   blocks kept for two captures (`RetentionConfig(missedFrames: 2)`).
///   The engine's default is zero, under which the retention and
///   cross-frame supersession pass is skipped entirely; a mutant that
///   broke that pass survived every other arm (this file's PR), so a
///   `RetentionManager` extraction needs this arm to be seen at all.
const List<DifferentialArm> kDifferentialArms = [
  DifferentialArm('legacy',
      model: PositionMergeModel.legacy, stepResponse: StepResponse.damp),
  DifferentialArm('agreementWeighted',
      model: PositionMergeModel.agreementWeighted,
      stepResponse: StepResponse.damp),
  DifferentialArm('agreementSnap',
      model: PositionMergeModel.agreementWeighted,
      stepResponse: StepResponse.snap),
  DifferentialArm('agreementCoherent',
      model: PositionMergeModel.agreementWeighted,
      stepResponse: StepResponse.coherentShift),
  DifferentialArm('agreementCoherentAdopt',
      model: PositionMergeModel.agreementWeighted,
      stepResponse: StepResponse.coherentShift,
      adoptAgreeing: true),
  DifferentialArm('agreementCoherentFloor',
      model: PositionMergeModel.agreementWeighted,
      stepResponse: StepResponse.coherentShift,
      floorPx: 390),
  DifferentialArm('agreementCoherentReanchor',
      model: PositionMergeModel.agreementWeighted,
      stepResponse: StepResponse.coherentShift,
      reanchorMinBlocks: 1),
  DifferentialArm('bandObserveOnly',
      model: PositionMergeModel.agreementWeighted,
      stepResponse: StepResponse.coherentShift,
      adoptAgreeing: true,
      band: BandFallbackConfig(mode: BandFallbackMode.observeOnly)),
  DifferentialArm('bandAdmit',
      model: PositionMergeModel.agreementWeighted,
      stepResponse: StepResponse.coherentShift,
      adoptAgreeing: true,
      band: BandFallbackConfig(mode: BandFallbackMode.admit)),
  DifferentialArm('retention2',
      model: PositionMergeModel.agreementWeighted,
      stepResponse: StepResponse.coherentShift,
      adoptAgreeing: true,
      retention: RetentionConfig(missedFrames: 2)),
];

/// Replay [stream] under [arm], invoking [onCapture] after every
/// `stabilize()` call exactly as [replay] does. The single funnel every
/// harness command goes through, so `report` and `dump` cannot disagree
/// on how an arm is built.
ReplayResult replayArm(
  CaptureStream stream,
  DifferentialArm arm, {
  required Viewport? viewport,
  required BucketPolicy bucketPolicy,
  required CaptureCallback onCapture,
}) =>
    replay(stream,
        band: arm.band,
        model: arm.model,
        stepResponse: arm.stepResponse,
        coherentShiftFloorPx: arm.floorPx,
        coherentShiftReanchorMinBlocks: arm.reanchorMinBlocks,
        coherentShiftAdoptAgreeing: arm.adoptAgreeing,
        retention: arm.retention,
        viewport: viewport,
        useStreamViewport: false,
        bucketPolicy: bucketPolicy,
        onCapture: onCapture);

/// The differential report for [stream]: per arm, one hash per capture
/// (in stream order, keyed by capture id) and a digest over the whole
/// sequence. This is the document committed as `<stream>.diff.json`.
///
/// Viewport and bucket policy follow `abReport()`'s contract: [viewport]
/// overrides, else the stream's `meta.vp`; the effective value is
/// recorded under `input`.
Map<String, Object?> differentialReport(
  CaptureStream stream, {
  Viewport? viewport,
  BucketPolicy bucketPolicy = BucketPolicy.auto,
}) {
  final effective = viewport ?? stream.viewport;
  final arms = <String, Object?>{};
  for (final arm in kDifferentialArms) {
    final captures = <Map<String, Object?>>[];
    replayArm(stream, arm,
        viewport: effective,
        bucketPolicy: bucketPolicy, onCapture: (captureId, result, engine) {
      captures.add({
        'capture': captureId,
        'hash': fnv1a64Hex(captureCanonicalJson(captureId, result, engine)),
      });
    });
    arms[arm.name] = {
      'captures': captures,
      'digest': fnv1a64Hex(captures.map((c) => c['hash']).join(',')),
    };
  }
  return {
    'mode': 'differential',
    'input': {
      'batches': stream.batches.length,
      'observations': stream.observationCount,
      'viewport': viewportJson(effective),
      'bucketPolicy': bucketPolicy.name,
    },
    'arms': arms,
  };
}

/// The canonical JSON of one capture under [arm], or null when [stream]
/// has no capture with that id. What `dump` prints; what the hashes in a
/// `.diff.json` were taken over.
String? captureCanonicalJsonFor(
  CaptureStream stream,
  DifferentialArm arm,
  int captureId, {
  Viewport? viewport,
  BucketPolicy bucketPolicy = BucketPolicy.auto,
}) {
  String? found;
  replayArm(stream, arm,
      viewport: viewport ?? stream.viewport,
      bucketPolicy: bucketPolicy, onCapture: (id, result, engine) {
    if (id == captureId) found = captureCanonicalJson(id, result, engine);
  });
  return found;
}

/// Canonical JSON of one capture: the whole [StabilizationResult], the
/// engine's tracked set after the capture (sorted by geometry, then text,
/// so index iteration order is not part of the contract) and the band
/// telemetry counters. Keys are emitted in a fixed order and every map
/// with data-dependent keys is sorted, so equal state encodes to equal
/// bytes.
String captureCanonicalJson(
  int captureId,
  StabilizationResult<ReplayBlock> result,
  StabilizationEngine<ReplayBlock, Object> engine,
) =>
    jsonEncode(captureDigestMap(captureId, result, engine));

/// The map [captureCanonicalJson] encodes — exposed so a test can assert
/// on fields without re-parsing.
Map<String, Object?> captureDigestMap(
  int captureId,
  StabilizationResult<ReplayBlock> result,
  StabilizationEngine<ReplayBlock, Object> engine,
) {
  final tracked = engine.spatialIndex.allBlocks.toList()..sort(_byGeometry);
  final shift = result.coherentShift;
  final turnover = result.identityTurnover;
  final transform = result.transformEstimate;
  final band = engine.bandStats;
  return {
    'capture': captureId,
    // Output order is part of the engine's contract (consumers render in
    // it), so `stable` is NOT sorted.
    'stable': [for (final b in result.stableBlocks) blockDigestMap(b)],
    'tracked': [for (final b in tracked) blockDigestMap(b)],
    'contradictions': [
      for (final c in result.contradictions)
        {
          'type': c.type.name,
          'target': blockDigestMap(c.target),
          'evidence': [for (final e in c.evidence) blockDigestMap(e)],
        },
    ],
    'invalidatedTexts': result.invalidatedTexts,
    'wellObservedTexts': result.wellObservedTexts,
    'coherentShift': shift == null
        ? null
        : {
            'dx': shift.translation.dx,
            'dy': shift.translation.dy,
            'memberCount': shift.memberCount,
            'adoptedCount': shift.adoptedCount,
            'decidedBy': shift.decidedBy.name,
          },
    'identityTurnover': {
      'merged': turnover.merged,
      'admitted': turnover.admitted,
      'retained': turnover.retained,
      'dropped': turnover.dropped,
    },
    'transformEstimate': transform == null
        ? null
        : {
            'scale': transform.scale,
            'tx': transform.translation.dx,
            'ty': transform.translation.dy,
            'pairCount': transform.pairCount,
            'residualPx': transform.residualPx,
            'spanPx': transform.spanPx,
            'rejectedPairs': transform.rejectedPairs,
            'largestGapShare': transform.largestGapShare,
          },
    'bandStats': {
      'primaryMatchesAdmitted': band.primaryMatchesAdmitted,
      'primaryMatchesRejected': band.primaryMatchesRejected,
      'candidatesConsidered': band.candidatesConsidered,
      'rejectedCandidateFloor': band.rejectedCandidateFloor,
      'rejectedSpatial': band.rejectedSpatial,
      'rejectedTextBand': band.rejectedTextBand,
      'bandMatchesIdentified': band.bandMatchesIdentified,
      'matchesAdmitted': band.matchesAdmitted,
    },
  };
}

/// Every field of one tracked block that the engine reads or writes:
/// the 7 [Observation] getters (payload excepted — the rig's payload is
/// one opaque shared constant), the coordinate context, and all 8
/// [Track] state getters. Vote maps are sorted by key.
Map<String, Object?> blockDigestMap(Track<Object> b) {
  final r = b.absoluteRect.raw;
  final c = b.coordinates;
  final sf = c.stickyFallback;
  final textVotes = b.textVotes.keys.toList()..sort();
  return {
    'rect': [r.left, r.top, r.width, r.height],
    'text': b.originalText,
    'pconf': b.positionConfidence.raw,
    'tconf': b.textConfidence.raw,
    'sourceQuality': b.sourceQuality,
    'coordinates': {
      'viewportRelative': c.isViewportRelative,
      'innerScrollerChild': c.isInnerScrollerChild,
      'innerScrollerTop': c.innerScrollerTop,
      'horizontalScrollChild': c.isHorizontalScrollChild,
      'containerId': c.containerId?.hash,
      'scrollY': c.scrollContext.scrollY,
      'scrollX': c.scrollContext.scrollX,
      'hzScrollerIndex': c.scrollContext.hzScrollerIndex,
      'fromSticky': c.isFromStickyElement,
      'stickyFallback': [sf.scrollY, sf.scrollX, sf.isIc, sf.hzScrollerIndex],
    },
    'observationCount': b.observationCount,
    'classificationVotes': _sortedIntMap(b.classificationVotes),
    'carouselVotes': _sortedIntMap(b.carouselVotes.votes),
    'textVotes': {
      for (final k in textVotes)
        k: [
          b.textVotes[k]!.rawText,
          b.textVotes[k]!.score,
          b.textVotes[k]!.bestConfidence,
        ],
    },
    'isProvisional': b.isProvisional,
    'provisionalCapturesRemaining': b.provisionalCapturesRemaining,
    'groupSignature': b.groupSignature,
    'needsReclassification': b.needsReclassification,
  };
}

Map<String, int> _sortedIntMap(Map<int, int> m) {
  final keys = m.keys.toList()..sort();
  return {for (final k in keys) '$k': m[k]!};
}

int _byGeometry(Track<Object> a, Track<Object> b) {
  final ra = a.absoluteRect.raw;
  final rb = b.absoluteRect.raw;
  var c = ra.top.compareTo(rb.top);
  if (c != 0) return c;
  c = ra.left.compareTo(rb.left);
  if (c != 0) return c;
  c = ra.width.compareTo(rb.width);
  if (c != 0) return c;
  c = ra.height.compareTo(rb.height);
  if (c != 0) return c;
  c = a.originalText.compareTo(b.originalText);
  if (c != 0) return c;
  return a.observationCount.compareTo(b.observationCount);
}

/// FNV-1a, 64-bit, over the UTF-8 bytes of [s]; 16 lowercase hex digits.
/// Inline because the package's dev dependencies are `lints` and `test`
/// only and a tool-side hash is no reason to add one. Reference vectors:
/// `""` → `cbf29ce484222325`, `"a"` → `af63dc4c8601ec8c`.
String fnv1a64Hex(String s) {
  var h = 0xcbf29ce484222325;
  for (final byte in utf8.encode(s)) {
    h ^= byte;
    h *= 0x100000001b3; // wraps at 64 bits on the VM, as FNV specifies
  }
  final hi = (h >> 32) & 0xffffffff;
  final lo = h & 0xffffffff;
  return hi.toRadixString(16).padLeft(8, '0') +
      lo.toRadixString(16).padLeft(8, '0');
}
