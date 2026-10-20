import Foundation

/// MD4 (RFC 1320).
///
/// Only here because NTLM needs it: the NT hash is MD4 of the password in UTF-16LE.
/// CryptoKit has no MD4 — it is broken as a hash — but NTLM still uses it, so the
/// implementation is unavoidable. Kept private to the WinRM feature so nothing else
/// can reach for it.
enum MD4 {
    static func hash(_ data: [UInt8]) -> [UInt8] {
        var message = data
        let bitLength = UInt64(data.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 0, through: 56, by: 8) {
            message.append(UInt8truncating(bitLength >> UInt64(shift)))
        }

        var a: UInt32 = 0x6745_2301
        var b: UInt32 = 0xefcd_ab89
        var c: UInt32 = 0x98ba_dcfe
        var d: UInt32 = 0x1032_5476

        for chunk in stride(from: 0, to: message.count, by: 64) {
            var x = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let base = chunk + i * 4
                x[i] = UInt32(message[base])
                    | UInt32(message[base + 1]) << 8
                    | UInt32(message[base + 2]) << 16
                    | UInt32(message[base + 3]) << 24
            }

            let aa = a, bb = b, cc = c, dd = d

            // The round schedule is the only hard part: each pass reads the sixteen
            // words in a different order, and a wrong order still yields a plausible
            // 16-byte digest — which is how a broken NTLM client ends up with a bare
            // 401 and no explanation.
            func f(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | (~x & z) }
            func g(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | (x & z) | (y & z) }
            func h(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { x ^ y ^ z }

            for i in 0..<4 {
                a = rotl(a &+ f(b, c, d) &+ x[4 * i], 3)
                d = rotl(d &+ f(a, b, c) &+ x[4 * i + 1], 7)
                c = rotl(c &+ f(d, a, b) &+ x[4 * i + 2], 11)
                b = rotl(b &+ f(c, d, a) &+ x[4 * i + 3], 19)
            }
            for i in 0..<4 {
                a = rotl(a &+ g(b, c, d) &+ x[i] &+ 0x5a82_7999, 3)
                d = rotl(d &+ g(a, b, c) &+ x[i + 4] &+ 0x5a82_7999, 5)
                c = rotl(c &+ g(d, a, b) &+ x[i + 8] &+ 0x5a82_7999, 9)
                b = rotl(b &+ g(c, d, a) &+ x[i + 12] &+ 0x5a82_7999, 13)
            }
            for i in [0, 2, 1, 3] {
                a = rotl(a &+ h(b, c, d) &+ x[i] &+ 0x6ed9_eba1, 3)
                d = rotl(d &+ h(a, b, c) &+ x[i + 8] &+ 0x6ed9_eba1, 9)
                c = rotl(c &+ h(d, a, b) &+ x[i + 4] &+ 0x6ed9_eba1, 11)
                b = rotl(b &+ h(c, d, a) &+ x[i + 12] &+ 0x6ed9_eba1, 15)
            }

            a = a &+ aa
            b = b &+ bb
            c = c &+ cc
            d = d &+ dd
        }

        var digest: [UInt8] = []
        for word in [a, b, c, d] {
            digest.append(UInt8(word & 0xff))
            digest.append(UInt8((word >> 8) & 0xff))
            digest.append(UInt8((word >> 16) & 0xff))
            digest.append(UInt8((word >> 24) & 0xff))
        }
        return digest
    }

    static func hash(_ data: Data) -> Data { Data(hash([UInt8](data))) }

    private static func rotl(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }

    static func UInt8truncating(_ value: UInt64) -> UInt8 { UInt8(value & 0xff) }
}
