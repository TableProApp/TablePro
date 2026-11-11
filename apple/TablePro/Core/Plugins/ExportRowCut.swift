//
//  ExportRowCut.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// A stream that ends at the engine's ceiling or the driver's declared `rowLimit` wrote a partial file.
// One consumer reads an export stream, so one call at a time reaches the iterator.
final class ExportRowCut<Element: Sendable>: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<Element, Error>.AsyncIterator
    private let engineCeiling: Int?
    private let reading: @Sendable (Element) -> (header: PluginStreamHeader?, rows: Int)
    private var declaredLimit: Int?
    private var rowCount = 0
    private var isSettled = false

    private init(
        upstream: AsyncThrowingStream<Element, Error>,
        engineCeiling: Int?,
        reading: @escaping @Sendable (Element) -> (header: PluginStreamHeader?, rows: Int)
    ) {
        self.iterator = upstream.makeAsyncIterator()
        self.engineCeiling = engineCeiling
        self.reading = reading
    }

    private func next() async throws -> Element? {
        guard let element = try await iterator.next() else { return nil }
        let read = reading(element)
        if let header = read.header { declaredLimit = header.rowLimit }
        rowCount += read.rows
        return element
    }

    private func settle() -> Int? {
        guard !isSettled else { return nil }
        isSettled = true
        return [engineCeiling, declaredLimit].compactMap { $0 }.filter { rowCount >= $0 }.min()
    }

    // Pulled rather than pumped by a task of its own, which kept every row a slow writer had not taken yet.
    static func reporting(
        _ upstream: AsyncThrowingStream<Element, Error>,
        engineCeiling: Int?,
        reading: @escaping @Sendable (Element) -> (header: PluginStreamHeader?, rows: Int),
        onCut: @escaping @Sendable (Int) -> Void
    ) -> AsyncThrowingStream<Element, Error> {
        let cut = ExportRowCut(upstream: upstream, engineCeiling: engineCeiling, reading: reading)
        return AsyncThrowingStream(unfolding: {
            guard let element = try await cut.next() else {
                if let limit = cut.settle() { onCut(limit) }
                return nil
            }
            return element
        })
    }
}

extension ExportRowCut where Element == PluginStreamElement {
    static func reporting(
        _ upstream: AsyncThrowingStream<PluginStreamElement, Error>,
        engineCeiling: Int?,
        onCut: @escaping @Sendable (Int) -> Void
    ) -> AsyncThrowingStream<PluginStreamElement, Error> {
        reporting(upstream, engineCeiling: engineCeiling, reading: { element in
            switch element {
            case .header(let header): return (header, 0)
            case .rows(let rows): return (nil, rows.count)
            }
        }, onCut: onCut)
    }
}

extension ExportRowCut where Element == PluginExportStreamElement {
    static func reporting(
        _ upstream: AsyncThrowingStream<PluginExportStreamElement, Error>,
        engineCeiling: Int?,
        onCut: @escaping @Sendable (Int) -> Void
    ) -> AsyncThrowingStream<PluginExportStreamElement, Error> {
        reporting(upstream, engineCeiling: engineCeiling, reading: { element in
            if case .header(let header) = element { return (header, 0) }
            if case .rows(let rows, _) = element { return (nil, rows.count) }
            return (nil, 0)
        }, onCut: onCut)
    }
}
