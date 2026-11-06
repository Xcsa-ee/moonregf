///|
/// Size in bytes of the REGF base block that starts every hive file.
let base_block_size : Int32 = 4096

///|
/// Kind of file recorded in the base block.
pub(all) enum HiveFileType {
  Primary
  Log
  External
  Unknown(UInt32)
}

///|
/// Short label for a hive file type.
pub fn HiveFileType::label(self : HiveFileType) -> String {
  match self {
    Primary => "primary"
    Log => "log"
    External => "external"
    Unknown(value) => "unknown(" + value.to_string() + ")"
  }
}

///|
/// Parsed REGF base block (the 4096 bytes at the start of a hive file).
pub(all) struct HiveHeader {
  primary_sequence : UInt32
  secondary_sequence : UInt32
  last_written_high : UInt32
  last_written_low : UInt32
  major_version : UInt32
  minor_version : UInt32
  file_type : HiveFileType
  file_format : UInt32
  root_cell_offset : UInt32
  hive_bins_data_size : UInt32
  clustering_factor : UInt32
  file_name : String
  checksum : UInt32
}

///|
/// True when the first four bytes are the ASCII bytes of regf.
///
/// Bytes are compared directly instead of being decoded into a string: string
/// decoding depends on the backend and must not be used for format checks.
fn signature_matches(bytes : Bytes) -> Bool {
  bytes[0].to_int() == 0x72 &&
  bytes[1].to_int() == 0x65 &&
  bytes[2].to_int() == 0x67 &&
  bytes[3].to_int() == 0x66
}

///|
/// Renders the first four bytes as lowercase hex, for diagnostics.
fn signature_hex(bytes : Bytes) -> String {
  "0x" +
  bytes[0].to_uint().to_string(radix=16) +
  bytes[1].to_uint().to_string(radix=16) +
  bytes[2].to_uint().to_string(radix=16) +
  bytes[3].to_uint().to_string(radix=16)
}

///|
/// XOR checksum over the first 508 bytes of the base block.
fn compute_checksum(bytes : Bytes) -> UInt32 {
  let mut acc : UInt32 = 0
  let mut offset = 0
  while offset < 508 {
    acc = acc ^ read_u32_le(bytes, offset)
    offset = offset + 4
  }
  acc
}

///|
/// Parses the base block of a hive file.
pub fn parse_header(bytes : Bytes) -> Result[HiveHeader, RegfError] {
  let size = bytes.length()
  if size < base_block_size {
    return Err(TooShort(size))
  }
  if !signature_matches(bytes) {
    return Err(BadSignature(signature_hex(bytes)))
  }
  let computed = compute_checksum(bytes)
  let stored = read_u32_le(bytes, 0x1FC)
  if computed != stored {
    return Err(BadChecksum(stored, computed))
  }
  let raw_type = read_u32_le(bytes, 0x1C)
  let file_type = if raw_type == 0 {
    Primary
  } else if raw_type == 1 {
    Log
  } else if raw_type == 2 {
    External
  } else {
    Unknown(raw_type)
  }
  let parsed : HiveHeader = {
    primary_sequence: read_u32_le(bytes, 0x04),
    secondary_sequence: read_u32_le(bytes, 0x08),
    last_written_high: read_u32_le(bytes, 0x10),
    last_written_low: read_u32_le(bytes, 0x0C),
    major_version: read_u32_le(bytes, 0x14),
    minor_version: read_u32_le(bytes, 0x18),
    file_type,
    file_format: read_u32_le(bytes, 0x20),
    root_cell_offset: read_u32_le(bytes, 0x24),
    hive_bins_data_size: read_u32_le(bytes, 0x28),
    clustering_factor: read_u32_le(bytes, 0x2C),
    file_name: decode_utf16le(bytes, 0x30, 32),
    checksum: stored,
  }
  Ok(parsed)
}
