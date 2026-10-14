import YabaiC
import YabaiCore

//
// NOTE: The C entry point of JSON.escape (Sources/YabaiCore/JSON.swift) while the serializers are C (P6). Like the
// C version, it returns the string itself when nothing needs escaping, and a copy in temporary storage otherwise.
//

@_cdecl("json_string")
func json_string(_ s: UnsafeMutablePointer<CChar>?) -> UnsafeMutablePointer<CChar>
{
    guard let s else { return UnsafeMutableRawPointer(mutating: ("" as StaticString).utf8Start).assumingMemoryBound(to: CChar.self) }
    guard let escaped = JSON.escape(UnsafeRawBufferPointer(start: s, count: strlen(s))) else { return s }
    return escaped.withUnsafeBufferPointer { ts_string_from_bytes($0.baseAddress, UInt64($0.count)) }
}
