///|
/// Largest payload the writer stores in a single data cell.
let max_value_size : Int32 = 16344

///|
/// A value waiting to be written into a hive.
struct BuildValue {
  name : String
  data_type : HiveValueType
  data : Bytes
}

///|
/// A tree of keys and values that build() turns into a REGF hive.
///
/// Nodes are addressed by index; node 0 is the root key.
pub struct HiveBuilder {
  names : Array[String]
  parents : Array[Int32]
  children : Array[Array[Int32]]
  values : Array[Array[BuildValue]]
}

///|
/// Rounds a byte count up to the next multiple of eight.
fn align8(value : Int32) -> Int32 {
  (value + 7) / 8 * 8
}

///|
/// Total size of a cell whose payload holds payload_size bytes.
fn cell_size(payload_size : Int32) -> Int32 {
  let total = align8(4 + payload_size)
  if total < 8 {
    8
  } else {
    total
  }
}

///|
/// Writes a signed 32-bit value as four little-endian bytes.
fn w_i32(bytes : Array[Byte], offset : Int32, value : Int32) -> Unit {
  bytes[offset] = (value & 0xFF).to_byte()
  bytes[offset + 1] = ((value >> 8) & 0xFF).to_byte()
  bytes[offset + 2] = ((value >> 16) & 0xFF).to_byte()
  bytes[offset + 3] = ((value >> 24) & 0xFF).to_byte()
}

///|
/// Writes a 16-bit value as two little-endian bytes.
fn w_u16(bytes : Array[Byte], offset : Int32, value : Int32) -> Unit {
  bytes[offset] = (value & 0xFF).to_byte()
  bytes[offset + 1] = ((value >> 8) & 0xFF).to_byte()
}

///|
/// Copies raw bytes to offset.
fn w_bytes(bytes : Array[Byte], offset : Int32, source : Bytes) -> Unit {
  let mut index = 0
  while index < source.length() {
    bytes[offset + index] = source[index]
    index = index + 1
  }
}

///|
/// Writes ASCII bytes as UTF-16LE code units.
fn w_utf16le_ascii(bytes : Array[Byte], offset : Int32, source : Bytes) -> Unit {
  let mut index = 0
  while index < source.length() {
    bytes[offset + index * 2] = source[index]
    bytes[offset + index * 2 + 1] = (0).to_byte()
    index = index + 1
  }
}

///|
/// True when every byte is ASCII.
fn is_ascii(bytes : Bytes) -> Bool {
  let mut index = 0
  while index < bytes.length() {
    if bytes[index].to_int() >= 0x80 {
      return false
    }
    index = index + 1
  }
  true
}

///|
/// Builds an array holding count zeros.
fn zero_ints(count : Int32) -> Array[Int32] {
  let out : Array[Int32] = []
  let mut index = 0
  while index < count {
    out.push(0)
    index = index + 1
  }
  out
}

///|
/// XOR checksum over the first 508 bytes of a byte array.
fn array_checksum(bytes : Array[Byte]) -> UInt32 {
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
/// Uppercases up to four ASCII bytes into a little-endian lf hint.
fn name_hint(name : Bytes) -> Int32 {
  let mut hint = 0
  let mut index = 0
  while index < name.length() && index < 4 {
    let mut byte = name[index].to_int()
    if byte >= 0x61 && byte <= 0x7A {
      byte = byte - 0x20
    }
    hint = hint | (byte << (index * 8))
    index = index + 1
  }
  hint
}

///|
/// Numeric type code stored in a vk record.
fn value_type_code(data_type : HiveValueType) -> Int32 {
  match data_type {
    Nil => 0
    Sz => 1
    ExpandSz => 2
    Binary => 3
    Dword => 4
    DwordBigEndian => 5
    Link => 6
    MultiSz => 7
    ResourceList => 8
    FullResourceDescriptor => 9
    ResourceRequirementsList => 10
    Qword => 11
    Unknown(code) => code.reinterpret_as_int()
  }
}

///|
/// Longest key name among the given children.
fn longest_child_name(names : Array[String], children : Array[Int32]) -> Int32 {
  let mut longest = 0
  let mut index = 0
  while index < children.length() {
    let length = @utf8.encode(names[children[index]]).length()
    if length > longest {
      longest = length
    }
    index = index + 1
  }
  longest
}

///|
/// Longest value name of one key.
fn longest_value_name(names : Array[Bytes]) -> Int32 {
  let mut longest = 0
  let mut index = 0
  while index < names.length() {
    if names[index].length() > longest {
      longest = names[index].length()
    }
    index = index + 1
  }
  longest
}

///|
/// Largest value payload of one key.
fn largest_value_size(values : Array[BuildValue]) -> Int32 {
  let mut largest = 0
  let mut index = 0
  while index < values.length() {
    if values[index].data.length() > largest {
      largest = values[index].data.length()
    }
    index = index + 1
  }
  largest
}

///|
/// Creates a builder holding a single root key called ROOT.
pub fn HiveBuilder::new() -> HiveBuilder {
  HiveBuilder::new_named("ROOT")
}

///|
/// Creates a builder whose root key uses root_name.
pub fn HiveBuilder::new_named(root_name : String) -> HiveBuilder {
  let names : Array[String] = [root_name]
  let parents : Array[Int32] = [-1]
  let children : Array[Array[Int32]] = []
  children.push([])
  let values : Array[Array[BuildValue]] = []
  values.push([])
  { names, parents, children, values, }
}

///|
/// Number of keys in the tree.
pub fn HiveBuilder::key_count(self : HiveBuilder) -> Int32 {
  self.names.length()
}

///|
/// Adds a child key under parent and returns its index.
pub fn HiveBuilder::add_key(
  self : HiveBuilder,
  parent : Int32,
  name : String,
) -> Int32 {
  let index = self.names.length()
  self.names.push(name)
  self.parents.push(parent)
  self.children.push([])
  self.values.push([])
  self.children[parent].push(index)
  index
}

///|
/// Stores one value under the key at key_index.
pub fn HiveBuilder::set_value(
  self : HiveBuilder,
  key_index : Int32,
  name : String,
  data_type : HiveValueType,
  data : Bytes,
) -> Unit {
  let value : BuildValue = { name, data_type, data, }
  self.values[key_index].push(value)
}

///|
/// Stores a REG_SZ value holding text.
pub fn HiveBuilder::set_string(
  self : HiveBuilder,
  key_index : Int32,
  name : String,
  text : String,
) -> Unit {
  let encoded = @utf8.encode(text)
  let terminated : Array[Byte] = []
  let mut cursor = 0
  while cursor < encoded.length() {
    terminated.push(encoded[cursor])
    cursor = cursor + 1
  }
  terminated.push((0).to_byte())
  terminated.push((0).to_byte())
  self.set_value(key_index, name, Sz, Bytes::from_array(terminated))
}

///|
/// Stores a REG_DWORD value.
pub fn HiveBuilder::set_dword(
  self : HiveBuilder,
  key_index : Int32,
  name : String,
  value : Int32,
) -> Unit {
  let out : Array[Byte] = []
  out.push((value & 0xFF).to_byte())
  out.push(((value >> 8) & 0xFF).to_byte())
  out.push(((value >> 16) & 0xFF).to_byte())
  out.push(((value >> 24) & 0xFF).to_byte())
  self.set_value(key_index, name, Dword, Bytes::from_array(out))
}

///|
/// Serializes the tree into a REGF hive file.
///
/// The layout is the one Windows uses: a 4096-byte base block, then one or
/// more hive bins whose cells carry the nk, vk and lf records. Key names must
/// be ASCII and a value payload must fit in one data cell (16344 bytes).
pub fn HiveBuilder::build(self : HiveBuilder) -> Result[Bytes, RegfError] {
  let count = self.names.length()
  let names : Array[Bytes] = []
  let mut index = 0
  while index < count {
    let encoded = @utf8.encode(self.names[index])
    if !is_ascii(encoded) {
      return Err(UnsupportedName(index))
    }
    names.push(encoded)
    index = index + 1
  }
  let value_names : Array[Array[Bytes]] = []
  index = 0
  while index < count {
    let per_key : Array[Bytes] = []
    let mut inner = 0
    while inner < self.values[index].length() {
      let encoded = @utf8.encode(self.values[index][inner].name)
      if !is_ascii(encoded) {
        return Err(UnsupportedName(index))
      }
      if self.values[index][inner].data.length() > max_value_size {
        return Err(ValueTooLarge(self.values[index][inner].data.length()))
      }
      per_key.push(encoded)
      inner = inner + 1
    }
    value_names.push(per_key)
    index = index + 1
  }
  let nk_offsets = zero_ints(count)
  let value_list_offsets = zero_ints(count)
  let subkey_list_offsets = zero_ints(count)
  let vk_offsets : Array[Array[Int32]] = []
  let data_offsets : Array[Array[Int32]] = []
  index = 0
  while index < count {
    vk_offsets.push([])
    data_offsets.push([])
    index = index + 1
  }
  let mut cursor = 32
  index = 0
  while index < count {
    nk_offsets[index] = cursor
    cursor = cursor + cell_size(76 + names[index].length())
    let value_count = self.values[index].length()
    if value_count > 0 {
      value_list_offsets[index] = cursor
      cursor = cursor + cell_size(value_count * 4)
    } else {
      value_list_offsets[index] = -1
    }
    let mut inner = 0
    while inner < value_count {
      vk_offsets[index].push(cursor)
      cursor = cursor + cell_size(20 + value_names[index][inner].length())
      let length = self.values[index][inner].data.length()
      if length > 4 {
        data_offsets[index].push(cursor)
        cursor = cursor + cell_size(length)
      } else {
        data_offsets[index].push(-1)
      }
      inner = inner + 1
    }
    let child_count = self.children[index].length()
    if child_count > 0 {
      subkey_list_offsets[index] = cursor
      cursor = cursor + cell_size(4 + 8 * child_count)
    } else {
      subkey_list_offsets[index] = -1
    }
    index = index + 1
  }
  let bin_size = (cursor + 4095) / 4096 * 4096
  let file = Bytes::new(base_block_size + bin_size).to_array()
  w_i32(file, 0, 0x66676572)
  w_i32(file, 0x04, 1)
  w_i32(file, 0x08, 1)
  w_i32(file, 0x14, 1)
  w_i32(file, 0x18, 5)
  w_i32(file, 0x1C, 0)
  w_i32(file, 0x20, 1)
  w_i32(file, 0x24, nk_offsets[0])
  w_i32(file, 0x28, bin_size)
  w_i32(file, 0x2C, 1)
  let label = if names[0].length() > 32 {
    @utf8.encode("hive")
  } else {
    names[0]
  }
  w_utf16le_ascii(file, 0x30, label)
  let checksum = array_checksum(file)
  w_i32(file, 0x1FC, checksum.reinterpret_as_int())
  w_i32(file, base_block_size, 0x6E696268)
  w_i32(file, base_block_size + 4, 0)
  w_i32(file, base_block_size + 8, bin_size)
  index = 0
  while index < count {
    let offset = nk_offsets[index]
    let name = names[index]
    let total = cell_size(76 + name.length())
    w_i32(file, base_block_size + offset, -total)
    let head = base_block_size + offset + 4
    w_u16(file, head, 0x6B6E)
    let flags = if index == 0 { 0x2C } else { 0x20 }
    w_u16(file, head + 2, flags)
    let parent = if index == 0 { -1 } else { nk_offsets[self.parents[index]] }
    w_i32(file, head + 16, parent)
    w_i32(file, head + 20, self.children[index].length())
    w_i32(file, head + 24, 0)
    w_i32(file, head + 28, subkey_list_offsets[index])
    w_i32(file, head + 32, -1)
    w_i32(file, head + 36, self.values[index].length())
    w_i32(file, head + 40, value_list_offsets[index])
    w_i32(file, head + 44, -1)
    w_i32(file, head + 48, -1)
    w_i32(file, head + 52, longest_child_name(self.names, self.children[index]))
    w_i32(file, head + 56, 0)
    w_i32(file, head + 60, longest_value_name(value_names[index]))
    w_i32(file, head + 64, largest_value_size(self.values[index]))
    w_i32(file, head + 68, 0)
    w_u16(file, head + 72, name.length())
    w_u16(file, head + 74, 0)
    w_bytes(file, head + 76, name)
    let value_count = self.values[index].length()
    if value_list_offsets[index] >= 0 {
      let list_total = cell_size(value_count * 4)
      w_i32(file, base_block_size + value_list_offsets[index], -list_total)
      let list_head = base_block_size + value_list_offsets[index] + 4
      let mut inner = 0
      while inner < value_count {
        w_i32(file, list_head + inner * 4, vk_offsets[index][inner])
        inner = inner + 1
      }
    }
    let mut inner = 0
    while inner < value_count {
      let value = self.values[index][inner]
      let value_name = value_names[index][inner]
      let vk = vk_offsets[index][inner]
      let total_vk = cell_size(20 + value_name.length())
      w_i32(file, base_block_size + vk, -total_vk)
      let vk_head = base_block_size + vk + 4
      w_u16(file, vk_head, 0x6B76)
      w_u16(file, vk_head + 2, value_name.length())
      let length = value.data.length()
      if length == 0 {
        w_i32(file, vk_head + 4, 0)
        w_i32(file, vk_head + 8, -1)
      } else if length <= 4 {
        w_i32(file, vk_head + 4, -length)
        let mut packed = 0
        let mut byte = 0
        while byte < length {
          packed = packed | (value.data[byte].to_int() << (byte * 8))
          byte = byte + 1
        }
        w_i32(file, vk_head + 8, packed)
      } else {
        w_i32(file, vk_head + 4, length)
        w_i32(file, vk_head + 8, data_offsets[index][inner])
      }
      w_i32(file, vk_head + 12, value_type_code(value.data_type))
      w_u16(file, vk_head + 16, 0x0001)
      w_u16(file, vk_head + 18, 0)
      w_bytes(file, vk_head + 20, value_name)
      if length > 4 {
        let data_total = cell_size(length)
        let data_offset = data_offsets[index][inner]
        w_i32(file, base_block_size + data_offset, -data_total)
        w_bytes(file, base_block_size + data_offset + 4, value.data)
      }
      inner = inner + 1
    }
    let child_count = self.children[index].length()
    if subkey_list_offsets[index] >= 0 {
      let list_total = cell_size(4 + 8 * child_count)
      w_i32(file, base_block_size + subkey_list_offsets[index], -list_total)
      let list_head = base_block_size + subkey_list_offsets[index] + 4
      w_u16(file, list_head, 0x666C)
      w_u16(file, list_head + 2, child_count)
      let mut child = 0
      while child < child_count {
        let child_index = self.children[index][child]
        w_i32(file, list_head + 4 + child * 8, nk_offsets[child_index])
        w_i32(file, list_head + 8 + child * 8, name_hint(names[child_index]))
        child = child + 1
      }
    }
    index = index + 1
  }
  Ok(Bytes::from_array(file))
}
