import Foundation

struct KeywordDifficultyRankedResult: Equatable, Sendable {
    let position: Int
    let appStoreID: Int64
    let title: String
    let subtitle: String?
    let ratingCount: Int?
    let averageRating: Double?
    let releaseDate: Date?
    let sellerName: String?

    init(
        position: Int,
        appStoreID: Int64,
        title: String,
        subtitle: String? = nil,
        ratingCount: Int?,
        averageRating: Double? = nil,
        releaseDate: Date? = nil,
        sellerName: String? = nil
    ) {
        self.position = position
        self.appStoreID = appStoreID
        self.title = title
        self.subtitle = subtitle
        self.ratingCount = ratingCount
        self.averageRating = averageRating
        self.releaseDate = releaseDate
        self.sellerName = sellerName
    }

    init(searchResult: SearchRankingItem) {
        self.init(
            position: searchResult.position,
            appStoreID: searchResult.appStoreID,
            title: searchResult.name,
            subtitle: searchResult.subtitle,
            ratingCount: searchResult.ratingCount,
            averageRating: searchResult.averageRating,
            releaseDate: searchResult.releaseDate,
            sellerName: searchResult.sellerName
        )
    }
}

enum KeywordDifficultyEstimation: Equatable, Sendable {
    case estimated(EstimatedKeywordDifficulty)
    case unavailable(KeywordDifficultyUnavailable)
}

struct EstimatedKeywordDifficulty: Equatable, Sendable {
    enum Confidence: String, Equatable, Sendable {
        case low
        case medium
        case high
    }

    let score: Int
    let confidenceScore: Int
    let confidence: Confidence
    let algorithmIdentifier: String
    let algorithmVersion: Int
    let evidence: KeywordDifficultyEvidence
    let notes: [String]
}

struct KeywordDifficultyUnavailable: Equatable, Sendable {
    enum Reason: String, Equatable, Sendable {
        case emptyKeyword
        case insufficientResults
        case insufficientRatingEvidence
    }

    let reason: Reason
    let algorithmIdentifier: String
    let algorithmVersion: Int
    let evidence: KeywordDifficultyEvidence
    let notes: [String]
}

struct KeywordDifficultyResultEvidence: Codable, Equatable, Sendable {
    let position: Int
    let appStoreID: Int64
    let title: String
    let subtitle: String?
    let ratingCount: Int?
    let ratingAuthorityScore: Int?
    let titleTokenCoveragePercentage: Int?
    let combinedTokenCoveragePercentage: Int?
    let metadataMatchScore: Int?
    let exactTitlePhraseMatch: Bool
    let exactSubtitlePhraseMatch: Bool
}

struct KeywordDifficultyEvidence: Codable, Equatable, Sendable {
    let consideredResultCount: Int
    let ratedResultCount: Int
    let weightedRatingCoveragePercentage: Int
    let maximumRatingCount: Int?
    let medianRatingCount: Int?
    let ratingAuthorityScore: Int?
    let metadataSaturationScore: Int?
    let resultEvidence: [KeywordDifficultyResultEvidence]

    var ratingCoveragePercentage: Int {
        guard consideredResultCount > 0 else { return 0 }
        return Int((Double(ratedResultCount) / Double(consideredResultCount) * 100).rounded())
    }

    var exactTitlePhraseMatchCount: Int {
        resultEvidence.count(where: \.exactTitlePhraseMatch)
    }

    var exactSubtitlePhraseMatchCount: Int {
        resultEvidence.count(where: \.exactSubtitlePhraseMatch)
    }
}

enum KeywordDifficultyEstimator {
    static let algorithmIdentifier = "top10-authority-saturation"
    static let algorithmVersion = 1
    static let maximumResultCount = 10
    static let minimumResultCount = 3
    static let minimumRatedResultCount = 3

    static func estimate(
        keyword: String,
        searchResults: [SearchRankingItem]
    ) -> KeywordDifficultyEstimation {
        estimate(
            keyword: keyword,
            rankedResults: searchResults.map(KeywordDifficultyRankedResult.init(searchResult:))
        )
    }

    static func estimate(
        keyword: String,
        rankedResults: [KeywordDifficultyRankedResult]
    ) -> KeywordDifficultyEstimation {
        let consideredResults = normalizedTopResults(rankedResults)
        let keywordTokens = tokens(keyword)
        let resultEvidence = makeResultEvidence(
            consideredResults,
            keywordTokens: keywordTokens
        )
        let evidence = makeEvidence(resultEvidence)

        guard !keywordTokens.isEmpty else {
            return unavailable(
                reason: .emptyKeyword,
                evidence: evidence,
                note: "Estimated competition is unavailable because the keyword is empty."
            )
        }
        guard consideredResults.count >= minimumResultCount else {
            return unavailable(
                reason: .insufficientResults,
                evidence: evidence,
                note: "Estimated competition is unavailable until at least \(minimumResultCount) unique top-ten ranking results are available."
            )
        }
        guard evidence.ratedResultCount >= minimumRatedResultCount else {
            return unavailable(
                reason: .insufficientRatingEvidence,
                evidence: evidence,
                note: "Estimated competition is unavailable until at least \(minimumRatedResultCount) top-ten results include rating counts."
            )
        }

        let ratingAuthority = Double(evidence.ratingAuthorityScore ?? 0)
        let metadataSaturation = Double(evidence.metadataSaturationScore ?? 0)
        let score = boundedScore(ratingAuthority * 0.70 + metadataSaturation * 0.30)
        let confidenceScore = confidenceScore(
            consideredResultCount: evidence.consideredResultCount,
            weightedRatingCoveragePercentage: evidence.weightedRatingCoveragePercentage
        )
        let confidence = confidence(for: confidenceScore)

        return .estimated(EstimatedKeywordDifficulty(
            score: score,
            confidenceScore: confidenceScore,
            confidence: confidence,
            algorithmIdentifier: algorithmIdentifier,
            algorithmVersion: algorithmVersion,
            evidence: evidence,
            notes: [
                "Heuristic estimated competition based on the current top App Store search results.",
                "Uses 70% rating-count authority and 30% title/subtitle keyword saturation.",
                "This is not Apple Ads difficulty, Search Popularity, or an Apple-provided metric.",
                "Evidence confidence \(confidence.rawValue) (\(confidenceScore)/100): \(evidence.ratedResultCount) of \(evidence.consideredResultCount) sampled results included rating counts."
            ]
        ))
    }

    static func normalizedTopResults(
        _ results: [KeywordDifficultyRankedResult]
    ) -> [KeywordDifficultyRankedResult] {
        // Provider positions are not a unique key. Keep different apps that share
        // a position ordered by app ID, then deduplicate only repeated app IDs.
        let sortedResults = results
            .filter { (1...maximumResultCount).contains($0.position) }
            .sorted {
                if $0.position != $1.position { return $0.position < $1.position }
                if $0.appStoreID != $1.appStoreID { return $0.appStoreID < $1.appStoreID }
                let leftHasRatingEvidence = $0.ratingCount.map { $0 >= 0 } ?? false
                let rightHasRatingEvidence = $1.ratingCount.map { $0 >= 0 } ?? false
                if leftHasRatingEvidence != rightHasRatingEvidence {
                    return leftHasRatingEvidence
                }
                if leftHasRatingEvidence,
                   let leftRatingCount = $0.ratingCount,
                   let rightRatingCount = $1.ratingCount,
                   leftRatingCount != rightRatingCount
                {
                    return leftRatingCount < rightRatingCount
                }
                if $0.title != $1.title { return $0.title < $1.title }
                let leftSubtitle = $0.subtitle ?? ""
                let rightSubtitle = $1.subtitle ?? ""
                if leftSubtitle != rightSubtitle { return leftSubtitle < rightSubtitle }
                if ($0.ratingCount == nil) != ($1.ratingCount == nil) {
                    return $0.ratingCount == nil
                }
                if let leftRatingCount = $0.ratingCount,
                   let rightRatingCount = $1.ratingCount,
                   leftRatingCount != rightRatingCount
                {
                    return leftRatingCount < rightRatingCount
                }
                return false
            }

        var seenAppStoreIDs = Set<Int64>()
        return Array(sortedResults.filter {
            seenAppStoreIDs.insert($0.appStoreID).inserted
        }.prefix(maximumResultCount))
    }

    static func makeResultEvidence(
        _ results: [KeywordDifficultyRankedResult],
        keywordTokens: [String]
    ) -> [KeywordDifficultyResultEvidence] {
        let uniqueKeywordTokens = Set(keywordTokens)
        return results.map { result in
            let validRatingCount = result.ratingCount.flatMap { $0 >= 0 ? $0 : nil }
            let titleTokens = tokens(result.title)
            let subtitleTokens = tokens(result.subtitle ?? "")
            let titleTokenSet = Set(titleTokens)
            let combinedTokenSet = titleTokenSet.union(subtitleTokens)
            let exactTitlePhraseMatch = containsPhrase(keywordTokens, in: titleTokens)
            let exactSubtitlePhraseMatch = containsPhrase(keywordTokens, in: subtitleTokens)

            let titleCoverage = tokenCoverage(
                keywordTokens: uniqueKeywordTokens,
                candidateTokens: titleTokenSet
            )
            let combinedCoverage = tokenCoverage(
                keywordTokens: uniqueKeywordTokens,
                candidateTokens: combinedTokenSet
            )
            let metadataMatchScore: Double?
            if keywordTokens.isEmpty {
                metadataMatchScore = nil
            } else {
                metadataMatchScore = max(
                    titleCoverage * 100,
                    combinedCoverage * 75
                )
            }

            return KeywordDifficultyResultEvidence(
                position: result.position,
                appStoreID: result.appStoreID,
                title: result.title,
                subtitle: result.subtitle,
                ratingCount: validRatingCount,
                ratingAuthorityScore: validRatingCount.map(ratingAuthorityScore),
                titleTokenCoveragePercentage: keywordTokens.isEmpty ? nil : boundedScore(titleCoverage * 100),
                combinedTokenCoveragePercentage: keywordTokens.isEmpty ? nil : boundedScore(combinedCoverage * 100),
                metadataMatchScore: metadataMatchScore.map(boundedScore),
                exactTitlePhraseMatch: exactTitlePhraseMatch,
                exactSubtitlePhraseMatch: exactSubtitlePhraseMatch
            )
        }
    }

    static func makeEvidence(
        _ resultEvidence: [KeywordDifficultyResultEvidence]
    ) -> KeywordDifficultyEvidence {
        let ratedEvidence = resultEvidence.filter { $0.ratingCount != nil }
        let ratingCounts = ratedEvidence.compactMap(\.ratingCount).sorted()
        let totalWeight = resultEvidence.reduce(0.0) { partialResult, evidence in
            partialResult + positionWeight(evidence.position)
        }
        let ratedWeight = ratedEvidence.reduce(0.0) { partialResult, evidence in
            partialResult + positionWeight(evidence.position)
        }
        let weightedRatingCoverage = totalWeight > 0 ? ratedWeight / totalWeight * 100 : 0

        return KeywordDifficultyEvidence(
            consideredResultCount: resultEvidence.count,
            ratedResultCount: ratedEvidence.count,
            weightedRatingCoveragePercentage: boundedScore(weightedRatingCoverage),
            maximumRatingCount: ratingCounts.last,
            medianRatingCount: medianRatingCount(ratingCounts),
            ratingAuthorityScore: weightedAverage(
                ratedEvidence,
                value: { $0.ratingAuthorityScore }
            ),
            metadataSaturationScore: weightedAverage(
                resultEvidence,
                value: { $0.metadataMatchScore }
            ),
            resultEvidence: resultEvidence
        )
    }

    private static func weightedAverage(
        _ evidence: [KeywordDifficultyResultEvidence],
        value: (KeywordDifficultyResultEvidence) -> Int?
    ) -> Int? {
        let availableEvidence = evidence.compactMap { item -> (KeywordDifficultyResultEvidence, Int)? in
            value(item).map { (item, $0) }
        }
        guard !availableEvidence.isEmpty else { return nil }

        let totalWeight = availableEvidence.reduce(0.0) { partialResult, pair in
            partialResult + positionWeight(pair.0.position)
        }
        guard totalWeight > 0 else { return nil }
        let weightedValue = availableEvidence.reduce(0.0) { partialResult, pair in
            partialResult + Double(pair.1) * positionWeight(pair.0.position)
        }
        return boundedScore(weightedValue / totalWeight)
    }

    private static func ratingAuthorityScore(_ ratingCount: Int) -> Int {
        boundedScore(min(1, log10(Double(ratingCount) + 1) / 6) * 100)
    }

    private static func medianRatingCount(_ sortedRatingCounts: [Int]) -> Int? {
        guard !sortedRatingCounts.isEmpty else { return nil }
        let middleIndex = sortedRatingCounts.count / 2
        guard sortedRatingCounts.count.isMultiple(of: 2) else {
            return sortedRatingCounts[middleIndex]
        }

        let lower = sortedRatingCounts[middleIndex - 1]
        let upper = sortedRatingCounts[middleIndex]
        return lower + (upper - lower) / 2
    }

    private static func tokenCoverage(
        keywordTokens: Set<String>,
        candidateTokens: Set<String>
    ) -> Double {
        guard !keywordTokens.isEmpty else { return 0 }
        return Double(keywordTokens.intersection(candidateTokens).count) / Double(keywordTokens.count)
    }

    private static func containsPhrase(_ phrase: [String], in candidate: [String]) -> Bool {
        guard !phrase.isEmpty, phrase.count <= candidate.count else { return false }
        if phrase.count == 1 {
            return candidate.contains(phrase[0])
        }

        for startIndex in 0...(candidate.count - phrase.count) {
            if candidate[startIndex..<(startIndex + phrase.count)].elementsEqual(phrase) {
                return true
            }
        }
        return false
    }

    static func tokens(_ value: String) -> [String] {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    static func positionWeight(_ position: Int) -> Double {
        Double(maximumResultCount - position + 1)
    }

    static func confidenceScore(
        consideredResultCount: Int,
        weightedRatingCoveragePercentage: Int
    ) -> Int {
        let sampleCoverage = Double(consideredResultCount) / Double(maximumResultCount)
        let ratingCoverage = Double(weightedRatingCoveragePercentage) / 100
        return boundedScore(sqrt(sampleCoverage * ratingCoverage) * 100)
    }

    static func confidence(
        for score: Int
    ) -> EstimatedKeywordDifficulty.Confidence {
        switch score {
        case 85...:
            return .high
        case 65...:
            return .medium
        default:
            return .low
        }
    }

    private static func unavailable(
        reason: KeywordDifficultyUnavailable.Reason,
        evidence: KeywordDifficultyEvidence,
        note: String
    ) -> KeywordDifficultyEstimation {
        .unavailable(KeywordDifficultyUnavailable(
            reason: reason,
            algorithmIdentifier: algorithmIdentifier,
            algorithmVersion: algorithmVersion,
            evidence: evidence,
            notes: [
                "This would be a heuristic estimate, not Apple Ads difficulty or an Apple-provided metric.",
                note
            ]
        ))
    }

    static func boundedScore(_ value: Double) -> Int {
        Int(min(100, max(0, value)).rounded())
    }
}

// MARK: - Strength-based estimator (v2)


/// Estimates how hard it is to rank in the top results for a keyword by measuring
/// how strong the apps that already rank there are.
///
/// Factor weights and curves were tuned on live top-10 App Store results (broad
/// head terms such as "vpn" and "weather" scored 85-97, niche transit and timer
/// phrases 45-75, and fields of tiny new apps below 15). They are heuristics,
/// not an Apple metric.
///
///     factor            weight   per result   notes
///     rating volume     35%      yes          log curve over rating count
///     dominant players  25%      field        apps with 5,000+ ratings
///     app age           13%      yes          years since release
///     momentum          12%      yes          ratings per year of age
///     average stars     10%      yes          only when 5+ ratings
///     publisher mix      5%      field        distinct publishers
///
/// Factors with no data are dropped and the remaining weights renormalised. Title
/// and subtitle match is not a strength factor of its own. It scales the result:
/// when the top results barely mention the keyword the SERP is off-topic, so the
/// score is damped down to 55% of its raw value.
enum KeywordStrengthDifficultyEstimator {
    static let algorithmIdentifier = "top10-strength"
    static let algorithmVersion = 2

    private enum Weight {
        static let volume = 0.35
        static let dominant = 0.25
        static let age = 0.13
        static let momentum = 0.12
        static let rating = 0.10
        static let publisher = 0.05
    }

    private static let volumeCurve: [(Double, Double)] = [
        (10, 12), (100, 35), (1_000, 58), (10_000, 80), (100_000, 100)
    ]
    private static let momentumCurve: [(Double, Double)] = [
        (10, 8), (100, 30), (1_000, 60), (10_000, 100)
    ]
    private static let ageCurve: [(Double, Double)] = [
        (0.5, 8), (2, 35), (5, 65), (10, 100)
    ]
    private static let dominantRatingCount = 5_000
    private static let minimumRatingsForAverage = 5
    private static let dampingFloor = 0.55
    private static let relevantTitleSaturation = 50.0
    private static let secondsPerYear = 365.25 * 86_400

    static func estimate(
        keyword: String,
        searchResults: [SearchRankingItem],
        now: Date = Date()
    ) -> KeywordDifficultyEstimation {
        estimate(
            keyword: keyword,
            rankedResults: searchResults.map(KeywordDifficultyRankedResult.init(searchResult:)),
            now: now
        )
    }

    static func estimate(
        keyword: String,
        rankedResults: [KeywordDifficultyRankedResult],
        now: Date = Date()
    ) -> KeywordDifficultyEstimation {
        let considered = KeywordDifficultyEstimator.normalizedTopResults(rankedResults)
        let keywordTokens = KeywordDifficultyEstimator.tokens(keyword)
        let resultEvidence = KeywordDifficultyEstimator.makeResultEvidence(
            considered,
            keywordTokens: keywordTokens
        )
        let evidence = KeywordDifficultyEstimator.makeEvidence(resultEvidence)

        guard !keywordTokens.isEmpty else {
            return unavailable(.emptyKeyword, evidence, "Estimated competition is unavailable because the keyword is empty.")
        }
        guard considered.count >= KeywordDifficultyEstimator.minimumResultCount else {
            return unavailable(
                .insufficientResults,
                evidence,
                "Estimated competition is unavailable until at least \(KeywordDifficultyEstimator.minimumResultCount) unique top-ten ranking results are available."
            )
        }
        guard evidence.ratedResultCount >= KeywordDifficultyEstimator.minimumRatedResultCount else {
            return unavailable(
                .insufficientRatingEvidence,
                evidence,
                "Estimated competition is unavailable until at least \(KeywordDifficultyEstimator.minimumRatedResultCount) top-ten results include rating counts."
            )
        }

        let factors = factorScores(
            considered: considered,
            resultEvidence: resultEvidence,
            evidence: evidence,
            now: now
        )
        let weighted: [(weight: Double, value: Double)] = [
            (Weight.volume, factors.volume),
            (Weight.dominant, factors.dominant),
            (Weight.momentum, factors.momentum),
            (Weight.rating, factors.rating),
            (Weight.age, factors.age),
            (Weight.publisher, factors.publisher)
        ].compactMap { pair in pair.1.map { (pair.0, $0) } }
        let totalWeight = weighted.reduce(0) { $0 + $1.weight }
        let raw = weighted.reduce(0) { $0 + $1.weight * $1.value } / totalWeight
        let relevance = factors.title.map { min(1, $0 / relevantTitleSaturation) } ?? 1
        let score = KeywordDifficultyEstimator.boundedScore(
            raw * (dampingFloor + (1 - dampingFloor) * relevance)
        )

        let confidenceScore = KeywordDifficultyEstimator.confidenceScore(
            consideredResultCount: evidence.consideredResultCount,
            weightedRatingCoveragePercentage: evidence.weightedRatingCoveragePercentage
        )
        let confidence = KeywordDifficultyEstimator.confidence(for: confidenceScore)

        return .estimated(EstimatedKeywordDifficulty(
            score: score,
            confidenceScore: confidenceScore,
            confidence: confidence,
            algorithmIdentifier: algorithmIdentifier,
            algorithmVersion: algorithmVersion,
            evidence: evidence,
            notes: [
                "Heuristic estimate of how strong the apps ranking in the top ten are.",
                "Weights: rating volume 35%, dominant apps 25%, age 13%, momentum 12%, stars 10%, publisher mix 5%. Off-topic results damp the score.",
                "This is not Apple Ads difficulty, Search Popularity, or an Apple-provided metric.",
                "Evidence confidence \(confidence.rawValue) (\(confidenceScore)/100): \(evidence.ratedResultCount) of \(evidence.consideredResultCount) sampled results included rating counts."
            ]
        ))
    }

    // MARK: - Factors

    private struct FactorScores {
        let volume: Double?
        let dominant: Double?
        let title: Double?
        let momentum: Double?
        let rating: Double?
        let age: Double?
        let publisher: Double?
    }

    private static func factorScores(
        considered: [KeywordDifficultyRankedResult],
        resultEvidence: [KeywordDifficultyResultEvidence],
        evidence: KeywordDifficultyEvidence,
        now: Date
    ) -> FactorScores {
        var volume: [(Int, Double)] = []
        var momentum: [(Int, Double)] = []
        var rating: [(Int, Double)] = []
        var age: [(Int, Double)] = []

        for result in considered {
            if let count = result.ratingCount, count >= 0 {
                volume.append((result.position, curve(Double(count), volumeCurve)))
            }
            let years = result.releaseDate.map { max(0.05, now.timeIntervalSince($0) / secondsPerYear) }
            if let years {
                age.append((result.position, curve(years, ageCurve)))
                if let count = result.ratingCount, count >= 0 {
                    momentum.append((result.position, curve(Double(count) / years, momentumCurve)))
                }
            }
            if let count = result.ratingCount, count >= minimumRatingsForAverage,
               let stars = result.averageRating, stars > 0
            {
                rating.append((result.position, min(100, max(0, (stars - 3.5) / 1.4 * 100))))
            }
        }

        let ratedCounts = considered.compactMap { $0.ratingCount }.filter { $0 >= 0 }
        let dominantCount = ratedCounts.filter { $0 >= dominantRatingCount }.count
        let dominant = linear(Double(dominantCount), [(0, 0), (1, 35), (2, 60), (3, 80), (4, 100)])

        let publishers = Set(considered.map { $0.sellerName ?? String($0.appStoreID) })
        let publisher = Double(publishers.count) / Double(considered.count) * 100

        return FactorScores(
            volume: positionWeighted(volume),
            dominant: dominant,
            title: evidence.metadataSaturationScore.map(Double.init),
            momentum: positionWeighted(momentum),
            rating: positionWeighted(rating),
            age: positionWeighted(age),
            publisher: publisher
        )
    }

    private static func positionWeighted(_ values: [(Int, Double)]) -> Double? {
        guard !values.isEmpty else { return nil }
        let totalWeight = values.reduce(0) { $0 + KeywordDifficultyEstimator.positionWeight($1.0) }
        guard totalWeight > 0 else { return nil }
        return values.reduce(0) { $0 + KeywordDifficultyEstimator.positionWeight($1.0) * $1.1 } / totalWeight
    }

    /// Log-interpolates between calibration points; linear from zero up to the
    /// first point and flat after the last.
    private static func curve(_ value: Double, _ points: [(Double, Double)]) -> Double {
        guard value > 0, let first = points.first, let last = points.last else { return 0 }
        if value <= first.0 { return first.1 * value / first.0 }
        if value >= last.0 { return last.1 }
        for (lower, upper) in zip(points, points.dropFirst()) where value <= upper.0 {
            let t = log(value / lower.0) / log(upper.0 / lower.0)
            return lower.1 + t * (upper.1 - lower.1)
        }
        return last.1
    }

    private static func linear(_ value: Double, _ points: [(Double, Double)]) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if value <= first.0 { return first.1 }
        if value >= last.0 { return last.1 }
        for (lower, upper) in zip(points, points.dropFirst()) where value <= upper.0 {
            let t = (value - lower.0) / (upper.0 - lower.0)
            return lower.1 + t * (upper.1 - lower.1)
        }
        return last.1
    }

    private static func unavailable(
        _ reason: KeywordDifficultyUnavailable.Reason,
        _ evidence: KeywordDifficultyEvidence,
        _ note: String
    ) -> KeywordDifficultyEstimation {
        .unavailable(KeywordDifficultyUnavailable(
            reason: reason,
            algorithmIdentifier: algorithmIdentifier,
            algorithmVersion: algorithmVersion,
            evidence: evidence,
            notes: [
                "This would be a heuristic estimate, not Apple Ads difficulty or an Apple-provided metric.",
                note
            ]
        ))
    }
}
