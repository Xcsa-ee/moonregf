///|
/// Flag bit marking a key name stored as single-byte characters.
let key_flag_compressed_name : UInt32 = 0x0020

// Offsets inside an nk record, relative to its two signature bytes.

///|
let nk_flags : Int32 = 2

///|
let nk_last_written : Int32 = 4

///|
let nk_access_bits : Int32 = 12

///|
let nk_parent : Int32 = 16

///|
let nk_subkey_count : Int32 = 20

///|
let nk_volatile_subkey_count : Int32 = 24

///|
let nk_subkey_list : Int32 = 28

///|
let nk_volatile_subkey_list : Int32 = 32

///|
let nk_value_count : Int32 = 36

///|
let nk_value_list : Int32 = 40

///|
let nk_security : Int32 = 44

///|
let nk_class_name : Int32 = 48

///|
let nk_name_length : Int32 = 72

///|
let nk_class_name_length : Int32 = 74

///|
let nk_name : Int32 = 76

///|
let nk_min_size : Int32 = 76

///|
/// A key node (nk) record: one registry key and the offsets of its children.
pub(all) struct HiveKeyNode {
  offset : UInt32
  flags : UInt32
  last_written_high : UInt32
  last_written_low : UInt32
  access_bits : UInt32
  parent_offset : UInt32
  subkey_count : UInt32
  volatile_subkey_count : UInt32
  subkey_list_offset : UInt32
  volatile_subkey_list_offset : UInt32
  value_count : UInt32
  value_list_offset : UInt32
  security_offset : UInt32
  class_name_offset : UInt32
  name_length : UInt32
  class_name_length : UInt32
  name : String
}

///|
/// Parses the key node stored in the cell at offset.
pub fn parse_key_node(
  bytes : Bytes,
  offset : UInt32,
) -> Result[HiveKeyNode, RegfError] {
  match read_cell(bytes, offset) {
    Err(error) => Err(error)
    Ok(cell) => parse_key_payload(bytes, cell)
  }
}

///|
/// True when the two bytes at start are the ASCII signature of an nk record.
fn key_signature_matches(bytes : Bytes, start : Int32) -> Bool {
  bytes[start].to_int() == 0x6E && bytes[start + 1].to_int() == 0x6B
}

///|
/// Parses the nk payload of an already validated cell.
fn parse_key_payload(
  bytes : Bytes,
  cell : HiveCell,
) -> Result[HiveKeyNode, RegfError] {
  let relative = cell.offset.reinterpret_as_int()
  let start = hive_bins_base + relative + 4
  if cell.payload_size < nk_min_size {
    return Err(BadKeyNode(relative))
  }
  if !key_signature_matches(bytes, start) {
    return Err(BadKeyNode(relative))
  }
  let flags = read_u16_le(bytes, start + nk_flags)
  let name_length = read_u16_le(bytes, start + nk_name_length)
  let class_name_length = read_u16_le(bytes, start + nk_class_name_length)
  let name_len = name_length.reinterpret_as_int()
  if nk_name + name_len > cell.payload_size {
    return Err(BadKeyNode(relative))
  }
  let name = if (flags & key_flag_compressed_name) != 0 {
    decode_single_byte(bytes, start + nk_name, name_len)
  } else {
    decode_utf16le(bytes, start + nk_name, name_len / 2)
  }
  let key : HiveKeyNode = {
    offset: cell.offset,
    flags,
    last_written_high: read_u32_le(bytes, start + nk_last_written),
    last_written_low: read_u32_le(bytes, start + nk_last_written + 4),
    access_bits: read_u32_le(bytes, start + nk_access_bits),
    parent_offset: read_u32_le(bytes, start + nk_parent),
    subkey_count: read_u32_le(bytes, start + nk_subkey_count),
    volatile_subkey_count: read_u32_le(bytes, start + nk_volatile_subkey_count),
    subkey_list_offset: read_u32_le(bytes, start + nk_subkey_list),
    volatile_subkey_list_offset: read_u32_le(
      bytes,
      start + nk_volatile_subkey_list,
    ),
    value_count: read_u32_le(bytes, start + nk_value_count),
    value_list_offset: read_u32_le(bytes, start + nk_value_list),
    security_offset: read_u32_le(bytes, start + nk_security),
    class_name_offset: read_u32_le(bytes, start + nk_class_name),
    name_length,
    class_name_length,
    name,
  }
  Ok(key)
}
