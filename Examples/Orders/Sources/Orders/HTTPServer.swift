// A minimal blocking HTTP/1.1 server on POSIX sockets, so the example needs no web framework.
// It answers requests one at a time; a real service would use Hummingbird or Vapor.
#if canImport(Glibc)
import Glibc
private let streamSocket = Int32(SOCK_STREAM.rawValue)
#else
import Darwin
private let streamSocket = SOCK_STREAM
#endif
import Foundation

struct HTTPRequest {
    var method: String
    var path: String
    /// Header values by lower-cased name.
    var headers: [String: String]
    var body: Data
}

struct HTTPServer {
    var port: Int
    /// The largest request body read; a larger one gets 413.
    var maxBody = 1 << 20

    func run(_ handle: (HTTPRequest) -> (status: Int, contentType: String, body: Data)) throws -> Never {
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
            let (status, type, body) = respond(client, handle)
            let head = "HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Type: \(type)\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            let response = Data(head.utf8) + body
            response.withUnsafeBytes { _ = write(client, $0.baseAddress, $0.count) }
            close(client)
        }
    }

    /// Reads one request: the head up to the blank line ("POST /path HTTP/1.1" and the headers), then
    /// Content-Length bytes of body.
    private func respond(_ client: Int32, _ handle: (HTTPRequest) -> (status: Int, contentType: String, body: Data))
        -> (Int, String, Data)
    {
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        let blank = Array("\r\n\r\n".utf8)
        var headEnd: Int?
        while buffer.count < 65536 {
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { break }
            buffer += chunk.prefix(n)
            if let end = buffer.firstRange(of: blank)?.upperBound { headEnd = end; break }
        }
        guard let headEnd else { return (400, "text/plain", Data("bad request".utf8)) }
        let lines = String(decoding: buffer[..<headEnd], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2 else { return (400, "text/plain", Data("bad request".utf8)) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = headers["content-length"].flatMap { Int($0) } ?? 0
        guard length >= 0, length <= maxBody else { return (413, "text/plain", Data("body too large".utf8)) }
        var body = Data(buffer[headEnd...])
        while body.count < length {
            let n = read(client, &chunk, min(chunk.count, length - body.count))
            if n <= 0 { break }
            body += chunk.prefix(n)
        }
        return handle(HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body.prefix(length)))
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Content Too Large"
        default: "Error"
        }
    }
}
