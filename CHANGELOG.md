## 0.1.0

Initial release.

### Core
- `StabilizationEngine` — SAR merge, intra-batch dedup, contradiction detection
- `DriftTracker` — regional drift correction with submap isolation
- `SpatialBlockIndex` — grid-cell spatial index for O(cells) overlap queries
- `OverlapResolver` — spatial NMS with language-aware thresholds
- `BlockKeyGenerator` — position+text dedup keys with fuzzy neighbor matching
- `BlockClassifierService` — OCR group classification (fixed/sticky/carousel/IC/normal)

### Types
- `TrackedBlock<T>` / `ObservableBlock<P>` — block identity interfaces
- `AbsoluteRect` — zero-cost coordinate-space safety (extension type)
- `SpaceKey`, `ContainerId`, `ScrollContext`, `StickyFallback` — value types

### Utilities
- `TextDedupUtils` — Levenshtein, Jaccard, CJK detection
- `RobustStats` — median, MAD, IQR
- `IqrOutlier` — Tukey fence outlier detection
