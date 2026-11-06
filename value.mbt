///|
/// Size of one segment in a big value, as stored by Windows.
let max_segment_size : Int32 = 16344

///|
/// Kind of data stored in a registry value.
pub(all) enum HiveValueType {
  Nil
  Sz
  ExpandSz
  Binary
  Dword
  DwordBigEndian
  Link
  MultiSz
  ResourceList
  FullResourceDescriptor
  ResourceRequirementsList
  Qword
  Unknown(UInt32)
}

///|
/// Maps the numeric type code stored in a vk record to a value type.
pub fn HiveValueType::from_code(code : UInt32) -> HiveValueType {
  match code.reinterpret_as_int() {
    0 => Nil
    1 => Sz
    2 => ExpandSz
    3 => Binary
    4 => Dword
    5 => DwordBigEndian
    6 => Link
    7 => MultiSz
    8 => ResourceList
    9 => FullResourceDescriptor
    10 => ResourceRequirementsList
    11 => Qword
    _ => Unknown(code)
  }
}

///|
/// Registry type name such as REG_SZ, as used by regedit and .reg files.
pub fn HiveValueType::label(self : HiveValueType) -> String {
  match self {
    Nil => "REG_NONE"
    Sz => "REG_SZ"
    ExpandSz => "REG_EXPAND_SZ"
    Binary => "REG_BINARY"
    Dword => "REG_DWORD"
    DwordBigEndian => "REG_DWORD_BIG_ENDIAN"
    Link => "REG_LINK"
    MultiSz => "REG_MULTI_SZ"
    ResourceList => "REG_RESOURCE_LIST"
    FullResourceDescriptor => "REG_FULL_RESOURCE_DESCRIPTOR"
    ResourceRequirementsList => "REG_RESOURCE_REQUIREMENTS_LIST"
    Qword => "REG_QWORD"
    Unknown(code) => "REG_UNKNOWN(0x" + code.to_string(radix=16) + ")"
  }
}

///|
/// A registry value (vk record) together with its resolved data.
///
/// inline_data is true when the four bytes of data_offset hold the data
/// itself, which Windows does for payloads of at most four bytes.
pub(all) struct HiveValue {
  offset : UInt32
  name : String
  data_type : HiveValueType
  data_size : UInt32
  data_offset : UInt32
  inline_data : Bool
  data : Bytes
}

///|
/// Copies count bytes starting at start into a fresh byte sequence.
fn copy_range(bytes : Bytes, start : Int32, count : Int32) -> Bytes {
  let out : Array[Byte] = []
  let mut index = 0
  while index < count {
    out.push(bytes[start + index])
    index = index + 1
  }
  Bytes::from_array(out)
}

///|
/// Reads the value list stored in the cell at offset.
///
/// A value list cell is a plain array of 32-bit vk offsets; it carries no
/// signature of its own.
pub fn read_value_list(
  bytes : Bytes,
  offset : UInt32,
) -> Result[Array[UInt32], RegfError] {
  let cell = match read_cell(bytes, offset) {
    Err(error) => return Err(error)
    Ok(entry) => entry
  }
  let relative = cell.offset.reinterpret_as_int()
  let count = cell.payload_size / 4
  let start = hive_bins_base + relative + 4
  let offsets : Array[UInt32] = []
  let mut index = 0
  while index < count {
    offsets.push(read_u32_le(bytes, start + index * 4))
    index = index + 1
  }
  Ok(offsets)
}

///|
/// Reads the data of a value, following inline payloads and big data records.
fn read_value_data(
  bytes : Bytes,
  value : HiveValue,
) -> Result[Bytes, RegfError] {
  let raw = value.data_size.reinterpret_as_int()
  let size = raw & 0x7FFFFFFF
  if size == 0 {
    return Ok(Bytes::new(0))
  }
  if raw < 0 {
    let packed = value.data_offset.reinterpret_as_int()
    let out : Array[Byte] = []
    let mut index = 0
    while index < size && index < 4 {
      out.push(((packed >> (index * 8)) & 0xFF).to_byte())
      index = index + 1
    }
    return Ok(Bytes::from_array(out))
  }
  if size > max_segment_size {
    return read_big_value_data(bytes, value.data_offset, size)
  }
  let cell = match read_cell(bytes, value.data_offset) {
    Err(error) => return Err(error)
    Ok(entry) => entry
  }
  let relative = cell.offset.reinterpret_as_int()
  if cell.payload_size < size {
    return Err(BadValueData(relative))
  }
  Ok(copy_range(bytes, hive_bins_base + relative + 4, size))
}

///|
/// Reads data stored in a db big data record, concatenating its segments.
fn read_big_value_data(
  bytes : Bytes,
  offset : UInt32,
  size : Int32,
) -> Result[Bytes, RegfError] {
  let cell = match read_cell(bytes, offset) {
    Err(error) => return Err(error)
    Ok(entry) => entry
  }
  let relative = cell.offset.reinterpret_as_int()
  if cell.payload_size < 8 {
    return Err(BadValueData(relative))
  }
  let start = hive_bins_base + relative + 4
  let first = bytes[start].to_int()
  let second = bytes[start + 1].to_int()
  if first != 0x64 || second != 0x62 {
    return Err(BadValueData(relative))
  }
  let segments = read_u16_le(bytes, start + 2).reinterpret_as_int()
  if 4 + segments * 4 > cell.payload_size {
    return Err(BadValueData(relative))
  }
  let joined : Array[Byte] = []
  let mut index = 0
  while index < segments && joined.length() < size {
    let segment = match
      read_cell(bytes, read_u32_le(bytes, start + 4 + index * 4)) {
      Err(error) => return Err(error)
      Ok(entry) => entry
    }
    let segment_start = hive_bins_base + segment.offset.reinterpret_as_int() + 4
    let remaining = size - joined.length()
    let available = if segment.payload_size < remaining {
      segment.payload_size
    } else {
      remaining
    }
    // Windows stores at most 16344 data bytes per segment; the rest of the cell is 8-byte padding.
    let take = if available < max_segment_size {
      available
    } else {
      max_segment_size
    }
    let mut inner = 0
    while inner < take {
      joined.push(bytes[segment_start + inner])
      inner = inner + 1
    }
    index = index + 1
  }
  if joined.length() < size {
    return Err(BadValueData(relative))
  }
  Ok(Bytes::from_array(joined))
}

///|
/// Parses the value record stored in the cell at offset and resolves its data.
pub fn parse_value(
  bytes : Bytes,
  offset : UInt32,
) -> Result[HiveValue, RegfError] {
  let cell = match read_cell(bytes, offset) {
    Err(error) => return Err(error)
    Ok(entry) => entry
  }
  let relative = cell.offset.reinterpret_as_int()
  if cell.payload_size < 20 {
    return Err(BadValue(relative))
  }
  let start = hive_bins_base + relative + 4
  let first = bytes[start].to_int()
  let second = bytes[start + 1].to_int()
  if first != 0x76 || second != 0x6B {
    return Err(BadValue(relative))
  }
  let name_length = read_u16_le(bytes, start + 2).reinterpret_as_int()
  if 20 + name_length > cell.payload_size {
    return Err(BadValue(relative))
  }
  let flags = read_u16_le(bytes, start + 16).reinterpret_as_int()
  let compressed = (flags & 0x0001) != 0
  let name = if compressed {
    decode_single_byte(bytes, start + 20, name_length)
  } else {
    decode_utf16le(bytes, start + 20, name_length / 2)
  }
  let data_size = read_u32_le(bytes, start + 4)
  let data_offset = read_u32_le(bytes, start + 8)
  let data_type = HiveValueType::from_code(read_u32_le(bytes, start + 12))
  let inline_data = data_size.reinterpret_as_int() < 0
  let provisional : HiveValue = {
    offset,
    name,
    data_type,
    data_size,
    data_offset,
    inline_data,
    data: Bytes::new(0),
  }
  let data = match read_value_data(bytes, provisional) {
    Err(error) => return Err(error)
    Ok(resolved) => resolved
  }
  let value : HiveValue = {
    offset,
    name,
    data_type,
    data_size,
    data_offset,
    inline_data,
    data,
  }
  Ok(value)
}

///|
/// Reads the vk offsets listed by a key, without parsing the values.
///
/// The lenient counterpart of list_values: callers that must survive hives
/// referencing volatile or freed cells can parse each offset on their own.
pub fn value_offsets(
  bytes : Bytes,
  key : HiveKeyNode,
) -> Result[Array[UInt32], RegfError] {
  let offsets : Array[UInt32] = []
  let count = key.value_count.reinterpret_as_int()
  if count <= 0 {
    return Ok(offsets)
  }
  if key.value_list_offset.reinterpret_as_int() == -1 {
    return Ok(offsets)
  }
  read_value_list(bytes, key.value_list_offset)
}

///|
/// Reads the values of a key in stored order.
///
/// This is the strict view: any unreadable value fails the whole call.
pub fn list_values(
  bytes : Bytes,
  key : HiveKeyNode,
) -> Result[Array[HiveValue], RegfError] {
  let values : Array[HiveValue] = []
  let offsets = match value_offsets(bytes, key) {
    Err(error) => return Err(error)
    Ok(list) => list
  }
  let mut index = 0
  while index < offsets.length() {
    match parse_value(bytes, offsets[index]) {
      Err(error) => return Err(error)
      Ok(value) => values.push(value)
    }
    index = index + 1
  }
  Ok(values)
}

///|
/// Interprets the data as a 32-bit integer when it holds at least four bytes.
pub fn HiveValue::as_u32(self : HiveValue) -> UInt32? {
  if self.data.length() < 4 {
    return None
  }
  Some(read_u32_le(self.data, 0))
}

///|
/// Decodes the data of a string typed value; the trailing NUL is dropped.
pub fn HiveValue::as_string(self : HiveValue) -> String? {
  match self.data_type {
    Sz => Some(decode_utf16le(self.data, 0, self.data.length() / 2))
    ExpandSz => Some(decode_utf16le(self.data, 0, self.data.length() / 2))
    Link => Some(decode_utf16le(self.data, 0, self.data.length() / 2))
    _ => None
  }
}

///|
/// Splits the data of a REG_MULTI_SZ value into its NUL separated entries.
pub fn HiveValue::as_multi_string(self : HiveValue) -> Array[String]? {
  match self.data_type {
    MultiSz => {
      let units = self.data.length() / 2
      let out : Array[String] = []
      let mut start = 0
      while start < units {
        let mut end = start
        while end < units {
          let low = self.data[end * 2].to_int()
          let high = self.data[end * 2 + 1].to_int()
          if (low | (high << 8)) == 0 {
            break
          }
          end = end + 1
        }
        if end > start {
          out.push(decode_utf16le(self.data, start * 2, end - start))
        }
        start = end + 1
      }
      Some(out)
    }
    _ => None
  }
}
