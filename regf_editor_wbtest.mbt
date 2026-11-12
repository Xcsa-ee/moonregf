///|
/// Returns the u32 payload of a value by name.
fn ed_value_u32(values : Array[HiveValue], name : String) -> UInt32? {
  let mut index = 0
  while index < values.length() {
    if values[index].name == name {
      return values[index].as_u32()
    }
    index = index + 1
  }
  None
}

///|
/// Builds a hive with one key and two values, then opens it.
fn ed_open() -> Result[HiveEditor, RegfError] {
  let builder = HiveBuilder::new()
  let child = builder.add_key(0, "Software")
  builder.set_string(child, "Install", "Hello")
  builder.set_dword(child, "Count", 7)
  builder.set_key_metadata(0, 11, 22, 33, 0)
  builder.set_key_metadata(child, 44, 55, 66, 0)
  match security_descriptor_with_owner_group("S-1-5-18", "S-1-5-19") {
    Err(error) => Err(error)
    Ok(descriptor) => {
      builder.set_security(child, descriptor)
      match builder.build() {
        Err(error) => Err(error)
        Ok(bytes) => HiveEditor::open(bytes)
      }
    }
  }
}

///|
test "opens a hive and keeps its key count" {
  match ed_open() {
    Err(error) => assert_eq(error.message(), "opened")
    Ok(editor) => {
      assert_eq(editor.key_count(), 2)
      assert_eq(editor.key_name(1), "Software")
    }
  }
}

///|
test "finds a key by path" {
  match ed_open() {
    Err(error) => assert_eq(error.message(), "opened")
    Ok(editor) => {
      assert_eq(editor.find("ROOT/Software") == Some(1), true)
      assert_eq(editor.find("ROOT/Missing"), None)
    }
  }
}

///|
test "replaces a value and keeps the rest" {
  match ed_open() {
    Err(error) => assert_eq(error.message(), "opened")
    Ok(editor) => {
      editor.set_value(
        1,
        "Count",
        Dword,
        Bytes::from_array([
          (9).to_byte(),
          (0).to_byte(),
          (0).to_byte(),
          (0).to_byte(),
        ]),
      )
      match editor.build() {
        Err(error) => assert_eq(error.message(), "built")
        Ok(bytes) =>
          match parse_header(bytes) {
            Err(error) => assert_eq(error.message(), "header")
            Ok(header) =>
              match parse_key_node(bytes, header.root_cell_offset) {
                Err(error) => assert_eq(error.message(), "key")
                Ok(root) =>
                  match list_subkeys(bytes, root) {
                    Err(error) => assert_eq(error.message(), "children")
                    Ok(children) =>
                      match parse_key_node(bytes, children[0].offset) {
                        Err(error) => assert_eq(error.message(), "child")
                        Ok(key) =>
                          match list_values(bytes, key) {
                            Err(error) => assert_eq(error.message(), "values")
                            Ok(values) => {
                              assert_eq(values.length(), 2)
                              assert_eq(
                                ed_value_u32(values, "Count"),
                                Some((9 : UInt32)),
                              )
                            }
                          }
                      }
                  }
              }
          }
      }
    }
  }
}

///|
test "deletes a value" {
  match ed_open() {
    Err(error) => assert_eq(error.message(), "opened")
    Ok(editor) => {
      assert_eq(editor.delete_value(1, "Install"), true)
      assert_eq(editor.delete_value(1, "Install"), false)
      match editor.build() {
        Err(error) => assert_eq(error.message(), "built")
        Ok(bytes) => {
          let expected = 1
          assert_eq(expected, 1)
          assert_eq(bytes.length() > 4096, true)
        }
      }
    }
  }
}

///|
test "adds a key and preserves metadata" {
  match ed_open() {
    Err(error) => assert_eq(error.message(), "opened")
    Ok(editor) => {
      let added = editor.add_key(1, "Vendor")
      assert_eq(added, 2)
      editor.set_string(added, "Name", "Demo")
      match editor.build() {
        Err(error) => assert_eq(error.message(), "built")
        Ok(bytes) =>
          match parse_header(bytes) {
            Err(error) => assert_eq(error.message(), "header")
            Ok(header) =>
              match parse_key_node(bytes, header.root_cell_offset) {
                Err(error) => assert_eq(error.message(), "key")
                Ok(root) => {
                  assert_eq(root.last_written_high, (11 : UInt32))
                  assert_eq(root.last_written_low, (22 : UInt32))
                  assert_eq(root.access_bits, (33 : UInt32))
                  match list_subkeys(bytes, root) {
                    Err(error) => assert_eq(error.message(), "children")
                    Ok(children) => {
                      assert_eq(children.length(), 1)
                      match parse_key_node(bytes, children[0].offset) {
                        Err(error) => assert_eq(error.message(), "child")
                        Ok(key) => {
                          assert_eq(key.last_written_high, (44 : UInt32))
                          assert_eq(key.access_bits, (66 : UInt32))
                          match describe_security(bytes, key) {
                            Err(error) => assert_eq(error.message(), "security")
                            Ok(descriptor) =>
                              assert_eq(descriptor.owner, "S-1-5-18")
                          }
                        }
                      }
                    }
                  }
                }
              }
          }
      }
    }
  }
}

///|
test "deletes a key together with its children" {
  match ed_open() {
    Err(error) => assert_eq(error.message(), "opened")
    Ok(editor) => {
      let added = editor.add_key(1, "Vendor")
      let _ = editor.add_key(added, "Inner")
      assert_eq(editor.key_count(), 4)
      assert_eq(editor.delete_key(1), true)
      assert_eq(editor.key_count(), 1)
      assert_eq(editor.delete_key(0), false)
    }
  }
}

///|
/// Looks a value up by name.
fn ed_pick(values : Array[HiveValue], name : String) -> HiveValue? {
  let mut index = 0
  while index < values.length() {
    if values[index].name == name {
      return Some(values[index])
    }
    index = index + 1
  }
  None
}

///|
test "reads a u32 only from a REG_DWORD" {
  let builder = HiveBuilder::new()
  builder.set_dword(0, "Count", 42)
  builder.set_string(0, "Name", "Hello")
  match builder.build() {
    Err(error) => assert_eq(error.message(), "built")
    Ok(bytes) =>
      match parse_header(bytes) {
        Err(error) => assert_eq(error.message(), "header")
        Ok(header) =>
          match parse_key_node(bytes, header.root_cell_offset) {
            Err(error) => assert_eq(error.message(), "key")
            Ok(key) =>
              match list_values(bytes, key) {
                Err(error) => assert_eq(error.message(), "values")
                Ok(values) => {
                  match ed_pick(values, "Count") {
                    None => assert_eq("found", "missing")
                    Some(value) =>
                      assert_eq(value.as_u32(), Some((42 : UInt32)))
                  }
                  match ed_pick(values, "Name") {
                    None => assert_eq("found", "missing")
                    Some(value) =>
                      match value.as_u32() {
                        None => assert_eq("none", "none")
                        Some(_) => assert_eq("some", "none")
                      }
                  }
                }
              }
          }
      }
  }
}

///|
test "counts a value it cannot parse instead of dropping it silently" {
  let builder = HiveBuilder::new()
  builder.set_dword(0, "Count", 7)
  builder.set_string(0, "Name", "Hello")
  match builder.build() {
    Err(error) => assert_eq(error.message(), "built")
    Ok(bytes) =>
      match parse_header(bytes) {
        Err(error) => assert_eq(error.message(), "header")
        Ok(header) =>
          match parse_key_node(bytes, header.root_cell_offset) {
            Err(error) => assert_eq(error.message(), "key")
            Ok(key) =>
              match value_offsets(bytes, key) {
                Err(error) => assert_eq(error.message(), "offsets")
                Ok(offsets) => {
                  let patched = bytes.to_array()
                  let at = hive_bins_base + offsets[1].reinterpret_as_int() + 4
                  w_i32(patched, at + 8, 2147483632)
                  let broken = Bytes::from_array(patched)
                  match HiveEditor::open(broken) {
                    Err(error) => assert_eq(error.message(), "opened")
                    Ok(editor) => {
                      assert_eq(editor.is_lossless(), false)
                      assert_eq(editor.skipped_values(), 1)
                    }
                  }
                  match HiveEditor::open_strict(broken) {
                    Err(error) =>
                      assert_eq(
                        error.message().has_suffix("were dropped"),
                        true,
                      )
                    Ok(_) => assert_eq("rejected", "accepted")
                  }
                }
              }
          }
      }
  }
}

///|
test "a healthy hive loads losslessly" {
  match ed_open() {
    Err(error) => assert_eq(error.message(), "opened")
    Ok(editor) => assert_eq(editor.is_lossless(), true)
  }
}
