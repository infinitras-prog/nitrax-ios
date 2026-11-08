import Foundation

/// Beliebiger JSON-Wert - der PC liefert manche Felder mal als Zahl, mal als Text, mal als Objekt.
enum JSONWert: Codable, Hashable {
    case text(String)
    case zahl(Double)
    case wahr(Bool)
    case liste([JSONWert])
    case objekt([String: JSONWert])
    case nichts

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .nichts }
        else if let b = try? c.decode(Bool.self) { self = .wahr(b) }
        else if let z = try? c.decode(Double.self) { self = .zahl(z) }
        else if let t = try? c.decode(String.self) { self = .text(t) }
        else if let l = try? c.decode([JSONWert].self) { self = .liste(l) }
        else if let o = try? c.decode([String: JSONWert].self) { self = .objekt(o) }
        else { self = .nichts }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let t): try c.encode(t)
        case .zahl(let z): try c.encode(z)
        case .wahr(let b): try c.encode(b)
        case .liste(let l): try c.encode(l)
        case .objekt(let o): try c.encode(o)
        case .nichts: try c.encodeNil()
        }
    }

    var text: String? {
        switch self {
        case .text(let t): return t
        case .zahl(let z): return z == z.rounded() && abs(z) < 1e15 ? String(Int(z)) : String(z)
        case .wahr(let b): return b ? "true" : "false"
        default: return nil
        }
    }
    var zahl: Double? {
        switch self {
        case .zahl(let z): return z
        case .text(let t): return Double(t)
        default: return nil
        }
    }
    var wahr: Bool? {
        switch self {
        case .wahr(let b): return b
        case .zahl(let z): return z != 0
        case .text(let t): return ["true", "1", "ja"].contains(t.lowercased())
        default: return nil
        }
    }
    var liste: [JSONWert]? { if case .liste(let l) = self { return l }; return nil }
    var objekt: [String: JSONWert]? { if case .objekt(let o) = self { return o }; return nil }
    subscript(_ k: String) -> JSONWert? { objekt?[k] }
    var istLeer: Bool {
        switch self {
        case .nichts: return true
        case .text(let t): return t.trimmingCharacters(in: .whitespaces).isEmpty
        case .liste(let l): return l.isEmpty
        default: return false
        }
    }
}
