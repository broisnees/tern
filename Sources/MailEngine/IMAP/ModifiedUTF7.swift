import Foundation

/// IMAP mailbox names use "modified UTF-7" (RFC 3501 section 5.1.3).
public enum ModifiedUTF7 {
    public static func decode(_ name: String) -> String {
        guard name.contains("&") else { return name }
        var result = ""
        var chars = Substring(name)
        while let amp = chars.firstIndex(of: "&") {
            result += chars[chars.startIndex..<amp]
            let afterAmp = chars.index(after: amp)
            guard let dash = chars[afterAmp...].firstIndex(of: "-") else {
                result += chars[amp...]
                return result
            }
            let encoded = chars[afterAmp..<dash]
            if encoded.isEmpty {
                result += "&"
            } else {
                var b64 = encoded.replacingOccurrences(of: ",", with: "/")
                while b64.count % 4 != 0 { b64 += "=" }
                if let data = Data(base64Encoded: b64), let s = String(data: data, encoding: .utf16BigEndian) {
                    result += s
                } else {
                    result += chars[amp...dash]
                }
            }
            chars = chars[chars.index(after: dash)...]
        }
        result += chars
        return result
    }

    public static func encode(_ name: String) -> String {
        var result = ""
        var pending: [UInt16] = []
        func flush() {
            guard !pending.isEmpty else { return }
            var bytes: [UInt8] = []
            for unit in pending {
                bytes.append(UInt8(unit >> 8))
                bytes.append(UInt8(unit & 0xFF))
            }
            let b64 = Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "/", with: ",")
            result += "&\(b64)-"
            pending.removeAll()
        }
        for scalar in name.unicodeScalars {
            if scalar.value >= 0x20 && scalar.value <= 0x7E {
                flush()
                result += scalar == "&" ? "&-" : String(scalar)
            } else {
                pending.append(contentsOf: Array(String(scalar).utf16))
            }
        }
        flush()
        return result
    }
}
