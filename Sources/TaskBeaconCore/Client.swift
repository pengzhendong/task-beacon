import Foundation
import Darwin

public struct TaskBeaconClient: Sendable {
    public let socketPath: String
    public let timeout: TimeInterval

    public init(socketPath: String = RuntimePaths.socketPath, timeout: TimeInterval = 5) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    public func send(_ request: WireRequest) throws -> WireResponse {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TaskBeaconError.connection("cannot create socket") }
        defer { close(descriptor) }
        var interval = timeval(tv_sec: Int(max(1, timeout)), tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        var suppressBrokenPipe: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &suppressBrokenPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw TaskBeaconError.connection("socket path is too long")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            let bytes = socketPath.utf8CString
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
                _ = bytes.withUnsafeBufferPointer { source in
                    memcpy(destination, source.baseAddress!, source.count)
                }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw TaskBeaconError.connection("TaskBeacon service is not running at \(socketPath)")
        }

        var payload = try JSONCoding.encoder().encode(request)
        payload.append(0x0A)
        try payload.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw TaskBeaconError.connection("failed to write request") }
                offset += count
            }
        }
        shutdown(descriptor, SHUT_WR)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw TaskBeaconError.connection("failed to read response") }
            response.append(contentsOf: buffer[0..<count])
        }
        guard !response.isEmpty else { throw TaskBeaconError.connection("empty response from service") }
        return try JSONCoding.decoder().decode(WireResponse.self, from: response)
    }
}
