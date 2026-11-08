import ArgumentParser
import Foundation

struct CompletionCommand: ParsableCommand, CLIRunnable {
    static let configuration = CommandConfiguration(
        commandName: "completion",
        abstract: "Print a shell completion script.",
        discussion: """
        zsh:  tablepro completion zsh > "${fpath[1]}/_tablepro"
        bash: tablepro completion bash > /usr/local/etc/bash_completion.d/tablepro
        fish: tablepro completion fish > ~/.config/fish/completions/tablepro.fish
        """
    )

    @Argument(help: ArgumentHelp("bash, zsh or fish.", valueName: "shell"))
    var shell: CLIShell

    func run(in session: CLISession) async throws {
        let script = TableProCommand.completionScript(for: shell.completionShell)
        session.console.out(script.hasSuffix("\n") ? script : script + "\n")
    }
}
