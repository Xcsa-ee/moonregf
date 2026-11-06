///|
/// Narrows an integer to a byte.
fn byte_of(value : Int32) -> Byte {
  (value & 0xFF & 0xFF).to_byte()
}

///|
/// Writes a signed 32-bit value as four little-endian bytes.
fn put_i32(bytes : Array[Byte], offset : Int32, value : Int32) -> Unit {
  bytes[offset] = byte_of(value & 0xFF)
  bytes[offset + 1] = byte_of((value >> 8) & 0xFF)
  bytes[offset + 2] = byte_of((value >> 16) & 0xFF)
  bytes[offset + 3] = byte_of((value >> 24) & 0xFF)
}

///|
/// Writes a 16-bit little-endian value.
fn put_u16(bytes : Array[Byte], offset : Int32, value : Int32) -> Unit {
  bytes[offset] = byte_of(value & 0xFF)
  bytes[offset + 1] = byte_of((value >> 8) & 0xFF)
}

///|
/// Builds a hive buffer with one hive bin holding one nk cell at offset 32.
fn hive_with_key(name_len : Int32, flags : Int32) -> Array[Byte] {
  let bytes : Array[Byte] = Bytes::new(base_block_size * 2).to_array()
  put_signature(bytes)
  put_u32(bytes, 0x1FC, block_checksum(bytes))
  put_u32(bytes, base_block_size, 0x6E696268)
  let cell_start = base_block_size + 32
  let total = (4 + 76 + name_len + 7) / 8 * 8
  put_i32(bytes, cell_start, -total)
  put_u16(bytes, cell_start + 4, 0x6B6E)
  put_u16(bytes, cell_start + 6, flags)
  put_i32(bytes, cell_start + 20, -1)
  put_i32(bytes, cell_start + 24, 3)
  put_i32(bytes, cell_start + 40, 1)
  put_u16(bytes, cell_start + 76, name_len)
  bytes
}

///|
/// Renders a cell header.
fn describe_cell(bytes : Bytes, offset : UInt32) -> String {
  match read_cell(bytes, offset) {
    Ok(cell) =>
      "ok allocated=" +
      cell.allocated.to_string() +
      " payload=" +
      cell.payload_size.to_string()
    Err(error) => "err " + error.message()
  }
}

///|
/// Renders the parsed key node fields.
fn describe_key(bytes : Bytes, offset : UInt32) -> String {
  match parse_key_node(bytes, offset) {
    Ok(key) =>
      "ok name=" +
      key.name +
      " name_len=" +
      key.name_length.to_string() +
      " subkeys=" +
      key.subkey_count.to_string() +
      " values=" +
      key.value_count.to_string() +
      " parent=0x" +
      key.parent_offset.to_string(radix=16)
    Err(error) => "err " + error.message()
  }
}

///|
test "reads an allocated cell" {
  assert_eq(
    describe_cell(Bytes::from_array(hive_with_key(4, 0x2C)), 0x20),
    "ok allocated=true payload=84",
  )
}

///|
test "parses a compressed key name" {
  let block = hive_with_key(4, 0x2C)
  put_u32(block, base_block_size + 112, 0x544F4F52)
  assert_eq(
    describe_key(Bytes::from_array(block), 0x20),
    "ok name=ROOT name_len=4 subkeys=3 values=1 parent=0xffffffff",
  )
}

///|
test "parses a utf-16 key name" {
  let block = hive_with_key(4, 0x0C)
  put_u32(block, base_block_size + 112, 0x00620061)
  assert_eq(
    describe_key(Bytes::from_array(block), 0x20),
    "ok name=ab name_len=4 subkeys=3 values=1 parent=0xffffffff",
  )
}

///|
test "rejects a cell that is not a key node" {
  let block = hive_with_key(4, 0x2C)
  block[base_block_size + 36] = byte_of(0x78)
  assert_eq(
    describe_key(Bytes::from_array(block), 0x20),
    "err cell at 32 is not a key node",
  )
}

///|
test "rejects a cell with an impossible size" {
  assert_eq(
    describe_cell(Bytes::from_array(hive_with_key(4, 0x2C)), 0),
    "err cell at 0 has an invalid size",
  )
}
