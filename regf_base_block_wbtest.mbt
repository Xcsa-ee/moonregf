///|
/// Builds an all-zero base block as a mutable byte array.
fn empty_base_block() -> Array[Byte] {
  Bytes::new(base_block_size).to_array()
}

///|
/// Writes a little-endian 32-bit integer at offset.
fn put_u32(bytes : Array[Byte], offset : Int32, value : UInt32) -> Unit {
  bytes[offset] = (value & 0xFF).to_byte()
  bytes[offset + 1] = ((value >> 8) & 0xFF).to_byte()
  bytes[offset + 2] = ((value >> 16) & 0xFF).to_byte()
  bytes[offset + 3] = ((value >> 24) & 0xFF).to_byte()
}

///|
/// Writes the four ASCII bytes of the REGF signature.
fn put_signature(bytes : Array[Byte]) -> Unit {
  put_u32(bytes, 0, 0x66676572)
}

///|
/// Independent XOR checksum over the first 508 bytes of the block.
fn block_checksum(bytes : Array[Byte]) -> UInt32 {
  let mut acc : UInt32 = 0
  let mut offset = 0
  while offset < 508 {
    let b0 = bytes[offset].to_uint()
    let b1 = bytes[offset + 1].to_uint()
    let b2 = bytes[offset + 2].to_uint()
    let b3 = bytes[offset + 3].to_uint()
    acc = acc ^ (b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
    offset = offset + 4
  }
  acc
}

///|
/// A signed base block shaped like a real hive, file name hive.dat.
fn signed_block() -> Array[Byte] {
  let bytes = empty_base_block()
  put_signature(bytes)
  put_u32(bytes, 0x04, 36)
  put_u32(bytes, 0x08, 36)
  put_u32(bytes, 0x14, 1)
  put_u32(bytes, 0x18, 5)
  put_u32(bytes, 0x1C, 0)
  put_u32(bytes, 0x20, 1)
  put_u32(bytes, 0x24, 32)
  put_u32(bytes, 0x28, 184320)
  put_u32(bytes, 0x2C, 1)
  put_u32(bytes, 0x30, 0x00690068)
  put_u32(bytes, 0x34, 0x00650076)
  put_u32(bytes, 0x38, 0x0064002E)
  put_u32(bytes, 0x3C, 0x00740061)
  let checksum = block_checksum(bytes)
  put_u32(bytes, 0x1FC, checksum)
  bytes
}

///|
/// Renders the parsed header as a single-line summary.
fn describe(bytes : Bytes) -> String {
  match parse_header(bytes) {
    Ok(header) =>
      "ok seq=" +
      header.primary_sequence.to_string() +
      "/" +
      header.secondary_sequence.to_string() +
      " v=" +
      header.major_version.to_string() +
      "." +
      header.minor_version.to_string() +
      " type=" +
      header.file_type.label() +
      " format=" +
      header.file_format.to_string() +
      " root=" +
      header.root_cell_offset.to_string() +
      " bins=" +
      header.hive_bins_data_size.to_string() +
      " clustering=" +
      header.clustering_factor.to_string() +
      " name=" +
      header.file_name
    Err(error) => "err " + error.message()
  }
}

///|
/// True when parsing fails with a message ending in suffix.
fn fails_with(bytes : Bytes, suffix : String) -> Bool {
  match parse_header(bytes) {
    Ok(_) => false
    Err(error) => error.message().has_suffix(suffix)
  }
}

///|
/// True when the parsed checksum equals expected.
fn checksum_is(bytes : Bytes, expected : UInt32) -> Bool {
  match parse_header(bytes) {
    Ok(header) => header.checksum == expected
    Err(_) => false
  }
}

///|
/// True when the parsed file name equals expected.
fn name_is(bytes : Bytes, expected : String) -> Bool {
  match parse_header(bytes) {
    Ok(header) => header.file_name == expected
    Err(_) => false
  }
}

///|
/// True when the parsed file type is a log file.
fn type_is_log(bytes : Bytes) -> Bool {
  match parse_header(bytes) {
    Ok(header) => header.file_type.label() == "log"
    Err(_) => false
  }
}

///|
test "parses a base block shaped like a real hive" {
  let described = describe(Bytes::from_array(signed_block()))
  assert_eq(
    described, "ok seq=36/36 v=1.5 type=primary format=1 root=32 bins=184320 clustering=1 name=hive.dat",
  )
}

///|
test "the checksum field is outside the covered range" {
  let bytes = empty_base_block()
  put_signature(bytes)
  put_u32(bytes, 0x1FC, 0x66676572)
  assert_eq(checksum_is(Bytes::from_array(bytes), 0x66676572), true)
}

///|
test "rejects a corrupted checksum" {
  let bytes = empty_base_block()
  put_signature(bytes)
  assert_eq(fails_with(Bytes::from_array(bytes), "computed 0x66676572"), true)
}

///|
test "rejects a foreign signature" {
  let bytes = empty_base_block()
  put_u32(bytes, 0, 0x47454752)
  assert_eq(
    fails_with(
      Bytes::from_array(bytes),
      "unexpected signature 0x52474547, expected regf",
    ),
    true,
  )
}

///|
test "rejects an input shorter than the base block" {
  assert_eq(fails_with(Bytes::new(100), "the REGF base block needs 4096"), true)
}

///|
test "decodes a UTF-16LE file name" {
  let bytes = empty_base_block()
  put_signature(bytes)
  put_u32(bytes, 0x30, 0x65874E2D)
  let checksum = block_checksum(bytes)
  put_u32(bytes, 0x1FC, checksum)
  assert_eq(name_is(Bytes::from_array(bytes), "中文"), true)
}

///|
test "maps the file type code" {
  let bytes = signed_block()
  put_u32(bytes, 0x1C, 1)
  let checksum = block_checksum(bytes)
  put_u32(bytes, 0x1FC, checksum)
  assert_eq(type_is_log(Bytes::from_array(bytes)), true)
}

///|
test "reads hives labelled 1.3, 1.5 and 1.6" {
  let builder = HiveBuilder::new()
  builder.set_dword(0, "Count", 1)
  match builder.build() {
    Err(error) => assert_eq(error.message(), "built")
    Ok(bytes) => {
      let cases : Array[UInt32] = [3, 5, 6]
      let mut index = 0
      while index < cases.length() {
        let copy = bytes.to_array()
        w_i32(copy, 0x18, cases[index].reinterpret_as_int())
        let checksum = array_checksum(copy)
        w_i32(copy, 0x1FC, checksum.reinterpret_as_int())
        let patched = Bytes::from_array(copy)
        match parse_header(patched) {
          Err(error) => assert_eq(error.message(), "parsed")
          Ok(header) => {
            assert_eq(header.minor_version, cases[index])
            assert_eq(header.version_supported(), true)
            let entries = walk_key_tree(patched, header.root_cell_offset, 2)
            assert_eq(entries.length(), 1)
          }
        }
        index = index + 1
      }
    }
  }
}

///|
test "rejects a version outside 1.3 to 1.6" {
  let builder = HiveBuilder::new()
  match builder.build() {
    Err(error) => assert_eq(error.message(), "built")
    Ok(bytes) => {
      let copy = bytes.to_array()
      w_i32(copy, 0x18, 2)
      let checksum = array_checksum(copy)
      w_i32(copy, 0x1FC, checksum.reinterpret_as_int())
      match parse_header(Bytes::from_array(copy)) {
        Err(error) => assert_eq(error.message(), "parsed")
        Ok(header) => assert_eq(header.version_supported(), false)
      }
    }
  }
}
