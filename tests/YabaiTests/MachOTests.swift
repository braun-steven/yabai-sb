import MachO
import Testing

@testable import Yabai

private func rawBytes<T>(of value: T) -> [UInt8] {
  withUnsafeBytes(of: value) { Array($0) }
}

private func makeSymbolTable(
  symbolOffset: UInt32? = nil, stringOffset: UInt32? = nil,
  symbolCount: UInt32 = 1, symbolNameOffset: UInt32 = 1, stringSize: UInt32? = nil
) -> (commands: [UInt8], linkedit: [UInt8]) {
  var segment = segment_command_64()
  segment.cmd = UInt32(LC_SEGMENT_64)
  segment.cmdsize = UInt32(MemoryLayout<segment_command_64>.size)
  segment.vmaddr = 0x2000
  segment.vmsize = 0x100
  segment.fileoff = 0x1000
  segment.filesize = 0x100
  let name = Array("__LINKEDIT".utf8) + [UInt8](repeating: 0, count: 6)
  withUnsafeMutableBytes(of: &segment.segname) { bytes in
    for index in name.indices {
      bytes[index] = name[index]
    }
  }

  let symbolStart = MemoryLayout<nlist_64>.size
  let stringStart = symbolStart + MemoryLayout<nlist_64>.size
  var symbol = nlist_64()
  symbol.n_un.n_strx = symbolNameOffset
  symbol.n_value = 0x4567

  var symtab = symtab_command()
  symtab.cmd = UInt32(LC_SYMTAB)
  symtab.cmdsize = UInt32(MemoryLayout<symtab_command>.size)
  symtab.symoff = symbolOffset ?? UInt32(0x1000 + symbolStart)
  symtab.nsyms = symbolCount
  symtab.stroff = stringOffset ?? UInt32(0x1000 + stringStart)
  symtab.strsize = stringSize ?? UInt32("_target".utf8.count + 2)

  var linkedit = [UInt8](repeating: 0, count: 0x100)
  let symbolBytes = rawBytes(of: symbol)
  for index in symbolBytes.indices {
    linkedit[symbolStart + index] = symbolBytes[index]
  }
  let strings = Array([UInt8(0)] + Array("_target".utf8) + [0])
  for index in strings.indices {
    linkedit[stringStart + index] = strings[index]
  }
  return (rawBytes(of: segment) + rawBytes(of: symtab), linkedit)
}

private func symbolValue(
  commands: [UInt8], linkedit: [UInt8], commandCount: UInt32 = 2
) -> UInt64? {
  commands.withUnsafeBytes { commandBytes in
    linkedit.withUnsafeBytes { linkeditBytes in
      guard let table = MachOParser.symbolTable(in: commandBytes, commandCount: commandCount) else {
        return nil
      }
      return MachOParser.value(of: "_target", in: linkeditBytes, table: table)
    }
  }
}

@Test func machOParserFindsSymbolInBoundedLinkeditData() {
  let fixture = makeSymbolTable()
  #expect(symbolValue(commands: fixture.commands, linkedit: fixture.linkedit) == 0x4567)
}

@Test(arguments: [
  [UInt8](),
  [UInt8](repeating: 0, count: MemoryLayout<load_command>.size - 1),
])
func machOParserRejectsTruncatedCommandHeaders(commands: [UInt8]) {
  #expect(symbolValue(commands: commands, linkedit: []) == nil)
}

@Test func machOParserRejectsCommandSizesOutsideTheBuffer() {
  var command = load_command()
  command.cmd = UInt32(LC_SYMTAB)
  command.cmdsize = UInt32(MemoryLayout<load_command>.size + 1)
  #expect(symbolValue(commands: rawBytes(of: command), linkedit: []) == nil)
}

@Test func machOParserRejectsShortSymbolTableCommands() {
  var command = load_command()
  command.cmd = UInt32(LC_SYMTAB)
  command.cmdsize = UInt32(MemoryLayout<load_command>.size)
  #expect(symbolValue(commands: rawBytes(of: command), linkedit: []) == nil)
}

@Test(arguments: [UInt32(0x1100), 0x0FFF])
func machOParserRejectsSymbolTablesOutsideLinkeditBounds(symbolOffset: UInt32) {
  let fixture = makeSymbolTable(symbolOffset: symbolOffset)
  #expect(symbolValue(commands: fixture.commands, linkedit: fixture.linkedit) == nil)
}

@Test(arguments: [UInt32(0x1100), 0x0FFF])
func machOParserRejectsStringTablesOutsideLinkeditBounds(stringOffset: UInt32) {
  let fixture = makeSymbolTable(stringOffset: stringOffset)
  #expect(symbolValue(commands: fixture.commands, linkedit: fixture.linkedit) == nil)
}

@Test func machOParserRejectsSymbolCountPastTheLinkeditBuffer() {
  let fixture = makeSymbolTable(symbolOffset: 0x10F0, symbolCount: 2)
  #expect(symbolValue(commands: fixture.commands, linkedit: fixture.linkedit) == nil)
}

@Test(arguments: [UInt32(9), UInt32.max])
func machOParserSkipsStringIndexesOutsideTheStringTable(symbolNameOffset: UInt32) {
  let fixture = makeSymbolTable(symbolNameOffset: symbolNameOffset)
  #expect(symbolValue(commands: fixture.commands, linkedit: fixture.linkedit) == nil)
}

@Test func machOParserSkipsSymbolNamesWithoutATerminator() {
  var fixture = makeSymbolTable()
  let stringTerminator = MemoryLayout<nlist_64>.size * 2 + "_target".utf8.count + 1
  fixture.linkedit[stringTerminator] = UInt8(ascii: "x")
  #expect(symbolValue(commands: fixture.commands, linkedit: fixture.linkedit) == nil)
}

@Test func machOParserRejectsMissingSymbolNames() {
  let fixture = makeSymbolTable()
  fixture.commands.withUnsafeBytes { commandBytes in
    fixture.linkedit.withUnsafeBytes { linkeditBytes in
      let table = MachOParser.symbolTable(in: commandBytes, commandCount: 2)
      #expect(
        table.flatMap { MachOParser.value(of: "_missing", in: linkeditBytes, table: $0) } == nil)
    }
  }
}
