//  SummaryOperationState.swift
//  Sudrf
//
//  Состояние единственной активной операции загрузки или генерации summary.

import Foundation

enum SummaryOperationKind: Equatable { case load, generate }

struct SummaryOperation: Equatable {
    let id: UUID
    let kind: SummaryOperationKind
    let caseKey: String
    let sourceActID: String
}

struct SummaryOperationState {
    private(set) var current: SummaryOperation?

    func preservesCurrentLoad(caseKey: String, sourceActID: String) -> Bool {
        current?.caseKey == caseKey && current?.sourceActID == sourceActID
    }

    mutating func begin(kind: SummaryOperationKind, caseKey: String,
                        sourceActID: String) -> SummaryOperation {
        let operation = SummaryOperation(
            id: UUID(), kind: kind, caseKey: caseKey, sourceActID: sourceActID)
        current = operation
        return operation
    }

    mutating func finish(_ operation: SummaryOperation) -> Bool {
        guard current == operation else { return false }
        current = nil
        return true
    }

    mutating func cancel() { current = nil }
}
