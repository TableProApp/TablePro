//
//  ProjectConfigFileMatcherTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("Project Config File Matcher")
struct ProjectConfigFileMatcherTests {

    @Test("Real dotenv files are classified with their tier")
    func testDotenvTiers() {
        #expect(ProjectConfigFileMatcher.classify(relativePath: ".env")?.tier == .nearCertain)
        #expect(ProjectConfigFileMatcher.classify(relativePath: ".env.local")?.tier == .nearCertain)
        #expect(ProjectConfigFileMatcher.classify(relativePath: ".env.production.local")?.tier == .nearCertain)
        #expect(ProjectConfigFileMatcher.classify(relativePath: ".env.production")?.tier == .likelyReal)
        #expect(ProjectConfigFileMatcher.classify(relativePath: ".env.test")?.tier == .lowValue)
    }

    @Test("Placeholder dotenv files are excluded")
    func testPlaceholderFilesExcluded() {
        #expect(ProjectConfigFileMatcher.classify(relativePath: ".env.example") == nil)
        #expect(ProjectConfigFileMatcher.classify(relativePath: ".env.sample") == nil)
        #expect(ProjectConfigFileMatcher.classify(relativePath: ".env.template") == nil)
        #expect(ProjectConfigFileMatcher.classify(relativePath: ".env.dist") == nil)
        #expect(ProjectConfigFileMatcher.classify(relativePath: ".env.schema") == nil)
    }

    @Test("A direnv script is never classified, even though it starts with .env")
    func testEnvrcExcluded() {
        #expect(ProjectConfigFileMatcher.classify(relativePath: ".envrc") == nil)
    }

    @Test("Backup files are excluded")
    func testBackupExcluded() {
        #expect(ProjectConfigFileMatcher.classify(relativePath: ".env.bak") == nil)
    }

    @Test("Suffix form dotenv names are matched, not only the prefix form")
    func testSuffixFormMatched() {
        #expect(ProjectConfigFileMatcher.classify(relativePath: "production.env")?.kind == .dotenv)
        #expect(ProjectConfigFileMatcher.classify(relativePath: "config/db.env")?.kind == .dotenv)
    }

    @Test("Framework config files are classified by name and location")
    func testFrameworkConfigs() {
        #expect(ProjectConfigFileMatcher.classify(relativePath: "wp-config.php")?.kind == .wordPressConfig)
        #expect(ProjectConfigFileMatcher.classify(relativePath: "prisma/schema.prisma")?.kind == .prismaSchema)
        #expect(ProjectConfigFileMatcher.classify(relativePath: "config/database.yml")?.kind == .railsDatabaseYaml)
        #expect(ProjectConfigFileMatcher.classify(
            relativePath: "src/main/resources/application.properties"
        )?.kind == .springProperties)
        #expect(ProjectConfigFileMatcher.classify(relativePath: "application-dev.yml")?.kind == .springYaml)
        #expect(ProjectConfigFileMatcher.classify(relativePath: "appsettings.Development.json")?.kind == .appSettingsJson)
        #expect(ProjectConfigFileMatcher.classify(relativePath: "docker-compose.yml")?.kind == .dockerCompose)
        #expect(ProjectConfigFileMatcher.classify(relativePath: "compose.yaml")?.kind == .dockerCompose)
    }

    @Test("A database.yml outside config is not a Rails database file")
    func testDatabaseYamlNeedsConfigParent() {
        #expect(ProjectConfigFileMatcher.classify(relativePath: "database.yml") == nil)
    }

    @Test("Unrelated files are not classified")
    func testUnrelatedFiles() {
        #expect(ProjectConfigFileMatcher.classify(relativePath: "README.md") == nil)
        #expect(ProjectConfigFileMatcher.classify(relativePath: "src/index.ts") == nil)
    }
}
