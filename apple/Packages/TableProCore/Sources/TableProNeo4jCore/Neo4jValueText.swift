import Foundation

/// Renders Bolt values as grid text. Scalars and temporals read the way Cypher's `toString`
/// writes them; nodes, relationships, paths, lists and maps become JSON.
public enum Neo4jValueText {
    public static func text(_ value: PackStreamValue) -> String? {
        switch value {
        case .null:
            return nil
        case .bool(let flag):
            return flag ? "true" : "false"
        case .int(let number):
            return String(number)
        case .float(let number):
            return floatText(number)
        case .string(let text):
            return text
        case .bytes(let bytes):
            return "0x" + bytes.map { String(format: "%02x", $0) }.joined()
        case .list, .map:
            return json(jsonObject(value))
        case .structure(let tag, let fields):
            if let scalar = structureText(tag: tag, fields: fields) { return scalar }
            return json(jsonObject(value))
        }
    }

    public static func typeName(_ value: PackStreamValue) -> String {
        switch value {
        case .null: return "NULL"
        case .bool: return "BOOLEAN"
        case .int: return "INTEGER"
        case .float: return "FLOAT"
        case .string: return "STRING"
        case .bytes: return "BYTES"
        case .list: return "LIST"
        case .map: return "MAP"
        case .structure(let tag, _):
            switch tag {
            case Neo4jStructureTag.node: return "NODE"
            case Neo4jStructureTag.relationship, Neo4jStructureTag.unboundRelationship: return "RELATIONSHIP"
            case Neo4jStructureTag.path: return "PATH"
            case Neo4jStructureTag.date: return "DATE"
            case Neo4jStructureTag.time: return "ZONED TIME"
            case Neo4jStructureTag.localTime: return "LOCAL TIME"
            case Neo4jStructureTag.dateTime, Neo4jStructureTag.dateTimeZoneId,
                 Neo4jStructureTag.legacyDateTime, Neo4jStructureTag.legacyDateTimeZoneId:
                return "ZONED DATETIME"
            case Neo4jStructureTag.localDateTime: return "LOCAL DATETIME"
            case Neo4jStructureTag.duration: return "DURATION"
            case Neo4jStructureTag.point2D, Neo4jStructureTag.point3D: return "POINT"
            default: return "ANY"
            }
        }
    }

    public static func jsonObject(_ value: PackStreamValue) -> Any {
        switch value {
        case .null:
            return NSNull()
        case .bool(let flag):
            return flag
        case .int(let number):
            return number
        case .float(let number):
            return number.isFinite ? number as Any : floatText(number)
        case .string(let text):
            return text
        case .bytes:
            return text(value) ?? ""
        case .list(let items):
            return items.map(jsonObject)
        case .map(let entries):
            return entries.mapValues(jsonObject)
        case .structure(let tag, let fields):
            if let entity = Neo4jEntity(value) {
                return entityObject(entity)
            }
            if tag == Neo4jStructureTag.unboundRelationship, fields.count >= 3 {
                return [
                    "elementId": fields.count > 3 ? fields[3].stringValue ?? "" : fields[0].intValue.map(String.init) ?? "",
                    "type": fields[1].stringValue ?? "",
                    "properties": (fields[2].mapValue ?? [:]).mapValues(jsonObject)
                ] as [String: Any]
            }
            if tag == Neo4jStructureTag.path, fields.count == 3 {
                return pathObject(fields) ?? [
                    "nodes": (fields[0].listValue ?? []).map(jsonObject),
                    "relationships": (fields[1].listValue ?? []).map(jsonObject)
                ]
            }
            return structureText(tag: tag, fields: fields) ?? NSNull()
        }
    }

    /// Bolt sends a path's distinct nodes and relationships plus a sequence of (relationship, node)
    /// index pairs. A positive relationship index walks it forward, a negative one backward, and
    /// both are 1-based. The result lists every step in order, repeats included.
    private static func pathObject(_ fields: [PackStreamValue]) -> [String: Any]? {
        let nodes = (fields[0].listValue ?? []).compactMap(Neo4jEntity.init)
        let relationships = fields[1].listValue ?? []
        let sequence = (fields[2].listValue ?? []).compactMap(\.intValue)
        guard let start = nodes.first, sequence.count.isMultiple(of: 2) else { return nil }

        var orderedNodes = [entityObject(start)]
        var orderedRelationships: [Any] = []
        var current = start
        for step in stride(from: 0, to: sequence.count, by: 2) {
            let relationshipIndex = Int(sequence[step].magnitude) - 1
            let nodeIndex = Int(sequence[step + 1])
            guard sequence[step] != 0, relationships.indices.contains(relationshipIndex),
                  nodes.indices.contains(nodeIndex),
                  case .structure(_, let relationshipFields) = relationships[relationshipIndex],
                  relationshipFields.count >= 3
            else { return nil }
            let next = nodes[nodeIndex]
            let forward = sequence[step] > 0
            orderedRelationships.append(entityObject(Neo4jEntity(
                elementId: relationshipFields.count > 3
                    ? relationshipFields[3].stringValue ?? ""
                    : relationshipFields[0].intValue.map(String.init) ?? "",
                kind: .relationship(
                    type: relationshipFields[1].stringValue ?? "",
                    startId: forward ? current.elementId : next.elementId,
                    endId: forward ? next.elementId : current.elementId
                ),
                properties: relationshipFields[2].mapValue ?? [:]
            )))
            orderedNodes.append(entityObject(next))
            current = next
        }
        return ["nodes": orderedNodes, "relationships": orderedRelationships]
    }

    private static func entityObject(_ entity: Neo4jEntity) -> [String: Any] {
        var object: [String: Any] = [
            "elementId": entity.elementId,
            "properties": entity.properties.mapValues(jsonObject)
        ]
        switch entity.kind {
        case .node(let labels):
            object["labels"] = labels
        case .relationship(let type, let startId, let endId):
            object["type"] = type
            object["startElementId"] = startId
            object["endElementId"] = endId
        }
        return object
    }

    private static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return String(describing: object) }
        return text
    }

    static func floatText(_ number: Double) -> String {
        if number.isNaN { return "NaN" }
        if number.isInfinite { return number < 0 ? "-Infinity" : "Infinity" }
        return String(number)
    }

    // MARK: - Temporal and spatial

    static func structureText(tag: UInt8, fields: [PackStreamValue]) -> String? {
        let ints = fields.map { $0.intValue }
        switch tag {
        case Neo4jStructureTag.date:
            guard let days = ints.first ?? nil else { return nil }
            return dateText(days: days)
        case Neo4jStructureTag.localTime:
            guard let nanos = ints.first ?? nil else { return nil }
            return timeText(nanosOfDay: nanos)
        case Neo4jStructureTag.time:
            guard ints.count == 2, let nanos = ints[0], let offset = ints[1] else { return nil }
            return timeText(nanosOfDay: nanos) + offsetText(offset)
        case Neo4jStructureTag.localDateTime:
            guard ints.count == 2, let seconds = ints[0], let nanos = ints[1] else { return nil }
            return dateTimeText(localSeconds: seconds, nanos: nanos)
        case Neo4jStructureTag.dateTime, Neo4jStructureTag.legacyDateTime:
            guard ints.count == 3, let seconds = ints[0], let nanos = ints[1], let offset = ints[2] else { return nil }
            let local = tag == Neo4jStructureTag.dateTime ? seconds + offset : seconds
            return dateTimeText(localSeconds: local, nanos: nanos) + offsetText(offset)
        case Neo4jStructureTag.dateTimeZoneId, Neo4jStructureTag.legacyDateTimeZoneId:
            guard fields.count == 3, let seconds = ints[0], let nanos = ints[1],
                  let zoneId = fields[2].stringValue else { return nil }
            let zone = TimeZone(identifier: zoneId)
            let offset: Int64
            if tag == Neo4jStructureTag.dateTimeZoneId {
                offset = Int64(zone?.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(seconds))) ?? 0)
            } else {
                let guess = Int64(zone?.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(seconds))) ?? 0)
                offset = Int64(zone?.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(seconds - guess))) ?? 0)
            }
            let local = tag == Neo4jStructureTag.dateTimeZoneId ? seconds + offset : seconds
            return dateTimeText(localSeconds: local, nanos: nanos) + offsetText(offset) + "[\(zoneId)]"
        case Neo4jStructureTag.duration:
            guard ints.count == 4, let months = ints[0], let days = ints[1],
                  let seconds = ints[2], let nanos = ints[3] else { return nil }
            return durationText(months: months, days: days, seconds: seconds, nanos: nanos)
        case Neo4jStructureTag.point2D, Neo4jStructureTag.point3D:
            guard let srid = ints.first ?? nil else { return nil }
            let names = ["x", "y", "z"]
            let coordinates = fields.dropFirst().enumerated().map { index, field -> String in
                let number: Double
                switch field {
                case .float(let value): number = value
                case .int(let value): number = Double(value)
                default: number = .nan
                }
                return "\(names[min(index, 2)]): \(floatText(number))"
            }
            return "point({srid: \(srid), " + coordinates.joined(separator: ", ") + "})"
        default:
            return nil
        }
    }

    static func dateText(days: Int64) -> String {
        let (year, month, day) = civilDate(daysSinceEpoch: days)
        let yearText: String
        if year < 0 || year > 9_999 {
            yearText = (year < 0 ? "-" : "+") + String(format: "%04lld", abs(year))
        } else {
            yearText = String(format: "%04lld", year)
        }
        return yearText + String(format: "-%02lld-%02lld", month, day)
    }

    static func timeText(nanosOfDay: Int64) -> String {
        let seconds = nanosOfDay / 1_000_000_000
        let nanos = nanosOfDay % 1_000_000_000
        return String(format: "%02lld:%02lld:%02lld", seconds / 3_600, seconds / 60 % 60, seconds % 60)
            + fractionText(nanos)
    }

    static func dateTimeText(localSeconds: Int64, nanos: Int64) -> String {
        let days = floorDivide(localSeconds, 86_400)
        let secondsOfDay = localSeconds - days * 86_400
        return dateText(days: days) + "T" + timeText(nanosOfDay: secondsOfDay * 1_000_000_000 + nanos)
    }

    static func offsetText(_ offsetSeconds: Int64) -> String {
        guard offsetSeconds != 0 else { return "Z" }
        let sign = offsetSeconds < 0 ? "-" : "+"
        let magnitude = abs(offsetSeconds)
        var text = sign + String(format: "%02lld:%02lld", magnitude / 3_600, magnitude / 60 % 60)
        if magnitude % 60 != 0 { text += String(format: ":%02lld", magnitude % 60) }
        return text
    }

    static func durationText(months: Int64, days: Int64, seconds: Int64, nanos: Int64) -> String {
        var text = "P"
        if months / 12 != 0 { text += "\(months / 12)Y" }
        if months % 12 != 0 { text += "\(months % 12)M" }
        if days != 0 { text += "\(days)D" }
        // Seconds and nanoseconds stay apart: their product overflows Int64 for durations Neo4j accepts.
        let carry = floorDivide(nanos, 1_000_000_000)
        let (total, overflow) = seconds.addingReportingOverflow(carry)
        let signedSeconds = overflow ? seconds : total
        var fraction = nanos - carry * 1_000_000_000
        if signedSeconds != 0 || fraction != 0 {
            let negative = signedSeconds < 0
            var wholeSeconds = signedSeconds.magnitude
            if negative, fraction != 0 {
                wholeSeconds -= 1
                fraction = 1_000_000_000 - fraction
            }
            var time = "T"
            if wholeSeconds / 3_600 != 0 { time += (negative ? "-" : "") + "\(wholeSeconds / 3_600)H" }
            if wholeSeconds / 60 % 60 != 0 { time += (negative ? "-" : "") + "\(wholeSeconds / 60 % 60)M" }
            let remainder = wholeSeconds % 60
            if remainder != 0 || fraction != 0 {
                time += (negative ? "-" : "") + "\(remainder)" + fractionText(fraction) + "S"
            }
            text += time
        }
        return text == "P" ? "PT0S" : text
    }

    private static func fractionText(_ nanos: Int64) -> String {
        guard nanos != 0 else { return "" }
        var digits = String(format: "%09lld", nanos)
        while digits.hasSuffix("0") { digits.removeLast() }
        return "." + digits
    }

    private static func floorDivide(_ value: Int64, _ divisor: Int64) -> Int64 {
        let quotient = value / divisor
        return (value % divisor != 0 && (value < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }

    /// Proleptic Gregorian date from days since 1970-01-01 (Howard Hinnant's `civil_from_days`).
    private static func civilDate(daysSinceEpoch: Int64) -> (Int64, Int64, Int64) {
        let shifted = daysSinceEpoch + 719_468
        let era = floorDivide(shifted, 146_097)
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }
}
