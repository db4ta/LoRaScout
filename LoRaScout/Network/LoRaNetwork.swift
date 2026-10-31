import Foundation

struct CredentialField: Identifiable {
    var id: ConfigID
    var label: String
    var hexLength: Int
    var isSecret: Bool

    /// Returns the value as the device expects it, nil if it is not valid.
    func normalized(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespaces).uppercased()
        guard value.count == hexLength, value.allSatisfy(\.isHexDigit) else { return nil }
        return value
    }
}

/// Everything in the app that depends on the LoRaWAN network operator.
protocol LoRaNetwork {
    var name: String { get }
    var credentials: [CredentialField] { get }
    var gatewayNote: String { get }
}

struct TTNNetwork: LoRaNetwork {
    let name = "The Things Network"
    let credentials = [
        CredentialField(id: .devEUI, label: "DevEUI", hexLength: 16, isSecret: false),
        CredentialField(id: .joinEUI, label: "JoinEUI (AppEUI)", hexLength: 16, isSecret: false),
        CredentialField(id: .appKey, label: "AppKey", hexLength: 32, isSecret: true),
    ]
    let gatewayNote = "Gateway-Zahl und bestes Signal kommen per TTN-Downlink nach SEND NOW."
}
