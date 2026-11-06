///|
/// Errors reported while parsing or building a REGF hive file.
pub(all) enum RegfError {
  // The input is shorter than the 4096-byte base block.
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
}

///|
/// Human readable message for an error value.
pub fn RegfError::message(self : RegfError) -> String {
  match self {
    TooShort(size) =>
      "hive is " + size.to_string() + " bytes, the REGF base block needs 4096"
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
  }
}
