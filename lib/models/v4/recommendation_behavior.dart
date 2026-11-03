class RecommendationBehaviorSignal {
  const RecommendationBehaviorSignal({
    required this.trackId,
    required this.acceptedCount,
    required this.rejectedCount,
    required this.directAcceptedCount,
    required this.recentExposureCount,
    required this.matchingTimeAcceptedCount,
    this.lowEngagementCount = 0,
    this.recentRejectStreak = 0,
    this.lastAcceptedAt,
    this.lastRejectedAt,
  });

  final String trackId;
  final int acceptedCount;
  final int rejectedCount;
  final int directAcceptedCount;
  final int recentExposureCount;
  final int matchingTimeAcceptedCount;
  final int lowEngagementCount;
  final int recentRejectStreak;
  final DateTime? lastAcceptedAt;
  final DateTime? lastRejectedAt;

  bool get hasAcceptedPlayback => acceptedCount > 0;

  double get negativeEvidence => rejectedCount + lowEngagementCount * 0.6;

  bool get hasReliableAcceptance {
    if (acceptedCount < negativeEvidence) return false;
    if (directAcceptedCount > 0) return true;
    return acceptedCount >= 2 && acceptedCount >= negativeEvidence + 0.5;
  }

  bool get hasDominantNegativeEvidence =>
      negativeEvidence >= acceptedCount + 1.5;

  bool isTemporarilySuppressedAt(DateTime now) {
    final rejectedAt = lastRejectedAt;
    if (rejectedAt == null || rejectedCount == 0) {
      return false;
    }
    final acceptedAt = lastAcceptedAt;
    if (acceptedAt != null && rejectedAt.isBefore(acceptedAt)) return false;
    final daysSinceRejected = now.difference(rejectedAt).inDays;
    if (acceptedCount == 0) {
      return rejectedCount >= 2
          ? daysSinceRejected <= 30
          : daysSinceRejected <= 7;
    }
    if (recentRejectStreak >= 2) return daysSinceRejected <= 30;
    if (rejectedCount >= acceptedCount + 2) {
      return daysSinceRejected <= 14;
    }
    return false;
  }
}
