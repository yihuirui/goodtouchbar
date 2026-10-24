import Foundation
import Darwin

public struct ProcessResult: Sendable {
    public let stdout: Data, stderr: Data
    public let exitCode: Int32
    public let failure: String?
    public let stdoutTruncated: Bool
    public var succeeded: Bool { failure == nil && exitCode == 0 }
}

/// One-shot child in its own process group. Never call run on the UI thread.
/// The group leader is kept unreaped until group cleanup, preventing PID reuse.
public final class BoundedProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func run(executable: String, arguments: [String], timeout: Double,
                    stdoutLimit: Int = 1_048_576, stderrLimit: Int = 16_384) -> ProcessResult {
        func failed(_ code:String) -> ProcessResult { .init(stdout:Data(),stderr:Data(),exitCode:-1,failure:code,stdoutTruncated:false) }
        guard !isCancelled else { return failed("cancelled") }
        var out = [Int32](repeating:-1,count:2), err = out
        guard pipe(&out) == 0 else { return failed("pipe_failed") }
        guard pipe(&err) == 0 else { out.forEach { _ = close($0) }; return failed("pipe_failed") }
        defer { for fd in out + err where fd >= 0 { _ = close(fd) } }
        for fd in out + err { _ = fcntl(fd,F_SETFD,FD_CLOEXEC) }
        var actions: posix_spawn_file_actions_t?, attr: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return failed("spawn_setup_failed") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attr) == 0 else { return failed("spawn_setup_failed") }
        defer { posix_spawnattr_destroy(&attr) }
        guard posix_spawn_file_actions_addopen(&actions,STDIN_FILENO,"/dev/null",O_RDONLY,0) == 0,
              posix_spawn_file_actions_adddup2(&actions,out[1],STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions,err[1],STDERR_FILENO) == 0,
              posix_spawnattr_setflags(&attr,Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attr,0) == 0 else { return failed("spawn_setup_failed") }
        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        var env = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        let code = posix_spawn(&pid,executable,&actions,&attr,&argv,&env)
        guard code == 0 else { return failed("spawn_failed_\(code)") }
        _ = close(out[1]); out[1] = -1; _ = close(err[1]); err[1] = -1
        for fd in [out[0],err[0]] { _ = fcntl(fd,F_SETFL,fcntl(fd,F_GETFL) | O_NONBLOCK) }
        var captured = [Data(),Data()], eof = [false,false], truncated = false
        let limits = [max(0,stdoutLimit),max(0,stderrLimit)]
        let began = ProcessInfo.processInfo.systemUptime, deadline = began + max(0.01,timeout)
        var exitObserved: Double?, failure: String?
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if isCancelled { failure = "cancelled"; break }
            if now >= deadline { failure = "timeout"; break }
            var info = siginfo_t()
            if waitid(P_PID,id_t(pid),&info,WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid {
                if exitObserved == nil { exitObserved = now }
            }
            for (index,fd) in [out[0],err[0]].enumerated() where !eof[index] {
                var buffer = [UInt8](repeating:0,count:8192)
                let n = Darwin.read(fd,&buffer,buffer.count)
                if n > 0 {
                    let space = max(0,limits[index]-captured[index].count)
                    captured[index].append(contentsOf:buffer.prefix(min(n,space)))
                    if index == 0 && n > space { truncated = true }
                } else if n == 0 { eof[index] = true }
                else if errno != EAGAIN && errno != EINTR { failure = "pipe_read_failed"; eof[index] = true }
            }
            if exitObserved != nil && eof.allSatisfy({ $0 }) { break }
            if let exitObserved, now-exitObserved >= 0.5 { failure = "pipe_drain_timeout"; break }
            var fds = [pollfd(fd:eof[0] ? -1 : out[0],events:Int16(POLLIN),revents:0),pollfd(fd:eof[1] ? -1 : err[0],events:Int16(POLLIN),revents:0)]
            _ = poll(&fds,2,20)
        }
        // Also reclaim descendants that outlive a successful script.
        _ = kill(-pid,SIGTERM)
        if exitObserved == nil { usleep(50_000) }
        _ = kill(-pid,SIGKILL)
        var status: Int32 = 0
        var reaped = false
        for _ in 0..<50 {
            let result = waitpid(pid,&status,WNOHANG)
            if result == pid { reaped = true; break }
            if result < 0 && errno != EINTR { break }
            usleep(10_000)
        }
        if !reaped {
            failure = failure ?? "reap_timeout"
            DispatchQueue.global(qos:.utility).async { var s:Int32 = 0; while waitpid(pid,&s,0) < 0 && errno == EINTR {} }
        }
        let exitCode = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return .init(stdout:captured[0],stderr:captured[1],exitCode:exitCode,failure:failure,stdoutTruncated:truncated)
    }
}
