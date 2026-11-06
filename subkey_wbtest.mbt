///|
/// Narrows an integer to a byte.
fn s_byte_of(value : Int32) -> Byte {
  (value & 0xFF).to_byte()
}

///|
/// Writes a 32-bit value as four little-endian bytes.
fn s_put_u32(bytes : Array[Byte], offset : Int32, value : Int32) -> Unit {
  bytes[offset] = s_byte_of(value & 0xFF)
  bytes[offset + 1] = s_byte_of((value >> 8) & 0xFF)
  bytes[offset + 2] = s_byte_of((value >> 16) & 0xFF)
  bytes[offset + 3] = s_byte_of((value >> 24) & 0xFF)
}

///|
/// Writes a 16-bit little-endian value.
fn s_put_u16(bytes : Array[Byte], offset : Int32, value : Int32) -> Unit {
  bytes[offset] = s_byte_of(value & 0xFF)
  bytes[offset + 1] = s_byte_of((value >> 8) & 0xFF)
}

///|
/// Writes one allocated nk cell with a compressed name.
fn s_nk_cell(
  bytes : Array[Byte],
  relative : Int32,
  name : String,
  flags : Int32,
  subkey_count : Int32,
  subkey_list : Int32,
  value_count : Int32,
) -> Unit {
  let encoded = @utf8.encode(name)
  let name_len = encoded.length()
  let total = (4 + 76 + name_len + 7) / 8 * 8
  let head = hive_bins_base + relative
  s_put_u32(bytes, head, -total)
  s_put_u16(bytes, head + 4, 0x6B6E)
  s_put_u16(bytes, head + 6, flags)
  s_put_u32(bytes, head + 4 + 16, -1)
  s_put_u32(bytes, head + 4 + 20, subkey_count)
  s_put_u32(bytes, head + 4 + 28, subkey_list)
  s_put_u32(bytes, head + 4 + 36, value_count)
  s_put_u16(bytes, head + 4 + 72, name_len)
  let mut index = 0
  while index < name_len {
    bytes[head + 4 + 76 + index] = encoded[index]
    index = index + 1
  }
}

///|
/// Writes one lf list cell; each entry is a key offset plus a hash word.
fn s_lf_cell(
  bytes : Array[Byte],
  relative : Int32,
  children : Array[Int32],
) -> Unit {
  let count = children.length()
  let total = (4 + 4 + count * 8 + 7) / 8 * 8
  let head = hive_bins_base + relative
  s_put_u32(bytes, head, -total)
  s_put_u16(bytes, head + 4, 0x666C)
  s_put_u16(bytes, head + 6, count)
  let mut index = 0
  while index < count {
    s_put_u32(bytes, head + 8 + index * 8, children[index])
    index = index + 1
  }
}

///|
/// Writes one index cell (li or ri); each entry is a 32-bit offset.
fn s_index_cell(
  bytes : Array[Byte],
  relative : Int32,
  signature : Int32,
  children : Array[Int32],
) -> Unit {
  let count = children.length()
  let total = (4 + 4 + count * 4 + 7) / 8 * 8
  let head = hive_bins_base + relative
  s_put_u32(bytes, head, -total)
  s_put_u16(bytes, head + 4, signature)
  s_put_u16(bytes, head + 6, count)
  let mut index = 0
  while index < count {
    s_put_u32(bytes, head + 8 + index * 4, children[index])
    index = index + 1
  }
}

///|
/// Builds a hive with this layout:
///
///   0x20  nk ROOT   subkeys=2 list=0x128
///   0x78  nk Alpha  subkeys=1 list=0x198
///   0xD0  nk Beta   subkeys=0
///   0x128 lf [0x78, 0xD0]
///   0x140 nk Gamma  subkeys=0
///   0x198 li [0x140]
///   0x1A8 ri [0x198]
fn s_hive() -> Array[Byte] {
  let bytes : Array[Byte] = Bytes::new(hive_bins_base * 2).to_array()
  s_nk_cell(bytes, 0x20, "ROOT", 0x2C, 2, 0x128, 0)
  s_nk_cell(bytes, 0x78, "Alpha", 0x2C, 1, 0x198, 0)
  s_nk_cell(bytes, 0xD0, "Beta", 0x2C, 0, -1, 2)
  s_lf_cell(bytes, 0x128, [0x78, 0xD0])
  s_nk_cell(bytes, 0x140, "Gamma", 0x2C, 0, -1, 0)
  s_index_cell(bytes, 0x198, 0x696C, [0x140])
  s_index_cell(bytes, 0x1A8, 0x6972, [0x198])
  bytes
}

///|
/// Renders a subkey list record.
fn s_describe_list(bytes : Bytes, offset : UInt32) -> String {
  match read_subkey_list(bytes, offset) {
    Ok(list) =>
      list.kind.label() +
      " count=" +
      list.count.to_string() +
      " children=" +
      list.key_offsets.length().to_string()
    Err(error) => "err " + error.message()
  }
}

///|
/// Renders the names of a key's direct children.
fn s_describe_children(bytes : Bytes, key_offset : UInt32) -> String {
  match parse_key_node(bytes, key_offset) {
    Err(error) => "err " + error.message()
    Ok(key) =>
      match list_subkeys(bytes, key) {
        Err(error) => "err " + error.message()
        Ok(children) => {
          let mut text = ""
          let mut index = 0
          while index < children.length() {
            if index > 0 {
              text = text + ","
            }
            text = text + children[index].name
            index = index + 1
          }
          text
        }
      }
  }
}

///|
/// Renders the paths of a tree walk joined with commas.
fn s_describe_walk(bytes : Bytes, depth : Int32) -> String {
  let entries = walk_key_tree(bytes, 0x20, depth)
  let mut text = ""
  let mut index = 0
  while index < entries.length() {
    if index > 0 {
      text = text + ","
    }
    text = text + entries[index].path
    index = index + 1
  }
  text
}

///|
test "reads an lf subkey list" {
  assert_eq(
    s_describe_list(Bytes::from_array(s_hive()), 0x128),
    "lf count=2 children=2",
  )
}

///|
test "reads an li subkey list" {
  assert_eq(
    s_describe_list(Bytes::from_array(s_hive()), 0x198),
    "li count=1 children=1",
  )
}

///|
test "expands an ri root index list" {
  assert_eq(
    s_describe_list(Bytes::from_array(s_hive()), 0x1A8),
    "ri count=1 children=1",
  )
}

///|
test "lists the children of the root key" {
  assert_eq(
    s_describe_children(Bytes::from_array(s_hive()), 0x20),
    "Alpha,Beta",
  )
}

///|
test "lists the children of a nested key" {
  assert_eq(s_describe_children(Bytes::from_array(s_hive()), 0x78), "Gamma")
}

///|
test "walks one level of the key tree" {
  assert_eq(
    s_describe_walk(Bytes::from_array(s_hive()), 1),
    "ROOT,ROOT/Alpha,ROOT/Beta",
  )
}

///|
test "walks nested key paths" {
  assert_eq(
    s_describe_walk(Bytes::from_array(s_hive()), 2),
    "ROOT,ROOT/Alpha,ROOT/Alpha/Gamma,ROOT/Beta",
  )
}

///|
test "rejects a cell that is not a subkey list" {
  let block = s_hive()
  block[hive_bins_base + 0x128 + 4] = s_byte_of(0x78)
  assert_eq(
    s_describe_list(Bytes::from_array(block), 0x128),
    "err cell at 296 is not a subkey list",
  )
}

///|
test "skips children whose key node is unreadable" {
  let block = s_hive()
  block[hive_bins_base + 0x78 + 4] = s_byte_of(0x78)
  assert_eq(s_describe_walk(Bytes::from_array(block), 2), "ROOT,ROOT/Beta")
}
