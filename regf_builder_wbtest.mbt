///|
/// Encodes a string as UTF-8 bytes.
fn bw_text(text : String) -> Bytes {
  @utf8.encode(text)
}

///|
/// Builds the bytes of a little-endian 32-bit integer.
fn bw_dword(value : Int32) -> Bytes {
  let out : Array[Byte] = []
  out.push((value & 0xFF).to_byte())
  out.push(((value >> 8) & 0xFF).to_byte())
  out.push(((value >> 16) & 0xFF).to_byte())
  out.push(((value >> 24) & 0xFF).to_byte())
  Bytes::from_array(out)
}

///|
/// Builds count bytes with a repeating pattern.
fn bw_blob(count : Int32) -> Bytes {
  let out : Array[Byte] = []
  let mut index = 0
  while index < count {
    out.push(((index * 7) & 0xFF).to_byte())
    index = index + 1
  }
  Bytes::from_array(out)
}

///|
/// Builds the ten bytes of the REG_MULTI_SZ value A, B.
fn bw_multi() -> Bytes {
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
/// Renders base block fields and every key path of a built hive.
fn bw_describe_tree(builder : HiveBuilder) -> String {
  match builder.build() {
    Err(error) => "err " + error.message()
    Ok(bytes) =>
      match parse_header(bytes) {
        Err(error) => "err " + error.message()
        Ok(header) => {
          let entries = walk_key_tree(bytes, header.root_cell_offset, 8)
          let mut text = "v=" +
            header.major_version.to_string() +
            "." +
            header.minor_version.to_string() +
            " root=" +
            header.root_cell_offset.to_string() +
            " name=" +
            header.file_name +
            " keys=" +
            entries.length().to_string()
          let mut index = 0
          while index < entries.length() {
            text = text + " | " + entries[index].path
            index = index + 1
          }
          text
        }
      }
  }
}

///|
/// Renders every value of a built hive as path|name|type|size records.
fn bw_describe_values(builder : HiveBuilder) -> String {
  match builder.build() {
    Err(error) => "err " + error.message()
    Ok(bytes) =>
      match parse_header(bytes) {
        Err(error) => "err " + error.message()
        Ok(header) => {
          let entries = walk_key_tree(bytes, header.root_cell_offset, 8)
          let mut text = ""
          let mut index = 0
          while index < entries.length() {
            match parse_key_node(bytes, entries[index].offset) {
              Err(_) => text = text + "ERR;"
              Ok(key) =>
                match list_values(bytes, key) {
                  Err(_) => text = text + "ERR;"
                  Ok(values) => {
                    let mut inner = 0
                    while inner < values.length() {
                      text = text +
                        entries[index].path +
                        "|" +
                        values[inner].name +
                        "|" +
                        values[inner].data_type.label() +
                        "|" +
                        values[inner].data.length().to_string() +
                        ";"
                      inner = inner + 1
                    }
                  }
                }
            }
            index = index + 1
          }
          text
        }
      }
  }
}

///|
/// Renders the first error of a build, or ok when it succeeds.
fn bw_build_error(builder : HiveBuilder) -> String {
  match builder.build() {
    Ok(_) => "ok"
    Err(error) => error.message()
  }
}

///|
/// A builder holding two keys and five values of every common type.
fn bw_sample() -> HiveBuilder {
  let builder = HiveBuilder::new()
  let software = builder.add_key(0, "Software")
  let vendor = builder.add_key(software, "Vendor")
  builder.set_value(software, "Install", Sz, bw_text("Hello"))
  builder.set_value(software, "Count", Dword, bw_dword(42))
  builder.set_value(software, "Blob", Binary, bw_blob(8))
  builder.set_value(software, "List", MultiSz, bw_multi())
  builder.set_value(vendor, "Name", Sz, bw_text("x"))
  builder
}

///|
test "builds a hive that reads back" {
  let described = bw_describe_tree(bw_sample())
  assert_eq(
    described, "v=1.5 root=32 name=ROOT keys=3 | ROOT | ROOT/Software | ROOT/Software/Vendor",
  )
}

///|
test "reads back every value of a built hive" {
  let described = bw_describe_values(bw_sample())
  assert_eq(
    described, "ROOT/Software|Install|REG_SZ|5;ROOT/Software|Count|REG_DWORD|4;ROOT/Software|Blob|REG_BINARY|8;ROOT/Software|List|REG_MULTI_SZ|10;ROOT/Software/Vendor|Name|REG_SZ|4;",
  )
}

///|
test "builds a hive with a single root key" {
  assert_eq(
    bw_describe_tree(HiveBuilder::new()),
    "v=1.5 root=32 name=ROOT keys=1 | ROOT",
  )
}

///|
test "keeps inline values inline" {
  let builder = HiveBuilder::new()
  builder.set_dword(0, "Flag", 7)
  match builder.build() {
    Err(error) => assert_eq(error.message(), "ok")
    Ok(bytes) =>
      match parse_header(bytes) {
        Err(error) => assert_eq(error.message(), "ok")
        Ok(header) =>
          match parse_key_node(bytes, header.root_cell_offset) {
            Err(error) => assert_eq(error.message(), "ok")
            Ok(key) =>
              match list_values(bytes, key) {
                Err(error) => assert_eq(error.message(), "ok")
                Ok(values) => {
                  assert_eq(values.length(), 1)
                  assert_eq(values[0].inline_data, true)
                  assert_eq(
                    match values[0].as_u32() {
                      Some(number) => number.to_string()
                      None => "none"
                    },
                    "7",
                  )
                }
              }
          }
      }
  }
}

///|
test "stores a value up to a whole data cell" {
  let builder = HiveBuilder::new()
  builder.set_value(0, "Big", Binary, bw_blob(16344))
  match builder.build() {
    Err(error) => assert_eq(error.message(), "ok")
    Ok(bytes) =>
      match parse_header(bytes) {
        Err(error) => assert_eq(error.message(), "ok")
        Ok(header) =>
          match parse_key_node(bytes, header.root_cell_offset) {
            Err(error) => assert_eq(error.message(), "ok")
            Ok(key) =>
              match list_values(bytes, key) {
                Err(error) => assert_eq(error.message(), "ok")
                Ok(values) => assert_eq(values[0].data.length(), 16344)
              }
          }
      }
  }
}

///|
/// True when some tree path ends with suffix.
fn bw_has_path(entries : Array[HiveKeyEntry], suffix : String) -> Bool {
  let mut index = 0
  while index < entries.length() {
    if entries[index].path.has_suffix(suffix) {
      return true
    }
    index = index + 1
  }
  false
}

///|
/// Values of the root key as the reader sees them.
fn bw_root_values(bytes : Bytes) -> Array[HiveValue] {
  match parse_header(bytes) {
    Err(_) => []
    Ok(header) =>
      match parse_key_node(bytes, header.root_cell_offset) {
        Err(_) => []
        Ok(key) =>
          match list_values(bytes, key) {
            Err(_) => []
            Ok(values) => values
          }
      }
  }
}

///|
/// Number of children of the root key as the reader sees them, -1 on failure.
fn bw_root_children(bytes : Bytes) -> Int32 {
  match parse_header(bytes) {
    Err(_) => -1
    Ok(header) =>
      match parse_key_node(bytes, header.root_cell_offset) {
        Err(_) => -1
        Ok(key) =>
          match list_subkeys(bytes, key) {
            Err(_) => -1
            Ok(children) => children.length()
          }
      }
  }
}

///|
test "writes and reads a non-ASCII key name" {
  let builder = HiveBuilder::new()
  let _ = builder.add_key(0, "key-one")
  let _ = builder.add_key(1, "中文")
  match builder.build() {
    Err(error) => assert_eq(error.message(), "built")
    Ok(bytes) =>
      match parse_header(bytes) {
        Err(error) => assert_eq(error.message(), "header")
        Ok(header) => {
          let entries = walk_key_tree(bytes, header.root_cell_offset, 4)
          assert_eq(bw_has_path(entries, "/中文"), true)
          assert_eq(bw_has_path(entries, "/key-one"), true)
        }
      }
  }
}

///|
test "writes and reads a non-ASCII value name and text" {
  let builder = HiveBuilder::new()
  builder.set_string(0, "说明", "你好")
  match builder.build() {
    Err(error) => assert_eq(error.message(), "built")
    Ok(bytes) => {
      let values = bw_root_values(bytes)
      assert_eq(values.length(), 1)
      assert_eq(values[0].name, "说明")
      match values[0].as_string() {
        Some(text) => assert_eq(text, "你好")
        None => assert_eq("decoded", "你好")
      }
    }
  }
}

///|
test "writes a value larger than one cell through a db record" {
  let blob = bw_blob(40000)
  let builder = HiveBuilder::new()
  builder.set_value(0, "Big", Binary, blob)
  match builder.build() {
    Err(error) => assert_eq(error.message(), "built")
    Ok(bytes) => {
      let values = bw_root_values(bytes)
      assert_eq(values.length(), 1)
      assert_eq(values[0].data.length(), 40000)
      assert_eq(Bytes::equal(values[0].data, blob), true)
    }
  }
}

///|
test "writes a root index when a key has many children" {
  let builder = HiveBuilder::new()
  let mut index = 0
  while index < 600 {
    let _ = builder.add_key(0, "k" + index.to_string())
    index = index + 1
  }
  assert_eq(bw_build_error(builder), "ok")
  match builder.build() {
    Err(error) => assert_eq(error.message(), "built")
    Ok(bytes) => assert_eq(bw_root_children(bytes), 600)
  }
}

///|
test "honours a forced index leaf" {
  let builder = HiveBuilder::new()
  let _ = builder.add_key(0, "a")
  let _ = builder.add_key(0, "b")
  let _ = builder.add_key(0, "c")
  builder.set_index_kind(0, IndexLeaf)
  match builder.build() {
    Err(error) => assert_eq(error.message(), "built")
    Ok(bytes) => assert_eq(bw_root_children(bytes), 3)
  }
}

///|
test "honours a forced hash leaf" {
  let builder = HiveBuilder::new()
  let _ = builder.add_key(0, "alpha")
  let _ = builder.add_key(0, "beta")
  builder.set_index_kind(0, HashLeaf)
  match builder.build() {
    Err(error) => assert_eq(error.message(), "built")
    Ok(bytes) => assert_eq(bw_root_children(bytes), 2)
  }
}

///|
test "honours a forced root index" {
  let builder = HiveBuilder::new()
  let _ = builder.add_key(0, "one")
  let _ = builder.add_key(0, "two")
  builder.set_index_kind(0, RootIndex)
  match builder.build() {
    Err(error) => assert_eq(error.message(), "built")
    Ok(bytes) => assert_eq(bw_root_children(bytes), 2)
  }
}
