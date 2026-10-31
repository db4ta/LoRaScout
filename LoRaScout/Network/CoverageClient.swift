import Foundation

enum CoverageError: LocalizedError, Equatable {
    case noServer
    case noToken
    case badToken
    case noLog
    case unreachable
    case insecure
    case server(Int)
    case notCoverage

    var errorDescription: String? {
        switch self {
        case .noServer: "Bitte einen Server eintragen."
        case .noToken: "Bitte das Upload-Token eintragen."
        case .badToken: "Token falsch (HTTP 403)."
        case .noLog: "Auf dem Server gibt es noch kein Coverage-Log, oder das ioBroker-Skript ist nicht aktuell (HTTP 404)."
        case .unreachable: "Server nicht erreichbar. Heim-WLAN und die Freigabe „Lokales Netzwerk“ in den iOS-Einstellungen prüfen."
        case .insecure: "Unverschlüsseltes http geht nur im lokalen Netz: IP-Adresse, Rechnername oder .local verwenden."
        case .server(let code): "Server-Fehler (HTTP \(code))."
        case .notCoverage: "Die Daten enthalten keine gültigen Coverage-Zeilen."
        }
    }

    init?(status: Int) {
        switch status {
        case 200: return nil
        case 403: self = .badToken
        case 404: self = .noLog
        default: self = .server(status)
        }
    }

    init(_ error: URLError) {
        self = error.code == .appTransportSecurityRequiresSecureConnection ? .insecure : .unreachable
    }
}

enum CoverageClient {
    static let port = 8099

    /// Accepts the device's server value (full URL, `host:port/path` or a bare IP). Only host, port and scheme are used.
    static func url(server: String) -> URL? {
        let text = server.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        guard var parts = URLComponents(string: text.contains("://") ? text : "http://" + text),
              parts.host?.isEmpty == false else { return nil }
        parts.port = parts.port ?? port
        parts.path = "/coverage"
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    /// The part of the device's server value worth showing and editing.
    static func hostText(server: String) -> String { url(server: server)?.host() ?? server }

    static func fetch(url: URL, token: String) async throws -> Data {
        try await send(url: url, method: "GET", token: token)
    }

    /// Removes coverage log and uploaded device log from the server.
    static func deleteLogs(coverageURL: URL, token: String) async throws {
        do {
            _ = try await send(url: coverageURL.deletingLastPathComponent().appending(path: "logs"), method: "DELETE", token: token)
        } catch CoverageError.noLog {
            throw CoverageError.server(404)  // only an old script answers 404 here
        }
    }

    private static func send(url: URL, method: String, token: String) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "x-token")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error = CoverageError(status: status) { throw error }
            return data
        } catch let error as URLError {
            throw CoverageError(error)
        }
    }
}
