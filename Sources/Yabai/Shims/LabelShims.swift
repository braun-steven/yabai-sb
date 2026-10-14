import YabaiC
import YabaiCore

//
// NOTE: The C entry points of LabelList (Sources/YabaiCore/Label.swift) while the display and space managers are C
// (src/misc/label.h). A `struct label_list *` is an opaque reference to a LabelListBox: labelSet creates it with
// passRetained when the list is NULL, and nothing releases it, because the managers own their lists while the
// daemon runs. They go when the managers are Swift (P9).
//

final class LabelListBox
{
    var list = LabelList()
}

func labelList(_ list: OpaquePointer?) -> LabelListBox?
{
    list.map { Unmanaged<LabelListBox>.fromOpaque(UnsafeRawPointer($0)).takeUnretainedValue() }
}

/// A copy of a string in the temporary storage of the C code (`ts_string_from_bytes`).
func tsString(_ string: String) -> UnsafeMutablePointer<CChar>
{
    var string = string
    return string.withUTF8 { ts_string_from_bytes($0.baseAddress, UInt64($0.count)) }
}

@_cdecl("label_find_id")
func label_find_id(_ list: OpaquePointer?, _ id: UInt64) -> UnsafeMutablePointer<CChar>?
{
    guard let label = labelList(list)?.list.find(id: id) else { return nil }
    return tsString(label.name)
}

@_cdecl("label_find_name")
func label_find_name(_ list: OpaquePointer?, _ name: UnsafeMutablePointer<CChar>?, _ id: UnsafeMutablePointer<UInt64>) -> Bool
{
    guard let name, let label = labelList(list)?.list.find(name: String(cString: name)) else { return false }

    id.pointee = label.id
    return true
}

@_cdecl("label_remove_id")
func label_remove_id(_ list: OpaquePointer?, _ id: UInt64) -> Bool
{
    labelList(list)?.list.remove(id: id) ?? false
}

/// The C label list of a manager (`struct label_list *`): sets a label, creating the list when it has none (`label_set`).
func labelSet(_ list: UnsafeMutablePointer<OpaquePointer?>, _ id: UInt64, _ label: Token)
{
    if list.pointee == nil {
        list.pointee = OpaquePointer(Unmanaged.passRetained(LabelListBox()).toOpaque())
    }

    labelList(list.pointee)!.list.set(id: id, name: label.string)
}

@_cdecl("label_set")
func label_set(_ list: UnsafeMutablePointer<OpaquePointer?>, _ id: UInt64, _ name: UnsafeMutablePointer<CChar>)
{
    defer { free(name) }
    labelSet(list, id, Token(cString: name))
}

@_cdecl("label_replace_id")
func label_replace_id(_ list: OpaquePointer?, _ id: UInt64, _ newID: UInt64)
{
    labelList(list)?.list.replace(id: id, with: newID)
}

@_cdecl("label_swap_ids")
func label_swap_ids(_ list: OpaquePointer?, _ a: UInt64, _ b: UInt64)
{
    labelList(list)?.list.swap(a, b)
}
