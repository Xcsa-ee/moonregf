///|
/// Narrows an integer to a byte.
fn w_byte(value : Int32) -> Byte {
  (value & 0xFF).to_byte()
}

///|
/// Writes a 32-bit value as four little-endian bytes.
fn w_put_u32(bytes : Array[Byte], offset : Int32, value : Int32) -> Unit {
  bytes[offset] = w_byte(value & 0xFF)
  bytes[offset + 1] = w_byte((value >> 8) & 0xFF)
  bytes[offset + 2] = w_byte((value >> 16) & 0xFF)
  bytes[offset + 3] = w_byte((value >> 24) & 0xFF)
}

///|
/// Writes a 16-bit little-endian value.
fn w_put_u16(bytes : Array[Byte], offset : Int32, value : Int32) -> Unit {
  bytes[offset] = w_byte(value & 0xFF)
  bytes[offset + 1] = w_byte((value >> 8) & 0xFF)
}

///|
/// Writes one allocated nk cell carrying a value list.
fn w_nk(
  bytes : Array[Byte],
  relative : Int32,
  name : String,
  value_count : Int32,
  value_list : Int32,
) -> Unit {
  let encoded = @utf8.encode(name)
  let name_len = encoded.length()
  let total = (4 + 76 + name_len + 7) / 8 * 8
  let head = hive_bins_base + relative
  w_put_u32(bytes, head, -total)
  w_put_u16(bytes, head + 4, 0x6B6E)
  w_put_u16(bytes, head + 6, 0x2C)
  w_put_u32(bytes, head + 4 + 16, -1)
  w_put_u32(bytes, head + 4 + 28, -1)
  w_put_u32(bytes, head + 4 + 36, value_count)
  w_put_u32(bytes, head + 4 + 40, value_list)
  w_put_u16(bytes, head + 4 + 72, name_len)
  let mut index = 0
  while index < name_len {
    bytes[head + 4 + 76 + index] = encoded[index]
    index = index + 1
  }
}

///|
/// Writes one value list cell holding vk offsets.
fn w_value_list(
  bytes : Array[Byte],
  relative : Int32,
  offsets : Array[Int32],
) -> Unit {
  let count = offsets.length()
  let total = (4 + count * 4 + 7) / 8 * 8
  let head = hive_bins_base + relative
  w_put_u32(bytes, head, -total)
  let mut index = 0
  while index < count {
    w_put_u32(bytes, head + 4 + index * 4, offsets[index])
    index = index + 1
  }
}

///|
/// Writes one allocated vk cell with a compressed name.
fn w_vk(
  bytes : Array[Byte],
  relative : Int32,
  name : String,
  type_code : Int32,
  data_size : Int32,
  data_offset : Int32,
) -> Unit {
  let encoded = @utf8.encode(name)
  let name_len = encoded.length()
  let total = (4 + 20 + name_len + 7) / 8 * 8
  let head = hive_bins_base + relative
  w_put_u32(bytes, head, -total)
  w_put_u16(bytes, head + 4, 0x6B76)
  w_put_u16(bytes, head + 6, name_len)
  w_put_u32(bytes, head + 4 + 4, data_size)
  w_put_u32(bytes, head + 4 + 8, data_offset)
  w_put_u32(bytes, head + 4 + 12, type_code)
  w_put_u16(bytes, head + 4 + 16, 0x0001)
  let mut index = 0
  while index < name_len {
    bytes[head + 4 + 20 + index] = encoded[index]
    index = index + 1
  }
}

///|
/// Writes one allocated data cell from explicit byte values.
fn w_data(
  bytes : Array[Byte],
  relative : Int32,
  payload : Array[Int32],
) -> Unit {
  let count = payload.length()
  let total = (4 + count + 7) / 8 * 8
  let head = hive_bins_base + relative
  w_put_u32(bytes, head, -total)
  let mut index = 0
  while index < count {
    bytes[head + 4 + index] = w_byte(payload[index])
    index = index + 1
  }
}

///|
/// Writes one allocated cell filled with a repeated byte value.
fn w_fill_cell(
  bytes : Array[Byte],
  relative : Int32,
  count : Int32,
  value : Int32,
) -> Unit {
  let total = (4 + count + 7) / 8 * 8
  let head = hive_bins_base + relative
  w_put_u32(bytes, head, -total)
  let mut index = 0
  while index < count {
    bytes[head + 4 + index] = w_byte(value)
    index = index + 1
  }
}

///|
/// Builds a hive with one key holding three values:
///
///   0x100 vk Count  REG_DWORD     inline 42
///   0x140 vk Path   REG_SZ        6 bytes at 0x200 (Hi and a NUL)
///   0x180 vk Multi  REG_MULTI_SZ  10 bytes at 0x240 (A, B)
fn w_hive() -> Array[Byte] {
  let bytes : Array[Byte] = Bytes::new(hive_bins_base * 2).to_array()
  w_nk(bytes, 0x20, "ROOT", 3, 0x80)
  w_value_list(bytes, 0x80, [0x100, 0x140, 0x180])
  w_vk(bytes, 0x100, "Count", 4, -2147483644, 42)
  w_vk(bytes, 0x140, "Path", 1, 6, 0x200)
  w_vk(bytes, 0x180, "Multi", 7, 10, 0x240)
  w_data(bytes, 0x200, [0x48, 0x00, 0x69, 0x00, 0x00, 0x00])
  w_data(bytes, 0x240, [
    0x41, 0x00, 0x00, 0x00, 0x42, 0x00, 0x00, 0x00, 0x00, 0x00,
  ])
  bytes
}

///|
/// Builds a hive with one value larger than one segment (16360 bytes), stored
/// as a db record with two segments of 16344 and 16 bytes.
fn w_big_hive() -> Array[Byte] {
  let bytes : Array[Byte] = Bytes::new(4096 + 0x4400).to_array()
  w_nk(bytes, 0x20, "ROOT", 1, 0x80)
  w_value_list(bytes, 0x80, [0x100])
  w_vk(bytes, 0x100, "Blob", 3, 16360, 0x200)
  let head = hive_bins_base + 0x200
  w_put_u32(bytes, head, -16)
  w_put_u16(bytes, head + 4, 0x6264)
  w_put_u16(bytes, head + 6, 2)
  w_put_u32(bytes, head + 8, 0x300)
  w_put_u32(bytes, head + 12, 0x4300)
  w_fill_cell(bytes, 0x300, 16344, 0xAA)
  w_fill_cell(bytes, 0x4300, 16, 0xBB)
  bytes
}

///|
/// Renders name, type and resolved data length of a value.
fn w_describe(bytes : Bytes, offset : UInt32) -> String {
  match parse_value(bytes, offset) {
    Ok(value) =>
      "ok name=" +
      value.name +
      " type=" +
      value.data_type.label() +
      " size=" +
      value.data.length().to_string() +
      " inline=" +
      value.inline_data.to_string()
    Err(error) => "err " + error.message()
  }
}

///|
/// Renders the 32-bit integer of a value.
fn w_u32(bytes : Bytes, offset : UInt32) -> String {
  match parse_value(bytes, offset) {
    Ok(value) =>
      match value.as_u32() {
        Some(number) => "u32=" + number.to_string()
        None => "u32=none"
      }
    Err(error) => "err " + error.message()
  }
}

///|
/// Renders the decoded string of a value.
fn w_string(bytes : Bytes, offset : UInt32) -> String {
  match parse_value(bytes, offset) {
    Ok(value) =>
      match value.as_string() {
        Some(text) => "str=" + text
        None => "str=none"
      }
    Err(error) => "err " + error.message()
  }
}

///|
/// Renders the entries of a multi string value joined with commas.
fn w_multi(bytes : Bytes, offset : UInt32) -> String {
  match parse_value(bytes, offset) {
    Ok(value) =>
      match value.as_multi_string() {
        Some(items) => {
          let mut text = "multi="
          let mut index = 0
          while index < items.length() {
            if index > 0 {
              text = text + ","
            }
            text = text + items[index]
            index = index + 1
          }
          text
        }
        None => "multi=none"
      }
    Err(error) => "err " + error.message()
  }
}

///|
/// Renders the names of the values of a key.
fn w_value_names(bytes : Bytes, key_offset : UInt32) -> String {
  match parse_key_node(bytes, key_offset) {
    Err(error) => "err " + error.message()
    Ok(key) =>
      match list_values(bytes, key) {
        Err(error) => "err " + error.message()
        Ok(values) => {
          let mut text = ""
          let mut index = 0
          while index < values.length() {
            if index > 0 {
              text = text + ","
            }
            text = text + values[index].name
            index = index + 1
          }
          text
        }
      }
  }
}

///|
/// Renders the resolved bytes of the big value at 0x100.
fn w_big(bytes : Bytes) -> String {
  match parse_value(bytes, 0x100) {
    Ok(value) =>
      "len=" +
      value.data.length().to_string() +
      " first=" +
      value.data[0].to_uint().to_string() +
      " edge=" +
      value.data[16343].to_uint().to_string() +
      " next=" +
      value.data[16344].to_uint().to_string()
    Err(error) => "err " + error.message()
  }
}

///|
test "parses an inline dword value" {
  assert_eq(
    w_describe(Bytes::from_array(w_hive()), 0x100),
    "ok name=Count type=REG_DWORD size=4 inline=true",
  )
}

///|
test "reads the integer stored inline" {
  assert_eq(w_u32(Bytes::from_array(w_hive()), 0x100), "u32=42")
}

///|
test "decodes a REG_SZ value" {
  assert_eq(w_string(Bytes::from_array(w_hive()), 0x140), "str=Hi")
}

///|
test "decodes a REG_MULTI_SZ value" {
  assert_eq(w_multi(Bytes::from_array(w_hive()), 0x180), "multi=A,B")
}

///|
test "lists the values of a key in stored order" {
  assert_eq(
    w_value_names(Bytes::from_array(w_hive()), 0x20),
    "Count,Path,Multi",
  )
}

///|
test "joins the segments of a big value" {
  assert_eq(
    w_big(Bytes::from_array(w_big_hive())),
    "len=16360 first=170 edge=170 next=187",
  )
}

///|
test "rejects a cell that is not a value record" {
  let block = w_hive()
  block[hive_bins_base + 0x100 + 4] = w_byte(0x78)
  assert_eq(
    w_describe(Bytes::from_array(block), 0x100),
    "err cell at 256 is not a value record",
  )
}

///|
test "rejects a value whose data cell is too small" {
  let block = w_hive()
  w_put_u32(block, hive_bins_base + 0x200, -8)
  assert_eq(
    w_string(Bytes::from_array(block), 0x140),
    "err cell at 512 cannot hold the value data",
  )
}

///|
test "maps type codes to registry type names" {
  assert_eq(HiveValueType::from_code(2).label(), "REG_EXPAND_SZ")
  assert_eq(HiveValueType::from_code(11).label(), "REG_QWORD")
  assert_eq(HiveValueType::from_code(99).label(), "REG_UNKNOWN(0x63)")
}
