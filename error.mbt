///|
/// Errors reported while parsing a REGF hive file.
pub(all) enum RegfError {
  // The input is shorter than the 4096-byte base block.
  TooShort(Int32)
  // The first four bytes are not regf.
  BadSignature(String)
  // The stored base block checksum differs from the computed one.
  BadChecksum(UInt32, UInt32)
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
  }
}
