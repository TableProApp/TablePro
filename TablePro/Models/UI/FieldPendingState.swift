//
//  FieldPendingState.swift
//  TablePro

enum FieldPendingState: Equatable {
    case null
    case `default`
    case sqlFunction(String)
}
