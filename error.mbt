///|
/// Errors reported while parsing a REGF hive file.
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
  }
}
