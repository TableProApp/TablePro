//
//  SidebarRootShapeResolverTests.swift
//  TableProTests
//

import TableProPluginKit
import Testing

@testable import TablePro

/// The one thing that still differs between the three sidebar modes now that they share an outline.
@Suite("Sidebar root shape")
struct SidebarRootShapeResolverTests {
    /// Oracle, Snowflake, BigQuery and Trino. They have no database dimension, so the layout
    /// preference cannot apply and the schema shape wins outright.
    @Test("A hierarchical-schema engine ignores the layout preference")
    func hierarchicalWinsOverLayout() {
        for layout in SidebarLayout.allCases {
            for supportsTree in [true, false] {
                #expect(
                    SidebarRootShapeResolver.resolve(
                        groupingStrategy: .hierarchicalSchema,
                        sidebarLayout: layout,
                        supportsDatabaseTree: supportsTree
                    ) == .hierarchicalSchema
                )
            }
        }
    }

    @Test("Tree layout gives the database tree when the driver supports one")
    func treeLayoutUsesDatabaseTree() {
        for grouping in [GroupingStrategy.byDatabase, .bySchema] {
            #expect(
                SidebarRootShapeResolver.resolve(
                    groupingStrategy: grouping,
                    sidebarLayout: .tree,
                    supportsDatabaseTree: true
                ) == .databaseTree
            )
        }
    }

    @Test("Flat layout stays flat even when the driver supports a tree")
    func flatLayoutStaysFlat() {
        #expect(
            SidebarRootShapeResolver.resolve(
                groupingStrategy: .bySchema,
                sidebarLayout: .flat,
                supportsDatabaseTree: true
            ) == .flat
        )
    }

    /// Redis, SQLite, MongoDB and the rest. They have no tree to offer, so asking for one changes
    /// nothing.
    @Test("A driver with no tree stays flat whatever the layout says")
    func unsupportedTreeStaysFlat() {
        for layout in SidebarLayout.allCases {
            #expect(
                SidebarRootShapeResolver.resolve(
                    groupingStrategy: .flat,
                    sidebarLayout: layout,
                    supportsDatabaseTree: false
                ) == .flat
            )
        }
    }

    @Test("Every grouping strategy resolves to a shape")
    func everyStrategyResolves() {
        let shapes = [GroupingStrategy.byDatabase, .bySchema, .flat, .hierarchicalSchema].map {
            SidebarRootShapeResolver.resolve(
                groupingStrategy: $0,
                sidebarLayout: .flat,
                supportsDatabaseTree: true
            )
        }
        #expect(shapes == [.flat, .flat, .flat, .hierarchicalSchema])
    }
}
