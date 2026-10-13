import ArgumentParser
import Darwin
import Foundation

private let screenCommanderBanner = """
                                 ███████╗ ██████╗██████╗ ███████╗███████╗███╗   ██╗
                                 ██╔════╝██╔════╝██╔══██╗██╔════╝██╔════╝████╗  ██║
                                 ███████╗██║     ██████╔╝█████╗  █████╗  ██╔██╗ ██║
                                 ╚════██║██║     ██╔══██╗██╔══╝  ██╔══╝  ██║╚██╗██║
                                 ███████║╚██████╗██║  ██║███████╗███████╗██║ ╚████║
                                 ╚══════╝ ╚═════╝╚═╝  ╚═╝╚══════╝╚══════╝╚═╝  ╚═══╝

                     ██████╗ ██████╗ ███╗   ███╗███╗   ███╗ █████╗ ███╗   ██╗██████╗ ███████╗██████╗
                    ██╔════╝██╔═══██╗████╗ ████║████╗ ████║██╔══██╗████╗  ██║██╔══██╗██╔════╝██╔══██╗
                    ██║     ██║   ██║██╔████╔██║██╔████╔██║███████║██╔██╗ ██║██║  ██║█████╗  ██████╔╝
                    ██║     ██║   ██║██║╚██╔╝██║██║╚██╔╝██║██╔══██║██║╚██╗██║██║  ██║██╔══╝  ██╔══██╗
                    ╚██████╗╚██████╔╝██║ ╚═╝ ██║██║ ╚═╝ ██║██║  ██║██║ ╚████║██████╔╝███████╗██║  ██║
                     ╚═════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═════╝ ╚══════╝╚═╝  ╚═╝

════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════

"""

/// The banner goes only to an interactive terminal wide enough to hold it, and
/// never when JSON output is requested.
private func shouldPrintBanner() -> Bool {
    guard isatty(STDOUT_FILENO) == 1 else {
        return false
    }
    if OutputOptions.preScanned.output?.trimmingCharacters(in: .whitespaces).lowercased() == "json" {
        return false
    }
    var size = winsize()
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else {
        return false
    }
    let bannerWidth = screenCommanderBanner.split(separator: "\n").map(\.count).max() ?? 0
    return Int(size.ws_col) >= bannerWidth
}

/// True when argv names a subcommand. Otherwise ArgumentParser falls back to the
/// default subcommand, `screenshot`.
private func namesSubcommand(_ arguments: [String]) -> Bool {
    let commandNames = Set(RootCommand.configuration.subcommands.compactMap { $0.configuration.commandName } + ["help"])
    return arguments.contains(where: commandNames.contains)
}

/// ArgumentParser reports an unknown root-level flag (`screencommander --bogus`)
/// against the default subcommand's usage. When no subcommand is named, report it
/// against the root command instead.
private func rootLevelUnknownOption(_ error: Error, arguments: [String]) -> String? {
    guard !namesSubcommand(arguments) else {
        return nil
    }
    let message = RootCommand.message(for: error)
    guard message.hasPrefix("Unknown option"), let end = message.firstIndex(of: ".") else {
        return nil
    }
    return String(message[..<end])
}

let arguments = Array(CommandLine.arguments.dropFirst())
OutputOptions.preScan(CommandLine.arguments)
let isRootHelpInvocation = arguments.count == 1 && ["--help", "-h", "help"].contains(arguments[0])
if isRootHelpInvocation, shouldPrintBanner() {
    print(screenCommanderBanner)
}
// `--version` is a root flag. Answer it here so it never falls through to the
// default subcommand and takes a screenshot.
if arguments.contains("--version"), !namesSubcommand(arguments) {
    print(ScreenCommanderVersion.current)
    exit(0)
}

let parsed: ParsableCommand
do {
    parsed = try RootCommand.parseAsRoot(arguments)
} catch {
    // With JSON output asked for, a parse error is one JSON error object too.
    if let envelope = OutputOptions.parseErrorEnvelope(for: error, arguments: arguments) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = OutputOptions.preScanned.compact ? [.sortedKeys] : [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(envelope), let json = String(data: data, encoding: .utf8) {
            print(json)
        }
        exit(envelope.exitCode)
    }
    if let unknown = rootLevelUnknownOption(error, arguments: arguments) {
        let text = "Error: \(unknown).\nUsage: \(RootCommand.usageString())\n  See 'screencommander --help' for more information.\n"
        FileHandle.standardError.write(Data(text.utf8))
        exit(ExitCode.validationFailure.rawValue)
    }
    RootCommand.exit(withError: error)
}

do {
    var command = parsed
    try command.run()
} catch {
    if let unknown = rootLevelUnknownOption(error, arguments: arguments) {
        let text = "Error: \(unknown).\nUsage: \(RootCommand.usageString())\n  See 'screencommander --help' for more information.\n"
        FileHandle.standardError.write(Data(text.utf8))
        exit(ExitCode.validationFailure.rawValue)
    }
    RootCommand.exit(withError: error)
}
