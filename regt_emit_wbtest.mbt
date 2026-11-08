///|
/// True when haystack contains needle.
fn xe_contains(haystack : String, needle : String) -> Bool {
  let hay = @utf8.encode(haystack)
  let key = @utf8.encode(needle)
  hay.find(key.clamped_view(start=0, end=key.length())) != None
}

///|
/// Builds the ten bytes of the REG_MULTI_SZ value A, B.
fn xe_multi() -> Bytes {
  let out : Array[Byte] = []
  out.push((0x41).to_byte())
  out.push((0).to_byte())
  out.push((0).to_byte())
  out.push((0).to_byte())
  out.push((0x42).to_byte())
  out.push((0).to_byte())
  out.push((0).to_byte())
  out.push((0).to_byte())
  out.push((0).to_byte())
  out.push((0).to_byte())
  Bytes::from_array(out)
}

///|
/// Builds a hive with one child key holding five values of different types.
fn xe_hive() -> Result[Bytes, RegfError] {
  let builder = HiveBuilder::new()
  let software = builder.add_key(0, "Software")
  builder.set_string(software, "Greeting", "Hello")
  builder.set_dword(software, "Count", 42)
  let blob : Array[Byte] = [(0).to_byte(), (1).to_byte(), (255).to_byte()]
  builder.set_value(software, "Blob", Binary, Bytes::from_array(blob))
  builder.set_value(software, "List", MultiSz, xe_multi())
  builder.set_value(software, "Target", ExpandSz, encode_utf16le("%TEMP%"))
  builder.build()
}

///|
/// Renders the sample hive as .reg text prefixed with HKEY_CURRENT_USER.
fn xe_export() -> Result[String, RegfError] {
  match xe_hive() {
    Err(error) => Err(error)
    Ok(bytes) => export_reg_text(bytes, "HKEY_CURRENT_USER")
  }
}

///|
/// Exports the sample hive, parses the text back and rebuilds it, reporting
/// how much survived the round trip.
fn xe_round_trip() -> String {
  match xe_export() {
    Err(error) => "export err " + error.message()
    Ok(text) =>
      match parse_reg_file(text) {
        Err(error) => "parse err " + error.message()
        Ok(file) =>
          match file.to_builder() {
            Err(error) => "builder err " + error.message()
            Ok(builder) =>
              match builder.build() {
                Err(error) => "rebuild err " + error.message()
                Ok(_) =>
                  "ok sections=" +
                  file.section_count().to_string() +
                  " values=" +
                  file.value_count().to_string() +
                  " keys=" +
                  builder.key_count().to_string()
              }
          }
      }
  }
}

///|
test "exports a hive back into reg text" {
  assert_eq(xe_round_trip(), "ok sections=2 values=5 keys=2")
}

///|
test "renders dwords in the regedit form" {
  match xe_export() {
    Err(error) => assert_eq(error.message(), "exported")
    Ok(text) => assert_eq(xe_contains(text, "dword:0000002a"), true)
  }
}

///|
test "renders multi strings and expand strings as hex" {
  match xe_export() {
    Err(error) => assert_eq(error.message(), "exported")
    Ok(text) => {
      assert_eq(xe_contains(text, "hex(7):41,00,00,00,42,00,00,00,00,00"), true)
      assert_eq(xe_contains(text, "hex(2):"), true)
    }
  }
}

///|
test "prefixes sections with the requested root" {
  match xe_export() {
    Err(error) => assert_eq(error.message(), "exported")
    Ok(text) => assert_eq(xe_contains(text, "[HKEY_CURRENT_USER"), true)
  }
}

///|
test "exports the default value with the at sign" {
  let builder = HiveBuilder::new()
  builder.set_string(0, "", "plain")
  match builder.build() {
    Err(error) => assert_eq(error.message(), "built")
    Ok(bytes) =>
      match export_reg_text(bytes, "HKEY_CURRENT_USER") {
        Err(error) => assert_eq(error.message(), "exported")
        Ok(text) => assert_eq(xe_contains(text, "@="), true)
      }
  }
}
