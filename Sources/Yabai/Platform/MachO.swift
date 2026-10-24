import MachO

//
// NOTE: Finds symbols in the symbol table of a loaded image, including the symbols that it does not export, which dlsym
// cannot find. Daemon.run resolves two private SkyLight functions with it.
//

enum MachOSymbol {
  /// The address of the symbol in the loaded image at the path; nil if the image is not loaded or has no such symbol.
  static func address(of symbol: String, inImage imagePath: String) -> UnsafeMutableRawPointer? {
    guard let image = imageHeader(at: imagePath) else { return nil }
    let header = image.header
    let commands = UnsafeRawBufferPointer(
      start: UnsafeRawPointer(header) + MemoryLayout<mach_header_64>.size,
      count: Int(header.pointee.sizeofcmds))
    guard
      let table = MachOParser.symbolTable(
        in: commands, commandCount: header.pointee.ncmds)
    else { return nil }

    guard
      let linkeditAddress = UnsafeRawPointer(
        bitPattern: UInt(table.linkedit.vmaddr) &+ image.slide)
    else { return nil }
    guard let linkeditSize = Int(exactly: table.linkedit.filesize) else { return nil }
    let linkedit = UnsafeRawBufferPointer(start: linkeditAddress, count: linkeditSize)
    guard let value = MachOParser.value(of: symbol, in: linkedit, table: table) else { return nil }
    return UnsafeMutableRawPointer(bitPattern: UInt(value) &+ image.slide)
  }

  private static func imageHeader(at path: String) -> (
    header: UnsafePointer<mach_header_64>, slide: UInt
  )? {
    return path.withCString { target -> (header: UnsafePointer<mach_header_64>, slide: UInt)? in
      for i in 0..<_dyld_image_count() {
        guard let imageName = _dyld_get_image_name(i) else { continue }

        if strcmp(imageName, target) == 0 {
          guard let header = _dyld_get_image_header(i) else { return nil }
          let slide = UInt(bitPattern: _dyld_get_image_vmaddr_slide(i))
          return (
            header: UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self),
            slide: slide
          )
        }
      }

      return nil
    }
  }

}

/// Bounds-checked parsing for the parts of a loaded image needed to find a symbol.
enum MachOParser {
  struct SymbolTable {
    let linkedit: segment_command_64
    let symbols: symtab_command
  }

  static func symbolTable(in commands: UnsafeRawBufferPointer, commandCount: UInt32)
    -> SymbolTable?
  {
    var linkedit: segment_command_64?
    var symbols: symtab_command?
    var offset = 0
    let commandHeaderSize = MemoryLayout<load_command>.size

    for _ in 0..<Int(commandCount) {
      guard offset <= commands.count, commandHeaderSize <= commands.count - offset else {
        return nil
      }
      let command = commands.loadUnaligned(fromByteOffset: offset, as: load_command.self)
      guard let commandSize = Int(exactly: command.cmdsize),
        commandSize >= commandHeaderSize, commandSize <= commands.count - offset
      else { return nil }

      switch command.cmd {
      case UInt32(LC_SEGMENT_64):
        guard commandSize >= MemoryLayout<segment_command_64>.size else { return nil }
        let segment = commands.loadUnaligned(
          fromByteOffset: offset, as: segment_command_64.self)
        let isLinkedit = withUnsafeBytes(of: segment.segname) { bytes in
          String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self) == "__LINKEDIT"
        }
        if isLinkedit {
          guard linkedit == nil else { return nil }
          linkedit = segment
        }
      case UInt32(LC_SYMTAB):
        guard commandSize >= MemoryLayout<symtab_command>.size, symbols == nil else {
          return nil
        }
        symbols = commands.loadUnaligned(fromByteOffset: offset, as: symtab_command.self)
      default:
        break
      }

      offset += commandSize
    }

    guard offset == commands.count, let linkedit, let symbols else { return nil }
    return SymbolTable(linkedit: linkedit, symbols: symbols)
  }

  static func value(of name: String, in linkedit: UnsafeRawBufferPointer, table: SymbolTable)
    -> UInt64?
  {
    let fileOffset = table.linkedit.fileoff
    let symbolOffset = UInt64(table.symbols.symoff)
    let stringOffset = UInt64(table.symbols.stroff)
    guard symbolOffset >= fileOffset, stringOffset >= fileOffset else { return nil }

    let symbolStart = symbolOffset - fileOffset
    let symbolBytes = UInt64(table.symbols.nsyms).multipliedReportingOverflow(
      by: UInt64(MemoryLayout<nlist_64>.size))
    let stringStart = stringOffset - fileOffset
    let stringBytes = UInt64(table.symbols.strsize)
    let linkeditBytes = UInt64(linkedit.count)
    guard !symbolBytes.overflow,
      symbolStart <= linkeditBytes, symbolBytes.partialValue <= linkeditBytes - symbolStart,
      stringStart <= linkeditBytes, stringBytes <= linkeditBytes - stringStart,
      let symbolStartIndex = Int(exactly: symbolStart),
      let stringStartIndex = Int(exactly: stringStart),
      let stringEndIndex = Int(exactly: stringStart + stringBytes)
    else { return nil }

    let target = Array(name.utf8)
    for index in 0..<Int(table.symbols.nsyms) {
      let symbol = linkedit.loadUnaligned(
        fromByteOffset: symbolStartIndex + index * MemoryLayout<nlist_64>.size,
        as: nlist_64.self)
      let nameOffset = Int(symbol.n_un.n_strx)
      guard nameOffset < stringEndIndex - stringStartIndex else { continue }
      let nameStart = stringStartIndex + nameOffset
      var nameEnd = nameStart
      while nameEnd < stringEndIndex, linkedit[nameEnd] != 0 {
        nameEnd += 1
      }
      guard nameEnd < stringEndIndex, nameEnd - nameStart == target.count else { continue }
      if target.indices.allSatisfy({ linkedit[nameStart + $0] == target[$0] }) {
        return symbol.n_value
      }
    }

    return nil
  }
}
