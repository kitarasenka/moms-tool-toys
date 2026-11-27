import AppKit
import Darwin
import Foundation

enum ProcessAction: Sendable {
    case terminate, forceQuit, suspend, resume

    var signal: Int32 {
        switch self {
        case .terminate: SIGTERM
        case .forceQuit: SIGKILL
        case .suspend: SIGSTOP
        case .resume: SIGCONT
        }
    }

    var signalName: String {
        switch self {
        case .terminate: "TERM"
        case .forceQuit: "KILL"
        case .suspend: "STOP"
        case .resume: "CONT"
        }
    }

    var title: String {
        switch self {
        case .terminate: String(localized: "Завершить")
        case .forceQuit: String(localized: "Завершить принудительно")
        case .suspend: String(localized: "Приостановить")
        case .resume: String(localized: "Продолжить")
        }
    }

    var needsConfirmation: Bool { self == .terminate || self == .forceQuit }
}

/// Процессы, которые убивать нельзя: ядро и launchd (убийство launchd = паника системы).
let protectedPIDs: Set<pid_t> = [0, 1]

enum ProcessControl {
    struct Outcome {
        var denied: [pid_t] = []
        var failed: [(pid_t, String)] = []
    }

    @MainActor
    static func send(_ action: ProcessAction, to pids: [pid_t]) -> Outcome {
        var outcome = Outcome()
        for pid in pids where !protectedPIDs.contains(pid) {
            // Приложениям сначала даём корректно закрыться (сохранить документы), как делает Dock.
            if action == .terminate,
               let app = NSRunningApplication(processIdentifier: pid),
               app.activationPolicy == .regular,
               app.terminate() {
                continue
            }
            if kill(pid, action.signal) != 0 {
                let err = errno
                switch err {
                case EPERM: outcome.denied.append(pid)
                case ESRCH: break // уже завершился
                default: outcome.failed.append((pid, String(cString: strerror(err))))
                }
            }
        }
        return outcome
    }

    static func sendAsAdmin(_ action: ProcessAction, to pids: [pid_t]) async throws {
        let list = pids.filter { !protectedPIDs.contains($0) }.map(String.init).joined(separator: " ")
        guard !list.isEmpty else { return }
        _ = try await AdminRunner.run("/bin/kill -\(action.signalName) \(list)")
    }
}

/// Выполняет shell-команду от root через стандартный системный запрос пароля.
/// В команду подставляются только числа (PID) и фиксированные строки — инъекция невозможна.
enum AdminRunner {
    enum Failure: LocalizedError {
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: String(localized: "Операция отменена")
            case .failed(let msg): msg
            }
        }
    }

    static func run(_ shell: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let script = "do shell script \"\(shell)\" with administrator privileges without altering line endings"
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", script]
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch {
                    cont.resume(throwing: error)
                    return
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    cont.resume(returning: String(decoding: data, as: UTF8.self))
                } else {
                    let msg = String(decoding: errData, as: UTF8.self)
                    cont.resume(throwing: msg.contains("-128") ? Failure.cancelled : Failure.failed(msg.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
        }
    }
}
