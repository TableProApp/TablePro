//
//  MainSplitViewController+QueryMenuActions.swift
//  TablePro
//

import AppKit

extension MainSplitViewController {
    @objc func executeQuery(_ sender: Any?) {
        commandActions?.runQuery()
    }

    @objc func executeAllStatements(_ sender: Any?) {
        commandActions?.runAllStatements()
    }

    @objc func executeQueryWithoutLimit(_ sender: Any?) {
        commandActions?.runQueryWithoutLimit()
    }

    @objc func cancelQuery(_ sender: Any?) {
        commandActions?.cancelCurrentQuery()
    }

    @objc func explainQuery(_ sender: Any?) {
        commandActions?.explainQuery()
    }

    @objc func formatQuery(_ sender: Any?) {
        commandActions?.formatQuery()
    }

    @objc func toggleFold(_ sender: Any?) {
        commandActions?.toggleFold()
    }

    @objc func foldAll(_ sender: Any?) {
        commandActions?.foldAll()
    }

    @objc func unfoldAll(_ sender: Any?) {
        commandActions?.unfoldAll()
    }

    @objc func goToPreviousStatement(_ sender: Any?) {
        commandActions?.goToPreviousStatement()
    }

    @objc func goToNextStatement(_ sender: Any?) {
        commandActions?.goToNextStatement()
    }

    @objc func runStatementAndAdvance(_ sender: Any?) {
        commandActions?.runStatementAndAdvance()
    }

    @objc func previewSQL(_ sender: Any?) {
        commandActions?.previewSQL()
    }

    @objc func saveAsFavorite(_ sender: Any?) {
        commandActions?.saveAsFavorite()
    }

    @objc func previewFKReference(_ sender: Any?) {
        commandActions?.previewFKReference()
    }

    @objc func goToFirstPage(_ sender: Any?) {
        commandActions?.goToFirstPage()
    }

    @objc func goToPreviousPage(_ sender: Any?) {
        commandActions?.goToPreviousPage()
    }

    @objc func goToNextPage(_ sender: Any?) {
        commandActions?.goToNextPage()
    }

    @objc func goToLastPage(_ sender: Any?) {
        commandActions?.goToLastPage()
    }

    @objc func explainQueryWithAI(_ sender: Any?) {
        commandActions?.aiExplainQuery()
    }

    @objc func optimizeQueryWithAI(_ sender: Any?) {
        commandActions?.aiOptimizeQuery()
    }

    @objc func selectNumberedTab(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        commandActions?.selectTab(number: item.tag)
    }
}
