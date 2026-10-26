import CoreGraphics
import Testing
@testable import NousBrowser

@Suite("Sidebar layout and drag geometry")
struct SidebarLayoutGeometryTests {
    @Test func figmaRowsKeepTheirInsetsWhenTheSidebarResizesOrScrolls() {
        let first = SidebarTabDragGeometry.rowFrame(at: 0, sidebarWidth: 243, scrollOffset: 0)
        #expect(first == CGRect(x: 12, y: 60, width: 219, height: 36))
        let scrolled = SidebarTabDragGeometry.rowFrame(at: 2, sidebarWidth: 243, scrollOffset: 37)
        #expect(scrolled == CGRect(x: 12, y: 97, width: 219, height: 36))
        let resized = SidebarTabDragGeometry.rowFrame(at: 2, sidebarWidth: 320, scrollOffset: 37)
        #expect(resized == CGRect(x: 12, y: 97, width: 296, height: 36))
        #expect(resized.midY == scrolled.midY)
        #expect(resized.maxX == 308)
    }

    @Test func rowTopsResolveToTheSameAbsoluteSlotAcrossFractionalScrollOffsets() {
        // Include rows above the viewport and offsets between complete rows;
        // discarding the offset or rounding it first shifts the drop by a row.
        for width: CGFloat in [180, 243, 320, 420] {
            for offset: CGFloat in [0, 18.5, 37, 74.25, 600] {
                for index in [0, 1, 2, 11, 42] {
                    let frame = SidebarTabDragGeometry.rowFrame(at: index, sidebarWidth: width, scrollOffset: offset)
                    let result = SidebarTabDragGeometry.proposedIndex(forRowTop: frame.minY, scrollOffset: offset)
                    #expect(result == index)
                    #expect(frame.midX == width / 2)
                }
            }
        }
    }

    @Test func slotThresholdsStayStableWhileTheListScrolls() {
        for offset: CGFloat in [0, 37, 81.5] {
            let frame = SidebarTabDragGeometry.rowFrame(at: 3, sidebarWidth: 243, scrollOffset: offset)
            #expect(SidebarTabDragGeometry.proposedIndex(forRowTop: frame.minY - 18, scrollOffset: offset) == 3)
            #expect(SidebarTabDragGeometry.proposedIndex(forRowTop: frame.minY + 18, scrollOffset: offset) == 3)
            #expect(SidebarTabDragGeometry.proposedIndex(forRowTop: frame.minY - 19, scrollOffset: offset) == 2)
            #expect(SidebarTabDragGeometry.proposedIndex(forRowTop: frame.minY + 19, scrollOffset: offset) == 4)
        }
    }

    @Test func crossWindowDropAreaIncludesRowsAndListEndButExcludesFloatingButtons() {
        for viewport in [CGSize(width: 180, height: 400), CGSize(width: 243, height: 600), CGSize(width: 320, height: 900)] {
            let x = viewport.width / 2
            #expect(SidebarTabDragGeometry.containsDropPoint(CGPoint(x: x, y: 78), viewport: viewport))
            #expect(SidebarTabDragGeometry.containsDropPoint(CGPoint(x: x, y: viewport.height - 56), viewport: viewport))
            #expect(!SidebarTabDragGeometry.containsDropPoint(CGPoint(x: 30, y: 30), viewport: viewport))
            #expect(!SidebarTabDragGeometry.containsDropPoint(CGPoint(x: 28, y: viewport.height - 28), viewport: viewport))
            #expect(!SidebarTabDragGeometry.containsDropPoint(CGPoint(x: -1, y: 78), viewport: viewport))
            #expect(!SidebarTabDragGeometry.containsDropPoint(CGPoint(x: viewport.width + 1, y: 78), viewport: viewport))
        }
        // A row's center in a wider, scrolled destination still selects its
        // absolute insertion slot when the grab point is its vertical center.
        let viewport = CGSize(width: 320, height: 600)
        let pointer = CGPoint(x: 160, y: 115)
        #expect(SidebarTabDragGeometry.containsDropPoint(pointer, viewport: viewport))
        #expect(SidebarTabDragGeometry.proposedIndex(forRowTop: pointer.y - 18, scrollOffset: 37) == 2)
    }

    @Test func invalidGeometryNeverBecomesACrossWindowTarget() {
        let viewport = CGSize(width: 243, height: 600)
        for value in [CGFloat.nan, .infinity, -.infinity] {
            #expect(!SidebarTabDragGeometry.containsDropPoint(CGPoint(x: value, y: 78), viewport: viewport))
            #expect(!SidebarTabDragGeometry.containsDropPoint(CGPoint(x: 120, y: value), viewport: viewport))
            #expect(!SidebarTabDragGeometry.containsDropPoint(CGPoint(x: 120, y: 78), viewport: CGSize(width: value, height: 600)))
            #expect(!SidebarTabDragGeometry.containsDropPoint(CGPoint(x: 120, y: 78), viewport: CGSize(width: 243, height: value)))
            #expect(SidebarTabDragGeometry.proposedIndex(forRowTop: value, scrollOffset: 0) == 0)
            #expect(SidebarTabDragGeometry.proposedIndex(forRowTop: 60, scrollOffset: value) == 0)
        }
        #expect(!SidebarTabDragGeometry.containsDropPoint(CGPoint(x: 0, y: 78), viewport: CGSize(width: 0, height: 600)))
        #expect(!SidebarTabDragGeometry.containsDropPoint(CGPoint(x: 120, y: 78), viewport: CGSize(width: 243, height: -1)))
    }
}
