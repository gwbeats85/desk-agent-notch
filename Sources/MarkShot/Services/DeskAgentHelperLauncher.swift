import Foundation

enum DeskAgentHelperLauncher {
    static let restartLogPath = "/tmp/deskagent-helper-restart.log"

    static func restart(completion: @escaping (Bool) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-lc",
            """
            export PATH="/opt/homebrew/bin:/opt/homebrew/opt/node@22/bin:$PATH"
            cd "$HOME/Workspaces/apps/prototypes/DeskAgent"
            npm run desk:on >\(restartLogPath) 2>&1
            """
        ]
        process.terminationHandler = { process in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                completion(process.terminationStatus == 0)
            }
        }

        do {
            try process.run()
        } catch {
            DispatchQueue.main.async {
                completion(false)
            }
        }
    }
}
