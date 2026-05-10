//
//  SidebarRedisCommandsTests.swift
//  TableProTests
//
//  Tests for Redis sidebar command generation.
//
//  NOTE: All Redis sidebar helpers (generateSidebarRedisCommands, redisEscape,
//  isSidebarSQLFunction, generateSidebarUpdateSQL) are private extension methods
//  on MainContentCoordinator and cannot be unit tested without changing their
//  access level. MainContentCoordinator also requires database connections and
//  coordinator infrastructure that make it impractical to instantiate in tests.
//
//  To enable testing, consider extracting these helpers into a standalone
//  struct (e.g., SidebarRedisCommandBuilder) with internal access.
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

// No testable public API available for sidebar Redis commands.
// All helper methods are private to MainContentCoordinator.
