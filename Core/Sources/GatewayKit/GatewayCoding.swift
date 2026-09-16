import Foundation

/// The one place the wire format is decided.
///
/// Dates travel as ISO8601 strings because the client is JavaScript, where
/// `new Date(string)` parses them directly. Foundation's default encodes a `Date` as
/// seconds since 2001, which a browser reads as a nonsensical 1970-based instant.
public enum GatewayCoding {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
