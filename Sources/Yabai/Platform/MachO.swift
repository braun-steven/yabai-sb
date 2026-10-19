import MachO

//
// NOTE: Finds symbols in the symbol table of a loaded image, including the symbols that it does not export, which dlsym
// cannot find. Daemon.run resolves two private SkyLight functions with it.
//

enum MachOSymbol
{
    /// The address of the symbol in the loaded image at the path; nil if the image is not loaded or has no such symbol.
    static func address(of symbol: String, inImage imagePath: String) -> UnsafeMutableRawPointer?
    {
        guard let image = imageHeader(at: imagePath) else { return nil }
        guard let segment = linkeditSegment(image.header) else { return nil }
        guard let symtab = symtabCommand(image.header) else { return nil }

        let linkedit = UInt(segment.vmaddr &- segment.fileoff) &+ image.slide
        guard let symbolStr = UnsafeRawPointer(bitPattern: linkedit &+ UInt(symtab.stroff)) else { return nil }
        guard let symbolSym = UnsafeRawPointer(bitPattern: linkedit &+ UInt(symtab.symoff)) else { return nil }

        return symbol.withCString { target -> UnsafeMutableRawPointer? in
            for i in 0..<Int(symtab.nsyms) {
                let list = symbolSym.load(fromByteOffset: i * MemoryLayout<nlist_64>.size, as: nlist_64.self)
                let symbolName = (symbolStr + Int(list.n_un.n_strx)).assumingMemoryBound(to: CChar.self)
                if strcmp(symbolName, target) == 0 {
                    return UnsafeMutableRawPointer(bitPattern: UInt(list.n_value) &+ image.slide)
                }
            }

            return nil
        }
    }

    private static func imageHeader(at path: String) -> (header: UnsafePointer<mach_header_64>, slide: UInt)?
    {
        return path.withCString { target -> (header: UnsafePointer<mach_header_64>, slide: UInt)? in
            for i in 0..<_dyld_image_count() {
                guard let imageName = _dyld_get_image_name(i) else { continue }

                if strcmp(imageName, target) == 0 {
                    guard let header = _dyld_get_image_header(i) else { return nil }
                    let slide = UInt(bitPattern: _dyld_get_image_vmaddr_slide(i))
                    return (header: UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self), slide: slide)
                }
            }

            return nil
        }
    }

    private static func loadCommand(_ header: UnsafePointer<mach_header_64>, _ match: (UnsafeRawPointer, UInt32) -> Bool) -> UnsafeRawPointer?
    {
        var cursor = UnsafeRawPointer(header) + MemoryLayout<mach_header_64>.size

        for _ in 0..<header.pointee.ncmds {
            let cmd = cursor.load(as: load_command.self)
            if match(cursor, cmd.cmd) { return cursor }
            cursor += Int(cmd.cmdsize)
        }

        return nil
    }

    private static func linkeditSegment(_ header: UnsafePointer<mach_header_64>) -> segment_command_64?
    {
        let segment = loadCommand(header) { cmd, type in
            guard type == LC_SEGMENT_64 else { return false }
            return withUnsafeBytes(of: cmd.load(as: segment_command_64.self).segname) {
                strncmp($0.baseAddress!.assumingMemoryBound(to: CChar.self), SEG_LINKEDIT, $0.count) == 0
            }
        }

        return segment?.load(as: segment_command_64.self)
    }

    private static func symtabCommand(_ header: UnsafePointer<mach_header_64>) -> symtab_command?
    {
        return loadCommand(header) { _, type in type == LC_SYMTAB }?.load(as: symtab_command.self)
    }
}
