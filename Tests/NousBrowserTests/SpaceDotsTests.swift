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
