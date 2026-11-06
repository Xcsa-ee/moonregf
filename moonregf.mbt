// moonregf - a pure MoonBit reader and writer for Windows registry hive files
// (the REGF binary format used by NTUSER.DAT, SYSTEM, SOFTWARE and friends).
//
// Layers:
//   read_u32_le / decode_utf16le  - byte and text primitives
//   parse_header                  - the 4096-byte base block
//   cell, key tree and value layers (in progress)
