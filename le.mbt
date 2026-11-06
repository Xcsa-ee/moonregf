///|
/// Reads a little-endian 32-bit unsigned integer at offset.
///
/// The caller must guarantee that offset + 4 is within bounds.
pub fn read_u32_le(bytes : Bytes, offset : Int32) -> UInt32 {
  let b0 = bytes[offset].to_uint()
  let b1 = bytes[offset + 1].to_uint()
  let b2 = bytes[offset + 2].to_uint()
  let b3 = bytes[offset + 3].to_uint()
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}
