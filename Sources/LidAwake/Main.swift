import Foundation

@main
enum Main {
    static func main() {
        switch WindowSnapshot.folder(from: CommandLine.arguments) {
        case .success(let folder):
            exit(MainActor.assumeIsolated { WindowSnapshot.run(folder: folder) })
        case .failure(let error):
            FileHandle.standardError.write(Data((error.message + "\n").utf8))
            exit(64)
        case nil:
            break
        }
        if CommandLine.arguments.contains(LogCommand.flag) {
            exit(LogCommand.run())
        }
        if CommandLine.arguments.contains(AutoLogoutCommand.flag) {
            exit(AutoLogoutCommand.run())
        }
        if CommandLine.arguments.contains("--check-update") {
            FileHandle.standardError.write(Data("Upstream update checks are disabled in MacStayAwake.\n".utf8))
            exit(64)
        }
        guard let command = HelperCommand(arguments: CommandLine.arguments) else {
            LidAwakeApp.main()
            return
        }
        Task { @MainActor in
            exit(await command.run())
        }
        dispatchMain()
    }
}
