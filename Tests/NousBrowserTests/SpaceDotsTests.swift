import Testing
@testable import NousBrowser

@Suite("Space dots")
@MainActor
struct SpaceDotsTests {
    @Test func fewSpacesShowEveryDot() {
        #expect(SpaceDots.visibleRange(count: 1, active: 0) == 0..<1)
        #expect(SpaceDots.visibleRange(count: 4, active: 3) == 0..<4)
    }

    @Test func manySpacesShowAtMostFourAroundTheActiveOne() {
        for count in 5...12 {
            for active in 0..<count {
                let range = SpaceDots.visibleRange(count: count, active: active)
                #expect(range.count == 4)
                #expect(range.contains(active))
                #expect(range.lowerBound >= 0 && range.upperBound <= count)
            }
        }
        #expect(SpaceDots.visibleRange(count: 10, active: 0) == 0..<4)
        #expect(SpaceDots.visibleRange(count: 10, active: 5) == 3..<7)
        #expect(SpaceDots.visibleRange(count: 10, active: 9) == 6..<10)
    }
}

@Suite("Space dots fitting")
@MainActor
struct SpaceDotsFittingTests {
    @Test func narrowSpaceShowsFewerDots() {
        // Four dots with the 10pt current capsule need 40pt.
        #expect(SpaceDots.fittingLimit(for: 200) == 4)
        #expect(SpaceDots.fittingLimit(for: 40) == 4)
        #expect(SpaceDots.fittingLimit(for: 39) == 3)
        #expect(SpaceDots.fittingLimit(for: 20) == 2)
        #expect(SpaceDots.fittingLimit(for: 19) == 1)
        #expect(SpaceDots.fittingLimit(for: -10) == 0)
    }

    @Test func aSmallerLimitStillKeepsTheActiveSpaceVisible() {
        for count in 3...9 {
            for active in 0..<count {
                let range = SpaceDots.visibleRange(count: count, active: active, limit: 2)
                #expect(range.count == 2)
                #expect(range.contains(active))
            }
        }
    }
}
