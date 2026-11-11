///|
/// A parsed self-relative security descriptor.
pub(all) struct SecurityDescriptor {
  revision : Int32
  control : Int32
  owner : String
  group : String
  has_sacl : Bool
  has_dacl : Bool
  dacl : Array[Ace]
}

///|
/// Appends a little-endian 32-bit value.
fn push_u32(out : Array[Byte], value : Int32) -> Unit {
  out.push((value & 0xFF).to_byte())
  out.push(((value >> 8) & 0xFF).to_byte())
  out.push(((value >> 16) & 0xFF).to_byte())
  out.push(((value >> 24) & 0xFF).to_byte())
}

///|
/// Parses a decimal byte range, returning -1 when it holds a non-digit.
fn parse_decimal(bytes : Bytes, start : Int32, stop : Int32) -> Int32 {
  if start >= stop {
    return -1
  }
  let mut value = 0
  let mut index = start
  while index < stop {
    let code = bytes[index].to_int()
    if code < 0x30 || code > 0x39 {
      return -1
    }
    value = value * 10 + (code - 0x30)
    index = index + 1
  }
  value
}

///|
/// Turns a SID string such as S-1-5-18 into its binary form.
///
/// The binary form is one revision byte, one sub authority count byte, a six
/// byte big-endian identifier authority and the sub authorities as u32 LE.
pub fn sid_from_string(text : String) -> Result[Bytes, RegfError] {
  let raw = @utf8.encode(text)
  let parts : Array[Int32] = []
  let mut start = 0
  let mut index = 0
  let mut first = true
  while index <= raw.length() {
    let at_end = index == raw.length()
    if at_end || raw[index].to_int() == 0x2D {
      if index > start {
        let code = raw[start].to_int()
        if first && (code == 0x53 || code == 0x73) {
          first = false
        } else {
          first = false
          let value = parse_decimal(raw, start, index)
          if value < 0 {
            return Err(BadSecurityDescriptor("invalid SID " + text))
          }
          parts.push(value)
        }
      }
      start = index + 1
    }
    index = index + 1
  }
  if parts.length() < 2 {
    return Err(BadSecurityDescriptor("invalid SID " + text))
  }
  let out : Array[Byte] = []
  out.push((parts[0] & 0xFF).to_byte())
  out.push(((parts.length() - 2) & 0xFF).to_byte())
  let authority = parts[1]
  out.push((0).to_byte())
  out.push((0).to_byte())
  out.push(((authority >> 24) & 0xFF).to_byte())
  out.push(((authority >> 16) & 0xFF).to_byte())
  out.push(((authority >> 8) & 0xFF).to_byte())
  out.push((authority & 0xFF).to_byte())
  let mut sub = 2
  while sub < parts.length() {
    push_u32(out, parts[sub])
    sub = sub + 1
  }
  Ok(Bytes::from_array(out))
}

///|
/// Renders the binary SID at offset as S-1-5-... form.
pub fn sid_to_string(bytes : Bytes, offset : Int32) -> String {
  if offset < 0 || offset + 8 > bytes.length() {
    return ""
  }
  let revision = bytes[offset].to_int()
  let count = bytes[offset + 1].to_int()
  let mut authority : Int64 = 0
  let mut index = 0
  while index < 6 {
    authority = authority * 256 + bytes[offset + 2 + index].to_int().to_int64()
    index = index + 1
  }
  let mut text = "S-" + revision.to_string() + "-" + authority.to_string()
  index = 0
  while index < count && offset + 8 + index * 4 + 4 <= bytes.length() {
    let sub = read_u32_le(bytes, offset + 8 + index * 4)
    text = text + "-" + sub.to_string()
    index = index + 1
  }
  text
}

///|
/// Parses the self-relative security descriptor stored at offset.
pub fn parse_security_descriptor(
  bytes : Bytes,
  offset : Int32,
) -> Result[SecurityDescriptor, RegfError] {
  if offset < 0 || offset + 20 > bytes.length() {
    return Err(BadSecurityDescriptor("descriptor is truncated"))
  }
  let revision = bytes[offset].to_int()
  let control = read_u16_le(bytes, offset + 2).reinterpret_as_int()
  let owner_offset = read_u32_le(bytes, offset + 4).reinterpret_as_int()
  let group_offset = read_u32_le(bytes, offset + 8).reinterpret_as_int()
  let sacl_offset = read_u32_le(bytes, offset + 12).reinterpret_as_int()
  let dacl_offset = read_u32_le(bytes, offset + 16).reinterpret_as_int()
  let owner = if owner_offset > 0 {
    sid_to_string(bytes, offset + owner_offset)
  } else {
    ""
  }
  let group = if group_offset > 0 {
    sid_to_string(bytes, offset + group_offset)
  } else {
    ""
  }
  let dacl = if dacl_offset > 0 {
    match parse_acl(bytes, offset + dacl_offset) {
      Err(_) => []
      Ok(entries) => entries
    }
  } else {
    []
  }
  Ok({
    revision,
    control,
    owner,
    group,
    has_sacl: sacl_offset > 0,
    has_dacl: dacl_offset > 0,
    dacl,
  })
}

///|
/// Reads the sk record a key points at and parses its descriptor.
pub fn describe_security(
  bytes : Bytes,
  key : HiveKeyNode,
) -> Result[SecurityDescriptor, RegfError] {
  let relative = key.security_offset.reinterpret_as_int()
  if relative < 0 {
    return Err(BadSecurityDescriptor("the key has no sk record"))
  }
  let cell = match read_cell(bytes, key.security_offset) {
    Err(error) => return Err(error)
    Ok(parsed) => parsed
  }
  let head = hive_bins_base + relative + 4
  if read_u16_le(bytes, head) != 0x6B73 {
    return Err(BadSecurityDescriptor("the cell is not an sk record"))
  }
  let size = read_u32_le(bytes, head + 16).reinterpret_as_int()
  if size < 0 || head + 20 + size > bytes.length() || size > cell.payload_size {
    return Err(BadSecurityDescriptor("the sk payload is out of bounds"))
  }
  parse_security_descriptor(bytes, head + 20)
}

///|
/// Builds a self-relative descriptor that only carries an owner and a group.
pub fn security_descriptor_with_owner_group(
  owner : String,
  group : String,
) -> Result[Bytes, RegfError] {
  let owner_sid = match sid_from_string(owner) {
    Err(error) => return Err(error)
    Ok(parsed) => parsed
  }
  let group_sid = match sid_from_string(group) {
    Err(error) => return Err(error)
    Ok(parsed) => parsed
  }
  let out : Array[Byte] = []
  out.push((1).to_byte())
  out.push((0).to_byte())
  out.push((0x00).to_byte())
  out.push((0x80).to_byte())
  push_u32(out, 20)
  push_u32(out, 20 + owner_sid.length())
  push_u32(out, 0)
  push_u32(out, 0)
  let mut index = 0
  while index < owner_sid.length() {
    out.push(owner_sid[index])
    index = index + 1
  }
  index = 0
  while index < group_sid.length() {
    out.push(group_sid[index])
    index = index + 1
  }
  Ok(Bytes::from_array(out))
}

///|
/// Returns the raw self-relative descriptor a key points at, or empty bytes.
pub fn security_bytes_of(bytes : Bytes, key : HiveKeyNode) -> Bytes {
  let relative = key.security_offset.reinterpret_as_int()
  if relative < 0 {
    return Bytes::new(0)
  }
  match read_cell(bytes, key.security_offset) {
    Err(_) => Bytes::new(0)
    Ok(cell) => {
      let head = hive_bins_base + relative + 4
      if read_u16_le(bytes, head) != 0x6B73 {
        return Bytes::new(0)
      }
      let size = read_u32_le(bytes, head + 16).reinterpret_as_int()
      if size <= 0 || size > cell.payload_size - 20 {
        return Bytes::new(0)
      }
      copy_range(bytes, head + 20, size)
    }
  }
}
