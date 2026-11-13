import Foundation
import Testing
@testable import WilcoCore

@Suite("Matrix layout")
struct MatrixLayoutTests {
    private let a = UUID(), b = UUID(), c = UUID()

    @Test func widthsAreClampedAndDefaulted() {
        var layout = MatrixLayout()
        #expect(layout.width(for: a) == MatrixLayout.defaultWidth)

        layout.setWidth(10, for: a)
        #expect(layout.width(for: a) == MatrixLayout.widthRange.lowerBound)
        layout.setWidth(10_000, for: a)
        #expect(layout.width(for: a) == MatrixLayout.widthRange.upperBound)
    }

    @Test func collapsedColumnsAreNarrowAndRememberTheirWidth() {
        var layout = MatrixLayout()
        layout.setWidth(400, for: a)
        layout.setCollapsed(true, for: a)
        #expect(layout.displayWidth(for: a) == MatrixLayout.collapsedWidth)

        layout.setCollapsed(false, for: a)
        #expect(layout.displayWidth(for: a) == 400)
    }

    @Test func fitSharesTheAvailableWidthAmongOpenColumns() {
        var layout = MatrixLayout()
        layout.setCollapsed(true, for: c)
        layout.fit([a, b, c], into: 600 + MatrixLayout.collapsedWidth)

        #expect(layout.width(for: a) == 300)
        #expect(layout.width(for: b) == 300)
        #expect(layout.displayWidth(for: c) == MatrixLayout.collapsedWidth)
    }

    @Test func fontSizesOverrideTheTranscriptSizeWithinLimits() {
        var layout = MatrixLayout()
        #expect(layout.fontSize(for: a, default: 13) == 13)
        layout.setFontSize(40, for: a)
        #expect(layout.fontSize(for: a, default: 13) == TranscriptAppearance.fontSizeRange.upperBound)
        layout.resetFontSizes()
        #expect(layout.fontSize(for: a, default: 15) == 15)
    }

    @Test func survivesAPropertyListRoundTrip() {
        var layout = MatrixLayout()
        layout.setWidth(321, for: a)
        layout.setFontSize(18, for: b)
        layout.setCollapsed(true, for: c)

        let restored = MatrixLayout(propertyLists: layout.propertyLists)
        #expect(restored == layout)
    }

    @Test func ignoresDamagedStoredValues() {
        let restored = MatrixLayout(propertyLists: (
            widths: ["not-a-uuid": 300, a.uuidString: 250],
            fontSizes: [b.uuidString: -5],
            collapsed: ["also-not-a-uuid", c.uuidString]
        ))
        #expect(restored.width(for: a) == 250)
        #expect(restored.fontSize(for: b, default: 13) == TranscriptAppearance.fontSizeRange.lowerBound)
        #expect(restored.isCollapsed(c))
    }
}

@Suite("Transcript appearance")
struct TranscriptAppearanceTests {
    @Test func ordersLinesForReading() {
        let lines = [1, 2, 3]
        #expect(TranscriptAppearance(newestFirst: false).ordered(lines) == [1, 2, 3])
        #expect(TranscriptAppearance(newestFirst: true).ordered(lines) == [3, 2, 1])
    }

    @Test func fontSizeIsKeptReadable() {
        var appearance = TranscriptAppearance()
        appearance.fontSize = 2
        #expect(appearance.fontSize == TranscriptAppearance.fontSizeRange.lowerBound)
        appearance.fontSize = 99
        #expect(appearance.fontSize == TranscriptAppearance.fontSizeRange.upperBound)
    }

    @Test func motionStylesDescribeThemselves() {
        #expect(MotionStyle.allCases.count == 4)
        #expect(MotionStyle.still.isAnimated == false)
        #expect(MotionStyle.allCases.filter(\.isAnimated).allSatisfy { !$0.summary.isEmpty })
    }

    @Test func themesRoundTripThroughTheirStoredNames() {
        #expect(AppTheme.allCases.map(\.rawValue) == ["system", "light", "dark"])
        for theme in AppTheme.allCases {
            #expect(AppTheme(rawValue: theme.rawValue) == theme)
            #expect(!theme.title.isEmpty && !theme.symbol.isEmpty)
        }
        #expect(AppTheme(rawValue: "sepia") == nil)
    }
}

@Suite("Matrix columns")
struct MatrixColumnsTests {
    @Test func channelModeIsDisplayOrder() {
        let f = GroupedShow()
        #expect(f.show.matrixColumns(.channels).map(\.id) == f.show.channelsInDisplayOrder.map(\.id))
    }

    @Test func groupModeIsGroupsThenUngrouped() {
        let f = GroupedShow()
        let columns = f.show.matrixColumns(.groups)
        #expect(columns.map(\.id) == [f.radios.id, f.stage.id, f.b.id])
        #expect(columns.first == .group(f.radios, channelCount: 2))
    }

    @Test func emptyGroupsGetNoColumn() {
        var f = GroupedShow()
        let empty = f.show.addGroup()
        #expect(!f.show.matrixColumns(.groups).map(\.id).contains(empty.id))
    }

    @Test func columnScopes() {
        let f = GroupedShow()
        #expect(MatrixColumn.group(f.radios, channelCount: 2).scope == .group(f.radios.id))
        #expect(MatrixColumn.channel(f.b).scope == .channel(f.b.id))
    }
}

@Suite("Matrix columns with free sidebar order")
struct MatrixColumnsOrderTests {
    @Test func groupModeFollowsTheSidebarIncludingInterleaving() {
        var f = GroupedShow()
        f.show.sidebarOrder = [.channel(f.b.id), .group(f.stage.id), .group(f.radios.id)]
        #expect(f.show.matrixColumns(.groups).map(\.id) == [f.b.id, f.stage.id, f.radios.id])
    }
}
