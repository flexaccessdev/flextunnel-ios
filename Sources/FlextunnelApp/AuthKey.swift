import Foundation

/// Client auth keypair primitives, via the Rust FFI. A secret key
/// ("flxtsecretv1:…") authenticates the tunnel handshake; its public key
/// ("flxtpubv1:…") is not a secret — it's what the user puts on the
/// server's authorized-keys file, and it's re-derived from the secret
/// whenever needed rather than stored. The app's named key list lives in
/// `AuthKeyStore`.
enum AuthKey {
    struct Keypair {
        let secretKey: String
        let publicKey: String
    }

    /// Generate a fresh ed25519 keypair. Nil only if the FFI misbehaves.
    static func generate() -> Keypair? {
        var buf = [CChar](repeating: 0, count: 1024)
        guard flextunnel_generate_client_key(&buf, buf.count) == 1,
              let data = String(cString: buf).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let secretKey = obj["secret_key"] as? String,
              let publicKey = obj["public_key"] as? String
        else { return nil }
        return Keypair(secretKey: secretKey, publicKey: publicKey)
    }

    /// The public key of `secret`, or nil when it isn't a valid secret key —
    /// which also makes this the validator for pasted keys.
    static func publicKey(forSecret secret: String) -> String? {
        guard !secret.isEmpty else { return nil }
        var buf = [CChar](repeating: 0, count: 256)
        let ok = secret.withCString { flextunnel_client_public_key($0, &buf, buf.count) }
        guard ok == 1 else { return nil }
        return String(cString: buf)
    }
}
