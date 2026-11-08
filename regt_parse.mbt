///|
/// One value read from a .reg file.
pub(all) struct RegValue {
  name : String
  data_type : HiveValueType
  data : Bytes
}

///|
/// One [path] section of a .reg file.
pub(all) struct RegSection {
  path : String
  delete : Bool
  values : Array[RegValue]
}

///|
/// A parsed .reg document.
pub(all) struct RegFile {
  sections : Array[RegSection]
}

///|
/// One logical line of a .reg file and the index to resume from.
priv struct RegLine {
  buffer : Array[Byte]
  next : Int32
}

///|
/// Quoted text and the index just after the closing quote.
priv struct QuotedText {
  text : String
  next : Int32
}

///|
/// Number of sections in the document.
pub fn RegFile::section_count(self : RegFile) -> Int32 {
  self.sections.length()
}

///|
/// Number of values across all sections.
pub fn RegFile::value_count(self : RegFile) -> Int32 {
  let mut total = 0
  let mut index = 0
  while index < self.sections.length() {
    total = total + self.sections[index].values.length()
    index = index + 1
  }
  total
}

///|
/// True for a space or tab byte.
fn is_space_code(code : Int32) -> Bool {
  code == 32 || code == 9
}

///|
/// Lowercases one ASCII byte code.
fn lowercase_code(code : Int32) -> Int32 {
  if code >= 65 && code <= 90 {
    code + 32
  } else {
    code
  }
}

///|
/// Value of a hex digit byte, or -1 when it is not a digit.
fn hex_value(code : Int32) -> Int32 {
  if code >= 48 && code <= 57 {
    code - 48
  } else if code >= 97 && code <= 102 {
    code - 87
  } else if code >= 65 && code <= 70 {
    code - 55
  } else {
    -1
  }
}

///|
/// Index of target within [start, limit), if present.
fn find_byte(
  source : Bytes,
  start : Int32,
  limit : Int32,
  target : Int32,
) -> Int32? {
  let mut index = start
  while index < limit {
    if source[index].to_int() == target {
      return Some(index)
    }
    index = index + 1
  }
  None
}

///|
/// Decodes bytes[start, end) as UTF-8 with replacement.
fn text_of_slice(source : Bytes, start : Int32, end : Int32) -> String {
  @utf8.decode_lossy(source.clamped_view(start~, end~))
}

///|
/// Decodes a byte buffer as UTF-8 with replacement.
fn text_of(buffer : Array[Byte]) -> String {
  let encoded = Bytes::from_array(buffer)
  text_of_slice(encoded, 0, encoded.length())
}

///|
/// True when the ASCII word appears at index, ignoring case.
fn has_word_at(
  source : Bytes,
  index : Int32,
  limit : Int32,
  word : String,
) -> Bool {
  let encoded = @utf8.encode(word)
  if index + encoded.length() > limit {
    return false
  }
  let mut cursor = 0
  while cursor < encoded.length() {
    if lowercase_code(source[index + cursor].to_int()) !=
      lowercase_code(encoded[cursor].to_int()) {
      return false
    }
    cursor = cursor + 1
  }
  true
}

///|
/// Parses a quoted string starting at start.
fn parse_quoted(source : Bytes, start : Int32, limit : Int32) -> QuotedText? {
  if start >= limit || source[start].to_int() != 34 {
    return None
  }
  let buffer : Array[Byte] = []
  let mut index = start + 1
  while index < limit {
    let code = source[index].to_int()
    if code == 92 && index + 1 < limit {
      buffer.push(source[index + 1])
      index = index + 2
    } else if code == 34 {
      let parsed : QuotedText = { text: text_of(buffer), next: index + 1, }
      return Some(parsed)
    } else {
      buffer.push(source[index])
      index = index + 1
    }
  }
  None
}

///|
/// Parses a comma separated hex byte list.
fn parse_hex_bytes(
  source : Bytes,
  start : Int32,
  limit : Int32,
) -> Array[Byte]? {
  let out : Array[Byte] = []
  let mut index = start
  let mut high = -1
  while index < limit {
    let code = source[index].to_int()
    if code == 44 || is_space_code(code) {
      index = index + 1
    } else {
      let digit = hex_value(code)
      if digit < 0 {
        return None
      }
      if high < 0 {
        high = digit
      } else {
        out.push(((high * 16 + digit) & 0xFF).to_byte())
        high = -1
      }
      index = index + 1
    }
  }
  if high >= 0 {
    return None
  }
  Some(out)
}

///|
/// Parses a decimal integer, stopping at the first non digit.
fn decimal_between(source : Bytes, start : Int32, limit : Int32) -> Int32? {
  let mut value = 0
  let mut digits = 0
  let mut index = start
  let mut stop = false
  while index < limit && !stop {
    let code = source[index].to_int()
    if code >= 48 && code <= 57 {
      value = value * 10 + (code - 48)
      digits = digits + 1
      index = index + 1
    } else {
      stop = true
    }
  }
  if digits == 0 {
    None
  } else {
    Some(value)
  }
}

///|
/// Parses up to eight hex digits into four little-endian bytes.
fn parse_dword_bytes(
  source : Bytes,
  start : Int32,
  limit : Int32,
) -> Array[Byte]? {
  let digits : Array[Int32] = []
  let mut index = start
  let mut stop = false
  while index < limit && !stop {
    let code = source[index].to_int()
    let digit = hex_value(code)
    if is_space_code(code) {
      index = index + 1
    } else if digit >= 0 {
      digits.push(digit)
      index = index + 1
    } else {
      stop = true
    }
  }
  if digits.length() == 0 || digits.length() > 8 {
    return None
  }
  let padded : Array[Int32] = []
  let mut pad = 8 - digits.length()
  while pad > 0 {
    padded.push(0)
    pad = pad - 1
  }
  let mut cursor = 0
  while cursor < digits.length() {
    padded.push(digits[cursor])
    cursor = cursor + 1
  }
  let out : Array[Byte] = []
  out.push(((padded[6] * 16 + padded[7]) & 0xFF).to_byte())
  out.push(((padded[4] * 16 + padded[5]) & 0xFF).to_byte())
  out.push(((padded[2] * 16 + padded[3]) & 0xFF).to_byte())
  out.push(((padded[0] * 16 + padded[1]) & 0xFF).to_byte())
  Some(out)
}

///|
/// Maps a .reg hex type suffix to a hive value type.
fn type_from_int(code : Int32) -> HiveValueType {
  let low = (code & 0xFF).to_byte()
  HiveValueType::from_code(low.to_uint())
}

///|
/// Parses one value line into a RegValue.
fn parse_value_line(source : Bytes, start : Int32, limit : Int32) -> RegValue? {
  let mut index = start
  let mut name : String = ""
  if index < limit && source[index].to_int() == 64 {
    index = index + 1
  } else if index < limit && source[index].to_int() == 34 {
    let quoted = parse_quoted(source, index, limit)
    match quoted {
      Some(value) => {
        name = value.text
        index = value.next
      }
      None => return None
    }
  } else {
    return None
  }
  if index >= limit || source[index].to_int() != 61 {
    return None
  }
  index = index + 1
  if index >= limit {
    return None
  }
  if source[index].to_int() == 34 {
    let quoted = parse_quoted(source, index, limit)
    match quoted {
      Some(value) => {
        let parsed : RegValue = {
          name,
          data_type: Sz,
          data: encode_utf16le(value.text),
        }
        return Some(parsed)
      }
      None => return None
    }
  }
  if has_word_at(source, index, limit, "dword:") {
    let body = parse_dword_bytes(source, index + 6, limit)
    match body {
      Some(bytes) => {
        let parsed : RegValue = {
          name,
          data_type: Dword,
          data: Bytes::from_array(bytes),
        }
        return Some(parsed)
      }
      None => return None
    }
  }
  if has_word_at(source, index, limit, "hex") {
    let mut cursor = index + 3
    let mut type_code = 3
    if cursor < limit && source[cursor].to_int() == 40 {
      let close = find_byte(source, cursor + 1, limit, 41)
      match close {
        Some(position) => {
          let code = decimal_between(source, cursor + 1, position)
          match code {
            Some(value) => {
              type_code = value
              cursor = position + 1
            }
            None => return None
          }
        }
        None => return None
      }
    }
    if cursor >= limit || source[cursor].to_int() != 58 {
      return None
    }
    let body = parse_hex_bytes(source, cursor + 1, limit)
    match body {
      Some(bytes) => {
        let parsed : RegValue = {
          name,
          data_type: type_from_int(type_code),
          data: Bytes::from_array(bytes),
        }
        return Some(parsed)
      }
      None => return None
    }
  }
  None
}

///|
/// Reads one logical line, joining continuations that end with a backslash.
fn next_reg_line(source : Bytes, start : Int32, limit : Int32) -> RegLine {
  let buffer : Array[Byte] = []
  let mut position = start
  let mut done = false
  while !done && position < limit {
    let mut stop = position
    while stop < limit {
      let code = source[stop].to_int()
      if code == 13 || code == 10 {
        break
      }
      stop = stop + 1
    }
    let continues = stop > position && source[stop - 1].to_int() == 92
    let copy_end = if continues { stop - 1 } else { stop }
    let mut cursor = position
    while cursor < copy_end {
      buffer.push(source[cursor])
      cursor = cursor + 1
    }
    position = stop
    if continues {
      if position < limit && source[position].to_int() == 13 {
        position = position + 1
      }
      if position < limit && source[position].to_int() == 10 {
        position = position + 1
      }
    } else {
      done = true
    }
  }
  if done {
    if position < limit && source[position].to_int() == 13 {
      position = position + 1
    }
    if position < limit && source[position].to_int() == 10 {
      position = position + 1
    }
  }
  { buffer, next: position, }
}

///|
/// Parses .reg text into sections and values.
pub fn parse_reg_file(text : String) -> Result[RegFile, RegfError] {
  let source = @utf8.encode(text)
  let limit = source.length()
  let sections : Array[RegSection] = []
  let mut current : Int32? = None
  let mut position = 0
  if limit >= 3 &&
    source[0].to_int() == 0xEF &&
    source[1].to_int() == 0xBB &&
    source[2].to_int() == 0xBF {
    position = 3
  }
  while position < limit {
    let line = next_reg_line(source, position, limit)
    position = line.next
    let bytes = Bytes::from_array(line.buffer)
    let mut from = 0
    let mut to = bytes.length()
    while from < to && is_space_code(bytes[from].to_int()) {
      from = from + 1
    }
    while to > from && is_space_code(bytes[to - 1].to_int()) {
      to = to - 1
    }
    if from >= to {
      let _ = from
    } else if bytes[from].to_int() == 59 {
      let _ = from
    } else if bytes[from].to_int() == 91 {
      let close = find_byte(bytes, from + 1, to, 93)
      match close {
        Some(end) => {
          let mut path_start = from + 1
          let mut delete = false
          if path_start < end && bytes[path_start].to_int() == 45 {
            delete = true
            path_start = path_start + 1
          }
          let section : RegSection = {
            path: text_of_slice(bytes, path_start, end),
            delete,
            values: [],
          }
          sections.push(section)
          current = Some(sections.length() - 1)
        }
        None =>
          return Err(BadRegFile("section header without a closing bracket"))
      }
    } else {
      let section_index = match current {
        Some(at) => at
        None => -1
      }
      if section_index >= 0 {
        let value = parse_value_line(bytes, from, to)
        match value {
          Some(parsed) => sections[section_index].values.push(parsed)
          None =>
            return Err(
              BadRegFile(
                "cannot parse the value line: " + text_of_slice(bytes, from, to),
              ),
            )
        }
      } else if has_word_at(bytes, from, to, "windows registry editor") ||
        has_word_at(bytes, from, to, "regedit") {
        let _ = from
      } else {
        return Err(BadRegFile("value line before the first section"))
      }
    }
  }
  let parsed : RegFile = { sections, }
  Ok(parsed)
}

///|
/// Parses .reg text from raw file bytes, honouring UTF-16LE and UTF-8 byte order marks.
pub fn parse_reg_bytes(raw : Bytes) -> Result[RegFile, RegfError] {
  let size = raw.length()
  if size >= 2 && raw[0].to_int() == 0xFF && raw[1].to_int() == 0xFE {
    return parse_reg_file(decode_utf16le(raw, 2, (size - 2) / 2))
  }
  if size >= 3 &&
    raw[0].to_int() == 0xEF &&
    raw[1].to_int() == 0xBB &&
    raw[2].to_int() == 0xBF {
    return parse_reg_file(text_of_slice(raw, 3, size))
  }
  parse_reg_file(text_of_slice(raw, 0, size))
}

///|
/// Splits a .reg path into its segments.
fn split_path(path : String) -> Array[String] {
  let source = @utf8.encode(path)
  let segments : Array[String] = []
  let mut start = 0
  let mut index = 0
  while index < source.length() {
    if source[index].to_int() == 92 {
      if index > start {
        segments.push(text_of_slice(source, start, index))
      }
      start = index + 1
    }
    index = index + 1
  }
  if index > start {
    segments.push(text_of_slice(source, start, index))
  }
  segments
}

///|
/// Builds a hive from the document.
///
/// The first path segment of each section (the predefined root such as
/// HKEY_CURRENT_USER) is dropped, so the remaining path hangs off the hive
/// root key. Delete sections are reported instead of being dropped silently.
pub fn RegFile::to_builder(self : RegFile) -> Result[HiveBuilder, RegfError] {
  let builder = HiveBuilder::new()
  let mut index = 0
  while index < self.sections.length() {
    let section = self.sections[index]
    if section.delete {
      return Err(UnsupportedDelete(section.path))
    }
    let segments = split_path(section.path)
    let mut key_index = 0
    let mut segment = 1
    while segment < segments.length() {
      let name = segments[segment]
      match builder.child_index(key_index, name) {
        Some(existing) => key_index = existing
        None => key_index = builder.add_key(key_index, name)
      }
      segment = segment + 1
    }
    let mut value_index = 0
    while value_index < section.values.length() {
      let value = section.values[value_index]
      builder.set_value(key_index, value.name, value.data_type, value.data)
      value_index = value_index + 1
    }
    index = index + 1
  }
  Ok(builder)
}
