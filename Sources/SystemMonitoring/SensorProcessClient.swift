import Foundation
import Darwin

public enum SensorClientError: Error { case unavailable, invalidResponse, timedOut, cancelled }

/// One request at a time; nonblocking POSIX reads return short pipe frames immediately.
public final class SensorProcessClient: @unchecked Sendable {
    private let requestLock = NSLock(), lock = NSLock()
    private let executable: URL
    private let event: (String, [String:Int]) -> Void
    private var child: Process?
    private var input: FileHandle?, output: FileHandle?
    private var pending = Data()
    private var launches = 0, samples = 0
    public init(executable: URL, event: @escaping (String, [String:Int]) -> Void = { _,_ in }) {
        self.executable = executable; self.event = event
        signal(SIGPIPE, SIG_IGN)
    }
    deinit { stop() }
    public func stop() {
        lock.lock()
        let process = child; child = nil
        let stdin = input, stdout = output; input = nil; output = nil
        try? stdin?.close(); try? stdout?.close()
        lock.unlock()
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
    public func sample(_ request: SensorRequest, timeout: TimeInterval = 2) throws -> SensorResponse {
        requestLock.lock(); defer { requestLock.unlock() }
        let began = ProcessInfo.processInfo.systemUptime
        let deadline = began + max(0.01, timeout)
        let bytes = try JSONEncoder().encode(request) + Data([10])
        guard bytes.count <= 4096 else { throw SensorClientError.invalidResponse }
        lock.lock()
        if child == nil {
            let process = Process(), stdin = Pipe(), stdout = Pipe()
            process.executableURL = executable; process.standardInput = stdin; process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { lock.unlock(); throw error }
            child = process; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; pending = Data()
            for fd in [input!.fileDescriptor, output!.fileDescriptor] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
            launches += 1; event("sensor_process_started", ["launches":launches,"pid":Int(process.processIdentifier)])
        }
        let process = child!
        lock.unlock()
        do {
            var sent = 0
            while true {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw SensorClientError.timedOut }
                lock.lock()
                guard child === process, let stdin = input, let stdout = output else { lock.unlock(); throw SensorClientError.cancelled }
                if sent < bytes.count {
                    let n = bytes.withUnsafeBytes { Darwin.write(stdin.fileDescriptor, $0.baseAddress!.advanced(by:sent), bytes.count-sent) }
                    if n > 0 { sent += n }
                    else if n < 0 && errno != EAGAIN && errno != EINTR { lock.unlock(); throw SensorClientError.unavailable }
                }
                var buffer = [UInt8](repeating:0,count:8192)
                let n = Darwin.read(stdout.fileDescriptor, &buffer, buffer.count)
                let code = errno, fd = stdout.fileDescriptor
                lock.unlock()
                if n > 0 {
                    guard pending.count + n <= 65_536 else { throw SensorClientError.invalidResponse }
                    pending.append(contentsOf:buffer.prefix(n))
                } else if n == 0 { throw SensorClientError.unavailable }
                else if code != EAGAIN && code != EINTR { throw SensorClientError.unavailable }
                if let newline = pending.firstIndex(of:10) {
                    let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                    let response = try JSONDecoder().decode(SensorResponse.self,from:line)
                    lock.lock(); let current = child === process; lock.unlock()
                    guard current else { throw SensorClientError.cancelled }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw SensorClientError.timedOut }
                    guard response.version == 1, response.requestID == request.requestID, abs(response.sampledAt.timeIntervalSinceNow) < 10 else { throw SensorClientError.invalidResponse }
                    samples += 1
                    if samples == 1 || samples % 60 == 0 { event("sensor_sample", ["samples":samples,"elapsed_ms":Int((ProcessInfo.processInfo.systemUptime-began)*1000),"launches":launches]) }
                    return response
                }
                var descriptor = pollfd(fd:fd,events:Int16(POLLIN),revents:0)
                _ = poll(&descriptor,1,20)
            }
        } catch {
            stop()
            let code = (error as? SensorClientError).map { String(describing:$0) } ?? "invalidResponse"
            event("sensor_request_" + code,["elapsed_ms":Int((ProcessInfo.processInfo.systemUptime-began)*1000),"launches":launches])
            throw error
        }
    }
}
