import Foundation

enum CoverageError: LocalizedError, Equatable {
    case noServer
    case noToken
    case badToken
    case noLog
    case noLogDevices
    case unreachable
    case portClosed(Int)
    case wrongPort(Int)
    case legacyOff
    case database
    case noDevEUI(String)
    case insecure
    case server(Int)
    case notCoverage

    var errorDescription: String? {
        switch self {
        case .noServer: "Bitte einen Server eintragen."
        case .noToken: "Bitte das Upload-Token eintragen."
        case .badToken: "Token falsch, der Server lehnt es ab (HTTP 401/403). Upload- oder Admin-Token des Servers eintragen."
        case .noLog: "Auf dem Server gibt es noch kein Coverage-Log, oder das ioBroker-Skript ist nicht aktuell (HTTP 404)."
        case .noLogDevices: "Der Server hat für die bekannten Tester noch keine Uplinks (HTTP 404). DevEUI im Tester und in der Geräteliste des Servers prüfen."
        case .unreachable: "Server nicht erreichbar. Heim-WLAN, IP-Adresse und die Freigabe „Lokales Netzwerk“ in den iOS-Einstellungen prüfen."
        case .portClosed(let port): "Am Port \(port) antwortet nichts. Port prüfen: LoRaScout Server 8090, ioBroker 8099."
        case .wrongPort(let port): "Am Port \(port) läuft weder der LoRaScout Server noch das ioBroker-Skript. Port prüfen: LoRaScout Server 8090, ioBroker 8099."
        case .legacyOff: "Im LoRaScout Server sind die Endpunkte für App und Tester abgeschaltet ([legacy] enabled in der Server-Konfiguration)."
        case .database: "Der LoRaScout Server meldet einen Datenbankfehler (HTTP 503)."
        case .noDevEUI(let name): "Die DevEUI von \(name) ist noch unbekannt. Tester einmal verbinden, bis Konfig seine Werte zeigt."
        case .insecure: "Unverschlüsseltes http geht nur im lokalen Netz: IP-Adresse, Rechnername oder .local verwenden."
        case .server(let code): "Server-Fehler (HTTP \(code))."
        case .notCoverage: "Die Daten enthalten keine gültigen Coverage-Zeilen."
        }
    }

    init(_ error: URLError, port: Int) {
        switch error.code {
        case .appTransportSecurityRequiresSecureConnection: self = .insecure
        case .cannotConnectToHost: self = .portClosed(port)
        default: self = .unreachable
        }
    }
}

/// What answers at host and port. The LoRaScout Server has /healthz, the ioBroker script doesn't.
enum ServerKind: Codable, Equatable {
    case lorascout(version: String)
    case legacy

    var title: String {
        switch self {
        case .lorascout(let version): version.isEmpty ? "LoRaScout Server" : "LoRaScout Server \(version)"
        case .legacy: "ioBroker (altes Skript)"
        }
    }

    /// Only the new server knows devices. It hides deleted rows and keeps them in its database.
    var perDevice: Bool { self != .legacy }
}

struct ServerEndpoint: Codable, Equatable {
    var base: URL
    var port: Int
    var kind: ServerKind
}

enum CoverageClient {
    static let newPort = 8090
    static let legacyPort = 8099

    /// Accepts the device's server value (full URL, `host:port/path` or a bare IP). Only host, port and scheme are used.
    static func base(server: String) -> URLComponents? {
        let text = server.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        guard var parts = URLComponents(string: text.contains("://") ? text : "http://" + text),
              parts.host?.isEmpty == false else { return nil }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts
    }

    /// The part of the device's server value worth showing and editing.
    static func hostText(server: String) -> String { base(server: server)?.host ?? server }

    /// Port field, else a port in the host text, else automatic: 8090, then 8099.
    static func ports(server: String, port: String) -> [Int] {
        if let fixed = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(fixed) { return [fixed] }
        if let fixed = base(server: server)?.port { return [fixed] }
        return [newPort, legacyPort]
    }

    /// GET /healthz without token: JSON with "ok" is the new server, any other HTTP answer the ioBroker script.
    /// A refused connection tries the next port, so a saved host without port keeps working with ioBroker on 8099.
    static func detect(server: String, port: String) async throws -> ServerEndpoint {
        guard let parts = base(server: server) else { throw CoverageError.noServer }
        let candidates = ports(server: server, port: port)
        for candidate in candidates {
            var withPort = parts
            withPort.port = candidate
            guard let base = withPort.url else { throw CoverageError.noServer }
            do {
                let (status, data) = try await request(base.appending(path: "healthz"), method: "GET", token: nil,
                                                       port: candidate, timeout: 5)
                if let kind = health(status: status, data: data) { return ServerEndpoint(base: base, port: candidate, kind: kind) }
                if status == 503, (try? JSONSerialization.jsonObject(with: data)) is [String: Any] { throw CoverageError.database }
                return ServerEndpoint(base: base, port: candidate, kind: .legacy)
            } catch CoverageError.portClosed {
                continue
            }
        }
        throw candidates.count == 1 ? CoverageError.portClosed(candidates[0]) : CoverageError.unreachable
    }

    /// The /healthz answer of the LoRaScout Server, nil for anything else.
    static func health(status: Int, data: Data) -> ServerKind? {
        guard status == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool == true else { return nil }
        return .lorascout(version: object["version"] as? String ?? "")
    }

    /// Legacy: the whole log as before. New server: one request per DevEUI, each row gets the DevEUI as tenth column,
    /// so the merge gives it only to that tester. Without any known DevEUI the server's default device, like legacy.
    static func fetch(_ endpoint: ServerEndpoint, token: String, devEUIs: [String]) async throws -> (data: Data, counts: [String: Int]) {
        guard endpoint.kind.perDevice, !devEUIs.isEmpty else {
            return (try await send(endpoint, path: "coverage", method: "GET", token: token), [:])
        }
        var parts: [(devEUI: String, data: Data)] = []
        var counts: [String: Int] = [:]
        for devEUI in devEUIs {
            do {
                let data = try await send(endpoint, path: "coverage", device: devEUI, method: "GET", token: token)
                parts.append((devEUI, data))
            } catch CoverageError.noLog {
                counts[devEUI] = 0
            }
        }
        let data = tagged(parts)
        for part in parts { counts[part.devEUI] = CoverageMerge.parseCSV(part.data).count }
        guard !parts.isEmpty else { throw CoverageError.noLogDevices }
        return (data, counts)
    }

    /// One coverage file with the DevEUI as tenth column of every row of its answer. The server's
    /// receiving gateways (`via=1`, tenth column there) move behind it, so they end up eleventh.
    static func tagged(_ parts: [(devEUI: String, data: Data)]) -> Data {
        let lines = parts.flatMap { part in
            CoverageMerge.parseCSV(part.data).map { Array($0.prefix(9)) + [part.devEUI] + $0.dropFirst(9) }
        }
        return Data(lines.map { $0.map { CoverageMerge.quoted($0) }.joined(separator: ",") + "\n" }.joined().utf8)
    }

    /// Checks the token: 200 or "no coverage log" means accepted, the token is checked first.
    static func checkToken(_ endpoint: ServerEndpoint, token: String) async throws {
        do {
            _ = try await send(endpoint, path: "coverage", method: "GET", token: token)
        } catch CoverageError.noLog {}
    }

    /// Legacy: removes coverage log and uploaded device log. New server: hides the rows of this device from
    /// /coverage and deletes its uploaded file, the database keeps the data.
    static func deleteLogs(_ endpoint: ServerEndpoint, token: String, devEUI: String?) async throws {
        do {
            _ = try await send(endpoint, path: "logs", device: endpoint.kind.perDevice ? devEUI : nil, method: "DELETE", token: token)
        } catch CoverageError.noLog {
            throw CoverageError.server(404)  // only an old script answers 404 here
        }
    }

    private static func send(_ endpoint: ServerEndpoint, path: String, device: String? = nil, method: String, token: String) async throws -> Data {
        // The ioBroker script compares the whole URL, so never a query for it.
        var url = endpoint.base.appending(path: path)
        // via=1: the LoRaScout server adds the receiving gateways, older versions ignore it.
        if let device { url.append(queryItems: [URLQueryItem(name: "device", value: device), URLQueryItem(name: "via", value: "1")]) }
        let (status, data) = try await request(url, method: method, token: token, port: endpoint.port, timeout: 10)
        switch status {
        case 200: return data
        case 401, 403: throw CoverageError.badToken
        case 404:
            let text = String(decoding: data.prefix(64), as: UTF8.self)
            if text.hasPrefix("no coverage log") { throw CoverageError.noLog }
            // An ioBroker script from before /coverage answers "not found".
            if !endpoint.kind.perDevice, text.hasPrefix("not found") { throw CoverageError.noLog }
            if endpoint.kind.perDevice, text.hasPrefix("404 page not found") { throw CoverageError.legacyOff }
            throw CoverageError.wrongPort(endpoint.port)
        default: throw CoverageError.server(status)
        }
    }

    private static func request(_ url: URL, method: String, token: String?, port: Int, timeout: TimeInterval) async throws -> (Int, Data) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token { request.setValue(token, forHTTPHeaderField: "x-token") }
        do {
            let (data, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch let error as URLError {
            throw CoverageError(error, port: port)
        }
    }
}
