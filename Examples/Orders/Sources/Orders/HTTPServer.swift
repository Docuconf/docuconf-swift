// A minimal blocking HTTP/1.1 server on POSIX sockets, so the example needs no web framework.
// It answers GET requests one at a time; a real service would use Hummingbird or Vapor.
#if canImport(Glibc)
import Glibc
private let streamSocket = Int32(SOCK_STREAM.rawValue)
#else
import Darwin
private let streamSocket = SOCK_STREAM
#endif
import Foundation

struct HTTPServer {
    var port: Int

    func run(_ handle: (String) -> (status: Int, contentType: String, body: Data)) throws -> Never {
        signal(SIGPIPE, SIG_IGN)  // a client that hangs up early must not stop the server
        let fd = socket(AF_INET, streamSocket, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            // Read the request head (up to the blank line); its first line is "GET /path HTTP/1.1".
            var request: [UInt8] = []
            var chunk = [UInt8](repeating: 0, count: 4096)
            while request.count < 65536, !request.ends(with: Array("\r\n\r\n".utf8)) {
                let n = read(client, &chunk, chunk.count)
                if n <= 0 { break }
                request += chunk.prefix(n)
            }
            let requestLine = String(decoding: request, as: UTF8.self).prefix { $0 != "\r" && $0 != "\n" }
            let parts = requestLine.split(separator: " ")
            let (status, type, body) = parts.count >= 2 && parts[0] == "GET"
                ? handle(String(parts[1]))
                : (405, "text/plain", Data("method not allowed".utf8))
            let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : status == 404 ? "Not Found" : "Method Not Allowed")\r\nContent-Type: \(type)\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            let response = Data(head.utf8) + body
            response.withUnsafeBytes { _ = write(client, $0.baseAddress, $0.count) }
            close(client)
        }
    }
}

extension Array where Element: Equatable {
    fileprivate func ends(with suffix: [Element]) -> Bool { count >= suffix.count && Array(self[(count - suffix.count)...]) == suffix }
}
