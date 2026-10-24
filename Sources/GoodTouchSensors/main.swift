import Foundation
import SystemMonitoring

let reader = SMCReader()
let decoder = JSONDecoder(), encoder = JSONEncoder()
// stdin/stdout are private pipes owned by the parent App. No network, commands or SMC writes.
while let line = readLine() {
    guard line.utf8.count <= 4096, let data = line.data(using: .utf8),
          let request = try? decoder.decode(SensorRequest.self, from: data), request.version == 1 else { break }
    let response = reader.sample(request)
    guard let data = try? encoder.encode(response) else { break }
    FileHandle.standardOutput.write(data + Data([10]))
}
