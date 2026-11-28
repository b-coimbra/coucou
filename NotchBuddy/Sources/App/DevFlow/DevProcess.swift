#if !APPSTORE
import Foundation

/// One run of a command-line tool (git, gh, lsappinfo) with its arguments as an array, no shell, and a
/// time limit. Blocking: call it off the main thread.
enum DevProcess {
    struct Result: Sendable {
        let status: Int32
        let stdout: Data
        let timedOut: Bool
        var succeeded: Bool { !timedOut && status == 0 }
        var text: String { String(decoding: stdout, as: UTF8.self) }
    }

    /// One run's process and output, handed between the queues that drive it.
    private final class Run: @unchecked Sendable {
        let process = Process()
        let output = Pipe()
        var data = Data()
    }

    /// nil when the tool couldn't be started. Its error output is dropped, never logged.
    static func run(_ executable: String, _ arguments: [String],
                    environment: [String: String], timeout: TimeInterval) -> Result? {
        let run = Run()
        run.process.executableURL = URL(fileURLWithPath: executable)
        run.process.arguments = arguments
        run.process.environment = environment
        run.process.standardInput = FileHandle.nullDevice
        run.process.standardOutput = run.output
        run.process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        let read = DispatchSemaphore(value: 0)
        run.process.terminationHandler = { _ in exited.signal() }
        do { try run.process.run() } catch { return nil }
        DispatchQueue.global(qos: .utility).async {
            // readToEnd() throws a Swift error where readDataToEndOfFile() raises an
            // Objective-C exception.
            run.data = (try? run.output.fileHandleForReading.readToEnd()) ?? Data()
            read.signal()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            run.process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(run.process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        // A child of the tool may still hold the pipe open: not waited for beyond this.
        guard read.wait(timeout: .now() + 2) == .success else {
            return Result(status: -1, stdout: Data(), timedOut: true)
        }
        let status = run.process.isRunning ? -1 : run.process.terminationStatus
        return Result(status: status, stdout: run.data, timedOut: timedOut)
    }
}
#endif
