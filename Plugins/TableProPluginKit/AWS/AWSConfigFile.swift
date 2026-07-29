import Foundation

public enum AWSConfigFile {
    public static var defaultConfigPath: String {
        if let override = ProcessInfo.processInfo.environment["AWS_CONFIG_FILE"], !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        return NSString("~/.aws/config").expandingTildeInPath
    }

    public static var defaultCredentialsPath: String {
        if let override = ProcessInfo.processInfo.environment["AWS_SHARED_CREDENTIALS_FILE"], !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        return NSString("~/.aws/credentials").expandingTildeInPath
    }

    public static func readFile(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    public static func mergedProfileSettings(
        profileName: String,
        configContents: String?,
        credentialsContents: String?
    ) -> [String: String] {
        var settings: [String: String] = [:]

        if let configContents {
            let sections = AWSSSO.parseIniSections(configContents)
            let sectionKey = profileName == "default" ? "default" : "profile \(profileName)"
            if let section = sections[sectionKey] {
                settings.merge(section) { _, new in new }
            }
        }

        if let credentialsContents {
            let sections = AWSSSO.parseIniSections(credentialsContents)
            if let section = sections[profileName] {
                settings.merge(section) { _, new in new }
            }
        }

        return settings
    }

    public static func discoverProfiles(
        configContents: String?,
        credentialsContents: String?
    ) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []

        func add(_ name: String) {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { return }
            seen.insert(trimmed)
            ordered.append(trimmed)
        }

        if let configContents {
            for section in AWSSSO.parseIniSections(configContents).keys {
                if section == "default" {
                    add("default")
                } else if section.hasPrefix("profile ") {
                    add(String(section.dropFirst("profile ".count)))
                }
            }
        }

        if let credentialsContents {
            for section in AWSSSO.parseIniSections(credentialsContents).keys where !section.hasPrefix("sso-session ") {
                add(section)
            }
        }

        return ordered.sorted { lhs, rhs in
            if lhs == "default" { return rhs != "default" }
            if rhs == "default" { return false }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }
}
