import MachO

private func findImageHeader(_ targetName: UnsafePointer<CChar>, _ slide: inout UInt) -> UnsafePointer<mach_header_64>?
{
    for i in 0..<_dyld_image_count() {
        guard let imageName = _dyld_get_image_name(i) else { continue }

        if strcmp(imageName, targetName) == 0 {
            slide = UInt(bitPattern: _dyld_get_image_vmaddr_slide(i))
            return _dyld_get_image_header(i).map { UnsafeRawPointer($0).assumingMemoryBound(to: mach_header_64.self) }
        }
    }

    return nil
}

private func findLoadCommand(_ header: UnsafePointer<mach_header_64>, _ match: (UnsafeRawPointer, UInt32) -> Bool) -> UnsafeRawPointer?
{
    var cursor = UnsafeRawPointer(header) + MemoryLayout<mach_header_64>.size

    for _ in 0..<header.pointee.ncmds {
        let cmd = cursor.load(as: load_command.self)
        if match(cursor, cmd.cmd) { return cursor }
        cursor += Int(cmd.cmdsize)
    }

    return nil
}

private func findLinkeditSegment(_ header: UnsafePointer<mach_header_64>) -> segment_command_64?
{
    let segment = findLoadCommand(header) { cmd, type in
        guard type == LC_SEGMENT_64 else { return false }
        return withUnsafeBytes(of: cmd.load(as: segment_command_64.self).segname) {
            strncmp($0.baseAddress!.assumingMemoryBound(to: CChar.self), SEG_LINKEDIT, $0.count) == 0
        }
    }

    return segment?.load(as: segment_command_64.self)
}

private func findSymtabCommand(_ header: UnsafePointer<mach_header_64>) -> symtab_command?
{
    return findLoadCommand(header) { _, type in type == LC_SYMTAB }?.load(as: symtab_command.self)
}

/// Finds a symbol in the symbol table of a loaded image, including the symbols that it does not export, which dlsym
/// cannot find. Ported from `macho_find_symbol` (src/misc/macho_dlsym.h); yabai.c calls it.
func macho_find_symbol(_ targetImage: UnsafeMutablePointer<CChar>, _ targetSymbol: UnsafeMutablePointer<CChar>) -> UnsafeMutableRawPointer?
{
    var slide: UInt = 0
    guard let header = findImageHeader(targetImage, &slide) else { return nil }
    guard let linkeditSegment = findLinkeditSegment(header) else { return nil }
    guard let symtabCommand = findSymtabCommand(header) else { return nil }

    let linkedit = UInt(linkeditSegment.vmaddr &- linkeditSegment.fileoff) &+ slide
    guard let symbolStr = UnsafeRawPointer(bitPattern: linkedit &+ UInt(symtabCommand.stroff)) else { return nil }
    guard let symbolSym = UnsafeRawPointer(bitPattern: linkedit &+ UInt(symtabCommand.symoff)) else { return nil }

    for i in 0..<Int(symtabCommand.nsyms) {
        let list = symbolSym.load(fromByteOffset: i * MemoryLayout<nlist_64>.size, as: nlist_64.self)
        let symbolName = (symbolStr + Int(list.n_un.n_strx)).assumingMemoryBound(to: CChar.self)
        if strcmp(symbolName, targetSymbol) == 0 {
            return UnsafeMutableRawPointer(bitPattern: UInt(list.n_value) &+ slide)
        }
    }

    return nil
}
