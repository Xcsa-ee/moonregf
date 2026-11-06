///|
/// Renders one ASCII code point below 128 as a one-byte string.
fn ascii_char(code : Int32) -> String {
  let out : Array[Byte] = [(code & 0x7F).to_byte()]
  let encoded = Bytes::from_array(out)
  @utf8.decode_lossy(encoded.clamped_view(start=0, end=encoded.length()))
}

///|
/// Backslash, the path separator of .reg files.
fn bs() -> String {
  ascii_char(92)
}

///|
/// Double quote, used around names and text values.
fn dq() -> String {
  ascii_char(34)
}

///|
/// CRLF, the line ending regedit writes.
fn crlf() -> String {
  ascii_char(13) + ascii_char(10)
}

///|
/// Builds a .reg document covering every value form.
fn rp_sample() -> String {
  let lines : Array[String] = [
    "Windows Registry Editor Version 5.00",
    "",
    "[" + "HKEY_CURRENT_USER" + bs() + "Software" + "]",
    ascii_char(64) + "=" + dq() + "hello" + dq(),
    dq() + "Count" + dq() + "=dword:0000002a",
    dq() + "Blob" + dq() + "=hex:00,01,02",
    dq() + "Wide" + dq() + "=hex(2):25,00,41,00",
    dq() + "Big" + dq() + "=hex:1f," + bs() + crlf() + "  20",
    dq() + "Temp" + dq() + "=hex(7):41,00,00,00",
    "",
  ]
  let mut text = ""
  let mut index = 0
  while index < lines.length() {
    text = text + lines[index] + crlf()
    index = index + 1
  }
  text
}

///|
/// Finds a value by name across all sections.
fn rp_find(file : RegFile, name : String) -> RegValue? {
  let mut index = 0
  while index < file.sections.length() {
    let values = file.sections[index].values
    let mut inner = 0
    while inner < values.length() {
      if values[inner].name == name {
        return Some(values[inner])
      }
      inner = inner + 1
    }
    index = index + 1
  }
  None
}

///|
/// Counts every value reachable from the root key of a hive.
fn rp_value_count(bytes : Bytes) -> Int32 {
  match parse_header(bytes) {
    Err(_) => -1
    Ok(header) => {
      let entries = walk_key_tree(bytes, header.root_cell_offset, 4)
      let mut total = 0
      let mut index = 0
      while index < entries.length() {
        match parse_key_node(bytes, entries[index].offset) {
          Ok(key) =>
            match list_values(bytes, key) {
              Ok(values) => total = total + values.length()
              Err(_) => ()
            }
          Err(_) => ()
        }
        index = index + 1
      }
      total
    }
  }
}

///|
/// True when haystack contains needle.
fn rp_contains(haystack : String, needle : String) -> Bool {
  let hay = @utf8.encode(haystack)
  let key = @utf8.encode(needle)
  hay.find(key.clamped_view(start=0, end=key.length())) != None
}

///|
test "parses every value form of a reg document" {
  match parse_reg_file(rp_sample()) {
    Err(error) => assert_eq(error.message(), "parsed")
    Ok(file) => {
      assert_eq(file.section_count(), 1)
      assert_eq(file.value_count(), 6)
      match rp_find(file, "") {
        Some(value) => {
          assert_eq(value.data_type.label(), "REG_SZ")
          assert_eq(value.data.length(), 10)
        }
        None => assert_eq("found", "missing")
      }
      match rp_find(file, "Count") {
        Some(value) => {
          assert_eq(value.data_type.label(), "REG_DWORD")
          assert_eq(value.data.length(), 4)
          assert_eq(value.data[0].to_int(), 42)
        }
        None => assert_eq("found", "missing")
      }
      match rp_find(file, "Blob") {
        Some(value) => {
          assert_eq(value.data_type.label(), "REG_BINARY")
          assert_eq(value.data.length(), 3)
        }
        None => assert_eq("found", "missing")
      }
      match rp_find(file, "Wide") {
        Some(value) => {
          assert_eq(value.data_type.label(), "REG_EXPAND_SZ")
          assert_eq(value.data.length(), 4)
        }
        None => assert_eq("found", "missing")
      }
      match rp_find(file, "Big") {
        Some(value) => {
          assert_eq(value.data.length(), 2)
          assert_eq(value.data[0].to_int(), 31)
          assert_eq(value.data[1].to_int(), 32)
        }
        None => assert_eq("found", "missing")
      }
      match rp_find(file, "Temp") {
        Some(value) => assert_eq(value.data_type.label(), "REG_MULTI_SZ")
        None => assert_eq("found", "missing")
      }
    }
  }
}

///|
test "imports a reg document into a hive" {
  match parse_reg_file(rp_sample()) {
    Err(error) => assert_eq(error.message(), "parsed")
    Ok(file) =>
      match file.to_builder() {
        Err(error) => assert_eq(error.message(), "built")
        Ok(builder) =>
          match builder.build() {
            Err(error) => assert_eq(error.message(), "built")
            Ok(bytes) => assert_eq(rp_value_count(bytes), 6)
          }
      }
  }
}

///|
test "parses UTF-16LE reg bytes" {
  let body = encode_utf16le(rp_sample())
  let out : Array[Byte] = [(0xFF).to_byte(), (0xFE).to_byte()]
  let mut index = 0
  while index < body.length() {
    out.push(body[index])
    index = index + 1
  }
  match parse_reg_bytes(Bytes::from_array(out)) {
    Err(error) => assert_eq(error.message(), "parsed")
    Ok(file) => assert_eq(file.value_count(), 6)
  }
}

///|
test "rejects a value line before the first section" {
  let text = dq() + "x" + dq() + "=" + dq() + "y" + dq() + crlf()
  match parse_reg_file(text) {
    Err(error) =>
      assert_eq(
        rp_contains(error.message(), "value line before the first section"),
        true,
      )
    Ok(_) => assert_eq("parsed", "rejected")
  }
}

///|
test "reports delete sections instead of dropping them" {
  let text = "Windows Registry Editor Version 5.00" +
    crlf() +
    crlf() +
    "[-HKEY_CURRENT_USER" +
    bs() +
    "Software]" +
    crlf()
  match parse_reg_file(text) {
    Err(error) => assert_eq(error.message(), "parsed")
    Ok(file) =>
      match file.to_builder() {
        Err(error) =>
          assert_eq(rp_contains(error.message(), "is not supported yet"), true)
        Ok(_) => assert_eq("built", "rejected")
      }
  }
}
