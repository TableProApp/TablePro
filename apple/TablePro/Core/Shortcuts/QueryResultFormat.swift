//
//  QueryResultFormat.swift
//  TablePro
//

import AppIntents
import Foundation

internal enum QueryResultFormat: String, AppEnum {
    case rows
    case firstValue
    case csv
    case json

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Result Format")
    static let caseDisplayRepresentations: [QueryResultFormat: DisplayRepresentation] = [
        .rows: DisplayRepresentation(title: "Rows", subtitle: "A dictionary for each row, keyed by column"),
        .firstValue: DisplayRepresentation(title: "First Value", subtitle: "The first column of the first row"),
        .csv: DisplayRepresentation(title: "CSV"),
        .json: DisplayRepresentation(title: "JSON")
    ]
}
