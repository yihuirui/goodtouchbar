import Foundation
import Darwin

/// Bounds legacy launchd stdout/stderr without renaming its still-open log inode.
public final class StandardStreamLogLimiter {
    public static let shared = StandardStreamLogLimiter()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label:"io.github.yihuirui.goodtouchbar.stream-log",qos:.utility)
    private init() {}
    public func start() {
        guard timer == nil else { return }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/GoodTouchBar")
        let timer = DispatchSource.makeTimerSource(queue:queue)
        timer.schedule(deadline:.now(),repeating:60,leeway:.seconds(5))
        timer.setEventHandler {
            for (fd,name) in [(STDOUT_FILENO,"stdout.log"),(STDERR_FILENO,"stderr.log")] {
                Self.limit(descriptor:fd,path:directory.appendingPathComponent(name).path)
            }
        }
        self.timer = timer; timer.resume()
    }
    public static func limit(descriptor:Int32,path:String,maximum:Int = 1_048_576) {
        guard maximum > 0 else { return }
        var opened = stat(), named = stat(), parent = stat()
        let directory = URL(fileURLWithPath:path).deletingLastPathComponent().path
        guard lstat(directory,&parent) == 0, parent.st_mode & S_IFMT == S_IFDIR, parent.st_uid == getuid(),
              fstat(descriptor,&opened) == 0, lstat(path,&named) == 0,
              opened.st_mode & S_IFMT == S_IFREG, named.st_mode & S_IFMT == S_IFREG,
              opened.st_uid == getuid(), opened.st_nlink == 1, opened.st_size > maximum,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else { return }
        let reader = open(path,O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard reader >= 0 else { return }; defer { close(reader) }
        var readStat = stat()
        guard fstat(reader,&readStat) == 0, readStat.st_ino == opened.st_ino, readStat.st_dev == opened.st_dev else { return }
        var bytes = [UInt8](repeating:0,count:maximum)
        let n = pread(reader,&bytes,maximum,opened.st_size-off_t(maximum))
        guard n > 0 else { return }
        let temporary = directory + "/.stream-log-" + UUID().uuidString
        let backup = open(temporary,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard backup >= 0 else { return }
        defer { close(backup); unlink(temporary) }
        let wrote = bytes.withUnsafeBytes { Darwin.write(backup,$0.baseAddress,n) }
        guard wrote == n, rename(temporary,path + ".previous") == 0 else { return }
        if ftruncate(descriptor,0) == 0 { _ = lseek(descriptor,0,SEEK_END) }
    }
}
