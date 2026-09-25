import Foundation
import AppKit
import SwiftTerm

/// Owns the PTY lifetime so closing tabs releases descriptors and reaps children.
/// DispatchIO owns the descriptor; it is closed only in its cleanup handler.
final class PTYProcess {
    private(set) var childfd: Int32 = -1
    private(set) var shellPid: pid_t = 0
    private(set) var running = false
    var onData: (([UInt8]) -> Void)?
    var onExit: ((Int32?) -> Void)?
    private var io: DispatchIO?
    private var monitor: DispatchSourceProcess?
    private var exitStatus: Int32?
    private var hasExited = false
    private var readEnded = false
    private var deliveredExit = false
    private var pendingInput: [UInt8] = []
    private var writing = false
    private let cleanupQueue = DispatchQueue(label: "app.echoterm.pty.cleanup")

    func startProcess(executable: String, args: [String], environment: [String], currentDirectory: String, size: winsize) {
        guard !running else { return }
        var dimensions = size
        guard let result = PseudoTerminalHelpers.fork(andExec: executable, args: [executable] + args, env: environment, currentDirectory: currentDirectory, desiredWindowSize: &dimensions) else {
            onExit?(nil); return
        }
        shellPid = result.pid; childfd = result.masterFd; running = true
        let descriptor = result.masterFd
        let channel = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: cleanupQueue) { _ in Darwin.close(descriptor) }
        io = channel
        channel.setLimit(lowWater: 1)
        channel.setLimit(highWater: 65536)
        channel.read(offset: 0, length: Int.max, queue: .main) { [weak self] done, data, _ in
            guard let self, !self.deliveredExit else { return }
            if let data, !data.isEmpty { self.onData?(Array(data)) }
            if done { self.readEnded = true; if self.hasExited { self.finish() } }
        }
        let watcher = DispatchSource.makeProcessSource(identifier: result.pid, eventMask: .exit, queue: .main)
        monitor = watcher
        // The watcher retains us until the child is reaped, including after its tab closes.
        watcher.setEventHandler { [self] in
            var status: Int32 = 0
            let reaped = waitpid(shellPid, &status, WNOHANG)
            exitStatus = reaped > 0 ? ((status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)) : nil
            hasExited = true; running = false
            monitor?.cancel(); monitor = nil
            if readEnded { finish() }
            else {
                // Drain already queued output; don't wait forever for detached grandchildren
                // that may retain a copy of the slave terminal.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in finish() }
            }
        }
        watcher.resume()
    }
    func send(data: ArraySlice<UInt8>) {
        guard running else { return }
        pendingInput.append(contentsOf: data)
        drainInput()
    }
    private func drainInput() {
        guard !writing, !pendingInput.isEmpty, running, let io else { return }
        writing = true
        let bytes = pendingInput
        pendingInput.removeAll(keepingCapacity: true)
        bytes.withUnsafeBytes { buffer in
            let dispatchData = DispatchData(bytes: buffer)
            io.write(offset: 0, data: dispatchData, queue: .main) { [weak self] done, _, _ in
                guard done, let self else { return }
                self.writing = false
                self.drainInput()
            }
        }
    }
    func stop() {
        guard running, shellPid > 0 else { return }
        let foreground = tcgetpgrp(childfd)
        if foreground > 0 && foreground != getpgrp() { kill(-foreground, SIGHUP) }
        kill(shellPid, SIGHUP)
        io?.close(flags: .stop)
    }
    private func finish() {
        guard !deliveredExit else { return }
        deliveredExit = true; running = false
        pendingInput.removeAll()
        io?.close(flags: .stop); io = nil; childfd = -1
        onExit?(exitStatus)
        onData = nil; onExit = nil
    }
}
