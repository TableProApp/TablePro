import Darwin
import TableProCommandLine

@main
struct TableProCLI {
    static func main() async {
        exit(await CommandLineTool.main(arguments: Array(CommandLine.arguments.dropFirst())))
    }
}
