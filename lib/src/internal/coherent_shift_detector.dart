// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// Coherent-shift detection (#116, `StepResponse.coherentShift`), extracted
// from `StabilizationEngine` in #150 with no behaviour change (the
// differential replay harness holds every capture of every committed
// stream byte-identical across the move).
//
// A per-batch translation vote: among a capture's ordinary text matches,
// find the pairs whose drift-corrected displacement exceeds their own
// agreement scale ("moved"), cluster the moved displacements, and — if a
// big-enough, big-enough-a-share group agrees — return its median
// displacement as the batch shift every member's merge applies. Where
// that quorum declines, the two #119 opt-in fallbacks (the absolute-pixel
// floor, then the batch-level re-anchor; both off by default) get a turn,
// each re-anchoring its own members only. Whatever plan is decided,
// `adoptAgreeing` (#119 item 2, ON by default since 2.4.0) then carries
// along the eligible under-gate pairs that agree with it — membership
// widens, the translation never changes.
//
// Design history (finding B's order-independent clustering, finding C's
// frozen drift snapshot, finding E's force-unwrap argument, the floor's
// direction + magnitude agreement, the re-anchor, adoption):
// doc/decisions/coherent-shift-detection.md.

import 'dart:math' show min;

import '../coherent_shift_event.dart' show CoherentShiftSource;
import '../drift_tracker.dart';
import '../observation.dart' show ObservationCoordinateViews;
import '../robust_stats.dart';
import '../stabilizer_config.dart' show CoherentShiftConfig;
import '../track.dart';
import '../types/geometry.dart' show Offset;
import 'block_geometry.dart';

/// A decided coherent-shift plan (#116/#119).
///
/// `memberDrift` is the single source of truth for membership AND each
/// member's frozen drift snapshot (#116 finding C); `adopted` is the
/// subset of members carried along by [CoherentShiftConfig.adoptAgreeing]
/// (#119 item 2); `source` names the path that decided the plan. Both
/// collections are identity-keyed — `T` is the consumer's type and may
/// define value equality. The engine summarises the plan's APPLIED
/// members into `StabilizationResult.coherentShift` (2.5.0).
typedef ShiftPlan<T> = ({
  Offset translation,
  Map<T, Offset> memberDrift,
  Set<T> adopted,
  CoherentShiftSource source,
});

/// One fresh block of a capture with its dry, primary-only match result —
/// the shape the engine's pre-pass produces for [CoherentShiftDetector.detect].
typedef ShiftCandidate<T> = ({
  T fresh,
  ({T? match, bool wasBandFallback, bool wasNestedFragment}) result,
});

/// Below this many pixels, a displacement component carries no direction
/// (#119). Used only by the floor fallback's direction-agreement check, so
/// a group whose members agree on the axis that actually moved is not
/// broken up by sub-pixel disagreement on the other one — real corpus
/// movers report dx values like `-0.0` and `0.1` on a purely vertical slab.
const double _kDirectionEpsilonPx = 1.0;

/// Decides the per-batch coherent-shift plan for one capture.
///
/// Pure with respect to the engine: reads [config], the shared
/// [driftTracker] (never mutates it) and the candidates it is given.
/// The engine constructs one per engine and calls [detect] on a dry,
/// primary-match-only pre-pass of each capture (see `stabilize`'s doc
/// for why that pre-pass is safe to run ahead of the capture's merges).
/// Whether the position model supports a shift at all (legacy has no
/// agreement scale) is the engine's decision, made before calling.
class CoherentShiftDetector<T extends Track<Object?>> {
  /// Creates a detector over [config] reading regional drift from
  /// [driftTracker]. Config invariants (`minBlocks >= 1`, ...) are
  /// validated by the engine at construction.
  CoherentShiftDetector({required this.config, required this.driftTracker});

  /// The coherent-shift levers (`StepResponseConfig.coherentShift`).
  final CoherentShiftConfig config;

  /// The engine's drift tracker — read for each candidate's regional
  /// drift, which is frozen into the plan (#116 finding C).
  final DriftTracker driftTracker;

  /// Detect a per-batch coherent shift among [matchResults].
  ///
  /// Returns `null` when fewer than [CoherentShiftConfig.minBlocks] pairs
  /// moved at all, or when the largest valid window fails either
  /// `minBlocks` or [CoherentShiftConfig.minShare] — unless one of the
  /// #119 opt-in fallbacks (`experimental.floorPx`, then
  /// `experimental.reanchorMinBlocks`) admits a group at one of those
  /// three decline points. Both are `null` by default.
  ///
  /// **Eligible pairs** — ordinary text matches only: excludes band
  /// admissions and nested fragments, provisional existing blocks (their
  /// merge freezes regardless), viewport-relative blocks (a different
  /// coordinate contract) and horizontal-scroll children (carousel motion
  /// is not page-scroll motion).
  ///
  /// **"Moved"** — the pair's drift-corrected displacement
  /// (`correctedRect.topLeft - existing.absoluteRect.raw.topLeft`, exactly
  /// what the merge computes) exceeds the existing block's own
  /// [agreementScale].
  ///
  /// **Frozen drift snapshot** (#116 finding C): each member's
  /// `driftTracker.medianDriftForKey(spaceKey)` — the value its
  /// displacement (and so the translation) was computed with — is
  /// returned in `memberDrift` alongside membership, for the engine to
  /// thread into that member's real merge as `frozenRegionDrift`.
  ///
  /// **Clustering** (#116 finding B): moved pairs are sorted by a
  /// deterministic total order over their VALUES — `(dy, dx,
  /// existing.top, existing.left, height)`, original index last — and
  /// every contiguous window of that order is searched, LARGEST size
  /// first, for one whose members all sit within
  /// `tolerance x min(member's own height, the window's OWN median
  /// height)` of the window's OWN median displacement (Euclidean),
  /// validated against the window's FINAL membership. The first (largest,
  /// then leftmost-start) valid window wins.
  ///
  /// **Adoption** (#119 item 2): once a plan is decided — by the quorum
  /// or either fallback — the eligible pairs that sat UNDER the "moved"
  /// gate but whose displacement is within the quorum's tolerance of the
  /// decided translation join `memberDrift` (and `adopted`). Members of
  /// the MERGE, not of the vote.
  ShiftPlan<T>? detect(List<ShiftCandidate<T>> matchResults) {
    final movedExisting = <T>[];
    final movedDx = <double>[];
    final movedDy = <double>[];
    final movedHeight = <double>[];
    final movedRegionDrift = <Offset>[];
    // #119 item 2: eligible pairs that sat under the "moved" gate, kept only
    // when adoption is on (see `adoptAgreeing` below).
    final agreeingExisting = <T>[];
    final agreeingDisplacement = <Offset>[];
    final agreeingHeight = <double>[];
    final agreeingRegionDrift = <Offset>[];
    for (final entry in matchResults) {
      final fresh = entry.fresh;
      final r = entry.result;
      final existing = r.match;
      if (existing == null) continue;
      if (r.wasNestedFragment || r.wasBandFallback) continue;
      if (existing.isProvisional) continue;
      if (fresh.isViewportRelative) continue;
      if (fresh.isHorizontalScrollChild || existing.isHorizontalScrollChild) {
        continue;
      }

      final spaceKey = driftTracker.spaceKeyFor(fresh);
      final regionDrift = driftTracker.medianDriftForKey(spaceKey);
      final correctedRect = DriftTracker.applyCorrectedPosition(
        fresh.absoluteRect.raw,
        regionDrift,
      );
      final displacement =
          correctedRect.topLeft - existing.absoluteRect.raw.topLeft;
      if (displacement.distance <= agreementScale(existing)) {
        // #119 item 2: remember the under-gate pair — `adoptAgreeing`
        // below may carry it along once a translation has been decided.
        // Same frozen drift snapshot as a voter (#116 finding C).
        if (config.adoptAgreeing) {
          agreeingExisting.add(existing);
          agreeingDisplacement.add(displacement);
          agreeingHeight.add(blockHeight(existing));
          agreeingRegionDrift.add(regionDrift);
        }
        continue;
      }

      movedExisting.add(existing);
      movedDx.add(displacement.dx);
      movedDy.add(displacement.dy);
      movedHeight.add(blockHeight(existing));
      // #116 finding C: the SAME snapshot that produced this member's
      // displacement above, frozen for its real merge later this capture.
      movedRegionDrift.add(regionDrift);
    }

    // Deterministic total order (#116 finding B): (dy, dx, existing.top,
    // existing.left, height), original index last as an always-harmless
    // final tiebreak — two value-identical pairs always land in the same
    // window regardless of their relative order.
    final order = List<int>.generate(movedExisting.length, (i) => i)
      ..sort((a, b) {
        var c = movedDy[a].compareTo(movedDy[b]);
        if (c != 0) return c;
        c = movedDx[a].compareTo(movedDx[b]);
        if (c != 0) return c;
        c = movedExisting[a]
            .absoluteRect
            .raw
            .top
            .compareTo(movedExisting[b].absoluteRect.raw.top);
        if (c != 0) return c;
        c = movedExisting[a]
            .absoluteRect
            .raw
            .left
            .compareTo(movedExisting[b].absoluteRect.raw.left);
        if (c != 0) return c;
        c = movedHeight[a].compareTo(movedHeight[b]);
        if (c != 0) return c;
        return a.compareTo(b);
      });

    // The LARGEST contiguous (in the order above) window of at least
    // [minSize] whose members all sit within `tolerance x min(member's own
    // height, the window's OWN median height)` of the window's OWN median
    // displacement — validated against the window's FINAL membership.
    // Largest-first, ties toward the leftmost start, so the search is
    // fully reproducible. [among] (PR #129 review C1) restricts the scan
    // to a subset of `order` — the floor fallback clusters only its
    // floor-qualified movers — and MUST already be in `order`'s sequence.
    List<int>? searchWindow(int minSize, {List<int>? among}) {
      final scan = among ?? order;
      for (var size = scan.length; size >= minSize; size--) {
        for (var start = 0; start + size <= scan.length; start++) {
          final window = scan.sublist(start, start + size);
          final wDx = RobustStats.median([for (final j in window) movedDx[j]]);
          final wDy = RobustStats.median([for (final j in window) movedDy[j]]);
          final wHeight =
              RobustStats.median([for (final j in window) movedHeight[j]]);
          // Only reachable if `window` were empty — `size` never goes
          // below `minSize`, which the engine enforces to be >= 1 for
          // both callers (finding E: explicit non-null handling).
          if (wDx == null || wDy == null || wHeight == null) continue;
          final valid = window.every((j) {
            final tol = config.tolerance * min(movedHeight[j], wHeight);
            final diff = Offset(movedDx[j] - wDx, movedDy[j] - wDy).distance;
            return diff <= tol;
          });
          if (valid) return window;
        }
      }
      return null;
    }

    // ┌─── #119: the absolute-pixel floor fallback ────────────────────
    // Tried ONLY where the ordinary quorum below declines, so enabling
    // the floor cannot perturb any capture the quorum already handles.
    // Direction agreement per axis (ignoring sub-epsilon components), then
    // magnitude agreement through the SAME clustering rule at a minimum
    // size of ONE (a lone mover is its own cluster — the starved-quorum
    // case this path exists for); only the winning cluster is re-anchored.
    ShiftPlan<T>? floorFallback() {
      final floor = config.experimental.floorPx;
      if (floor == null) return null;

      final qualified = <int>{};
      for (var i = 0; i < movedExisting.length; i++) {
        if (Offset(movedDx[i], movedDy[i]).distance >= floor) {
          qualified.add(i);
        }
      }
      if (qualified.isEmpty) return null;

      var sawPos = false, sawNeg = false;
      for (final j in qualified) {
        if (movedDy[j] > _kDirectionEpsilonPx) sawPos = true;
        if (movedDy[j] < -_kDirectionEpsilonPx) sawNeg = true;
      }
      if (sawPos && sawNeg) return null;
      sawPos = false;
      sawNeg = false;
      for (final j in qualified) {
        if (movedDx[j] > _kDirectionEpsilonPx) sawPos = true;
        if (movedDx[j] < -_kDirectionEpsilonPx) sawNeg = true;
      }
      if (sawPos && sawNeg) return null;

      // A size-1 window always validates (its member IS its median), so
      // for a non-empty set the search cannot come back empty — the null
      // check is belt and braces.
      final group = searchWindow(1, among: [
        for (final j in order)
          if (qualified.contains(j)) j
      ]);
      if (group == null) return null;

      // Non-null by construction: `group` is non-empty, and
      // `RobustStats.median` returns null only on an empty list.
      final tx = RobustStats.median([for (final j in group) movedDx[j]])!;
      final ty = RobustStats.median([for (final j in group) movedDy[j]])!;
      final memberDrift = Map<T, Offset>.identity();
      for (final j in group) {
        memberDrift[movedExisting[j]] = movedRegionDrift[j];
      }
      return (
        translation: Offset(tx, ty),
        memberDrift: memberDrift,
        adopted: Set<T>.identity(),
        source: CoherentShiftSource.floor,
      );
    }

    // ┌─── #119 candidate 2: the batch-level re-anchor ────────────────
    // The tolerance clustering exactly as it is, the SHARE gate dropped,
    // only the COUNT required to act lowered; the winning cluster's median
    // displacement applies to its own members alone. Tried after the
    // floor, so a consumer that sets both gets the magnitude-gated answer
    // first.
    ShiftPlan<T>? reanchorFallback() {
      final minN = config.experimental.reanchorMinBlocks;
      if (minN == null) return null;
      final group = searchWindow(minN);
      if (group == null) return null;
      // Non-null by construction: `group` is a non-empty window
      // (`minN >= 1` is enforced at engine construction).
      final tx = RobustStats.median([for (final j in group) movedDx[j]])!;
      final ty = RobustStats.median([for (final j in group) movedDy[j]])!;
      final memberDrift = Map<T, Offset>.identity();
      for (final j in group) {
        memberDrift[movedExisting[j]] = movedRegionDrift[j];
      }
      return (
        translation: Offset(tx, ty),
        memberDrift: memberDrift,
        adopted: Set<T>.identity(),
        source: CoherentShiftSource.reanchor,
      );
    }

    // ┌─── #119 item 2: adopt the agreeing under-gate pairs ─────────────
    // Runs on whatever plan the quorum or a fallback decided; a null plan
    // stays null. Membership only widens — no translation changes, and no
    // pair that could not vote gets a vote. The tolerance is the quorum's
    // own rule, measured against the DECIDED translation, so an under-gate
    // pair that merely moved a little (ordinary jitter) is left on damp.
    ShiftPlan<T>? adoptAgreeing(ShiftPlan<T>? plan) {
      if (plan == null || !config.adoptAgreeing) return plan;
      if (agreeingExisting.isEmpty) return plan;
      final groupHeight = RobustStats.median(
          [for (final member in plan.memberDrift.keys) blockHeight(member)]);
      // Null only for an empty group, which no path above produces.
      if (groupHeight == null) return plan;
      final t = plan.translation;
      for (var i = 0; i < agreeingExisting.length; i++) {
        final tol = config.tolerance * min(agreeingHeight[i], groupHeight);
        final diff = (agreeingDisplacement[i] - t).distance;
        if (diff > tol) continue;
        plan.memberDrift[agreeingExisting[i]] = agreeingRegionDrift[i];
        plan.adopted.add(agreeingExisting[i]);
      }
      return plan;
    }

    // Too few movers for the quorum to have anything to cluster.
    if (movedExisting.length < config.minBlocks) {
      return adoptAgreeing(floorFallback() ?? reanchorFallback());
    }

    final bestGroup = searchWindow(config.minBlocks);

    if (bestGroup == null) {
      return adoptAgreeing(floorFallback() ?? reanchorFallback());
    }
    if (bestGroup.length / movedExisting.length < config.minShare) {
      return adoptAgreeing(floorFallback() ?? reanchorFallback());
    }

    // #116 finding E: safe by construction — `bestGroup` is non-null and
    // non-empty (every window searched has `size >= minBlocks >= 1`), and
    // `RobustStats.median` returns null ONLY on an empty list.
    final tx = RobustStats.median([for (final j in bestGroup) movedDx[j]])!;
    final ty = RobustStats.median([for (final j in bestGroup) movedDy[j]])!;
    // #116 finding C: one identity-keyed map carries both membership AND
    // each member's frozen drift snapshot (see the ShiftPlan doc).
    final memberDrift = Map<T, Offset>.identity();
    for (final j in bestGroup) {
      memberDrift[movedExisting[j]] = movedRegionDrift[j];
    }
    return adoptAgreeing((
      translation: Offset(tx, ty),
      memberDrift: memberDrift,
      adopted: Set<T>.identity(),
      source: CoherentShiftSource.quorum,
    ));
  }
}
