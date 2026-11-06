///|
/// Decodes bytes as UTF-8 with replacement.
fn re_text(value : Bytes) -> String {
  @utf8.decode_lossy(value.clamped_view(start=0, end=value.length()))
}

///|
/// Appends text as UTF-8 bytes.
fn re_push_text(buffer : Array[Byte], text : String) -> Unit {
  let encoded = @utf8.encode(text)
  let mut index = 0
  while index < encoded.length() {
    buffer.push(encoded[index])
    index = index + 1
  }
}

///|
/// Appends a carriage return and a line feed.
fn re_push_newline(buffer : Array[Byte]) -> Unit {
  buffer.push((13).to_byte())
  buffer.push((10).to_byte())
}

///|
/// Appends one byte as two lowercase hex digits.
fn re_push_hex(buffer : Array[Byte], value : Int32) -> Unit {
  let high = (value >> 4) & 0x0F
  let low = value & 0x0F
  if high < 10 {
    buffer.push((48 + high).to_byte())
  } else {
    buffer.push((97 + high - 10).to_byte())
  }
  if low < 10 {
    buffer.push((48 + low).to_byte())
  } else {
    buffer.push((97 + low - 10).to_byte())
  }
}

///|
/// Escapes backslashes and quotes of one name.
fn re_escape(text : String) -> String {
  let encoded = @utf8.encode(text)
  let out : Array[Byte] = []
  let mut index = 0
  while index < encoded.length() {
    let code = encoded[index].to_int()
    if code == 92 || code == 34 {
      out.push((92).to_byte())
    }
    out.push(encoded[index])
    index = index + 1
  }
  re_text(Bytes::from_array(out))
}

///|
/// Appends the name part of an assignment, using @ for the default value.
fn re_push_name(buffer : Array[Byte], name : String) -> Unit {
  if name == "" {
    buffer.push((64).to_byte())
  } else {
    buffer.push((34).to_byte())
    re_push_text(buffer, re_escape(name))
    buffer.push((34).to_byte())
  }
  buffer.push((61).to_byte())
}

///|
/// Appends the data part of an assignment in the .reg form of its type.
fn re_push_data(buffer : Array[Byte], value : HiveValue) -> Unit {
  match value.data_type {
    Sz => {
      let text = decode_utf16le(value.data, 0, value.data.length() / 2)
      buffer.push((34).to_byte())
      re_push_text(buffer, re_escape(text))
      buffer.push((34).to_byte())
    }
    Dword => {
      re_push_text(buffer, "dword:")
      let number = if value.data.length() >= 4 {
        read_u32_le(value.data, 0).reinterpret_as_int()
      } else {
        0
      }
      let mut shift = 28
      while shift >= 0 {
        let digit = (number >> shift) & 0x0F
        if digit < 10 {
          buffer.push((48 + digit).to_byte())
        } else {
          buffer.push((97 + digit - 10).to_byte())
        }
        shift = shift - 4
      }
    }
    _ => {
      let prefix = match value.data_type {
        Binary => "hex:"
        _ => "hex(" + value_type_code(value.data_type).to_string() + "):"
      }
      re_push_text(buffer, prefix)
      let mut index = 0
      while index < value.data.length() {
        if index > 0 {
          buffer.push((44).to_byte())
        }
        re_push_hex(buffer, value.data[index].to_int())
        index = index + 1
      }
    }
  }
}

///|
/// Section path: root_path followed by the key path below the hive root key.
///
/// The hive root key itself is not part of any registry path, so it is
/// dropped; the remaining segments are joined with backslashes.
fn re_section_path(path : String, root_path : String) -> String {
  let encoded = @utf8.encode(path)
  let out : Array[Byte] = []
  re_push_text(out, root_path)
  let mut index = 0
  let mut seen_root = false
  while index < encoded.length() {
    let code = encoded[index].to_int()
    if code == 47 {
      if !seen_root {
        seen_root = true
        if out.length() > 0 {
          out.push((92).to_byte())
        }
      } else {
        out.push((92).to_byte())
      }
    } else if seen_root {
      out.push(encoded[index])
    }
    index = index + 1
  }
  re_text(Bytes::from_array(out))
}

///|
/// Renders a hive as .reg text.
///
/// Every section path is root_path followed by the key path below the hive
/// root key, so a hive whose root holds Environment renders as
/// [HKEY_CURRENT_USER\Environment] when root_path is HKEY_CURRENT_USER.
pub fn export_reg_text(
  bytes : Bytes,
  root_path : String,
) -> Result[String, RegfError] {
  match parse_header(bytes) {
    Err(error) => Err(error)
    Ok(header) => {
      let out : Array[Byte] = []
      re_push_text(out, "Windows Registry Editor Version 5.00")
      re_push_newline(out)
      re_push_newline(out)
      let entries = walk_key_tree(bytes, header.root_cell_offset, 32)
      let mut index = 0
      while index < entries.length() {
        let entry = entries[index]
        out.push((91).to_byte())
        re_push_text(out, re_section_path(entry.path, root_path))
        out.push((93).to_byte())
        re_push_newline(out)
        match parse_key_node(bytes, entry.offset) {
          Err(_) => ()
          Ok(key) =>
            match value_offsets(bytes, key) {
              Err(_) => ()
              Ok(offsets) => {
                let mut inner = 0
                while inner < offsets.length() {
                  match parse_value(bytes, offsets[inner]) {
                    Err(_) => ()
                    Ok(value) => {
                      re_push_name(out, value.name)
                      re_push_data(out, value)
                      re_push_newline(out)
                    }
                  }
                  inner = inner + 1
                }
              }
            }
        }
        re_push_newline(out)
        index = index + 1
      }
      Ok(re_text(Bytes::from_array(out)))
    }
  }
}
