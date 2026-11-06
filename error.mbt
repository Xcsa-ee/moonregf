///|
/// Errors reported while parsing, building or replaying a REGF hive file.
pub(all) enum RegfError {
  // The input cannot hold a REGF base block.
  TooShort(Int32)
  // The first four bytes are not regf.
  BadSignature(String)
  // The stored base block checksum differs from the computed one.
  BadChecksum(UInt32, UInt32)
  // A cell offset points outside the hive bins region.
  BadCellOffset(Int32)
  // A cell declares a size that does not fit the file.
  BadCellSize(Int32)
  // A cell is not a key node record.
  BadKeyNode(Int32)
  // A cell is not a subkey list record.
  BadSubkeyList(Int32)
  // A cell is not a value record.
  BadValue(Int32)
  // The data of a value cannot be resolved.
  BadValueData(Int32)
  // A key name is not ASCII, which the writer does not support yet.
  UnsupportedName(Int32)
  // A value does not fit in a single data cell.
  ValueTooLarge(Int32)
  // A .reg document cannot be parsed.
  BadRegFile(String)
  // A .reg section asks to delete a key, which the importer does not support yet.
  UnsupportedDelete(String)
  // The file type says the file is neither a hive nor a transaction log.
  NotALogFile(UInt32)
  // The log uses a layout this library does not parse yet.
  UnsupportedLogVersion(UInt32)
  // A transaction log entry is malformed.
  BadLogEntry(Int32)
  // A dirty page points outside the hive bins data.
  BadLogPage(Int32)
}

///|
/// Human readable message for an error value.
pub fn RegfError::message(self : RegfError) -> String {
  match self {
    TooShort(size) =>
      "input is " + size.to_string() + " bytes, the REGF base block needs 4096"
    BadSignature(signature) =>
      "unexpected signature " + signature + ", expected regf"
    BadChecksum(stored, computed) =>
      "checksum mismatch: stored 0x" +
      stored.to_string(radix=16) +
      " computed 0x" +
      computed.to_string(radix=16)
    BadCellOffset(offset) =>
      "cell offset " + offset.to_string() + " is outside the hive bins region"
    BadCellSize(offset) =>
      "cell at " + offset.to_string() + " has an invalid size"
    BadKeyNode(offset) => "cell at " + offset.to_string() + " is not a key node"
    BadSubkeyList(offset) =>
      "cell at " + offset.to_string() + " is not a subkey list"
    BadValue(offset) =>
      "cell at " + offset.to_string() + " is not a value record"
    BadValueData(offset) =>
      "cell at " + offset.to_string() + " cannot hold the value data"
    UnsupportedName(index) =>
      "key " +
      index.to_string() +
      " has a non-ASCII name, which build() does not support yet"
    ValueTooLarge(size) =>
      "value " +
      size.to_string() +
      " bytes cannot be stored in one data cell yet"
    BadRegFile(detail) => "cannot parse .reg text: " + detail
    UnsupportedDelete(path) => "deleting " + path + " is not supported yet"
    NotALogFile(file_type) =>
      "file type " + file_type.to_string() + " is not a transaction log"
    UnsupportedLogVersion(version) =>
      "log format " + version.to_string() + " is not supported"
    BadLogEntry(offset) =>
      "log entry at " + offset.to_string() + " is malformed"
    BadLogPage(offset) =>
      "dirty page at " + offset.to_string() + " is outside the hive bins data"
  }
}
