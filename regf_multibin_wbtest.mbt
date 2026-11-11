///|
/// Declared size of every bin, in file order.
fn mb_bin_sizes(bytes : Bytes) -> Array[Int32] {
  let out : Array[Int32] = []
  let mut start = base_block_size
  while start + 32 <= bytes.length() {
    let declared = read_u32_le(bytes, start + 8).reinterpret_as_int()
    if declared < 4096 || start + declared > bytes.length() {
      break
    }
    out.push(declared)
    start = start + declared
  }
  out
}

///|
test "keeps a small hive in one 4096 byte bin" {
  let builder = HiveBuilder::new()
  builder.set_dword(0, "Count", 1)
  match builder.build() {
    Err(error) => assert_eq(error.message(), "built")
    Ok(bytes) => {
      let sizes = mb_bin_sizes(bytes)
      assert_eq(sizes.length(), 1)
      assert_eq(sizes[0], 4096)
      assert_eq(bytes.length(), base_block_size + 4096)
    }
  }
}

///|
test "splits a large tree across several bins" {
  let builder = HiveBuilder::new()
  let mut index = 0
  while index < 400 {
    let child = builder.add_key(0, "k" + index.to_string())
    builder.set_string(child, "Name", "value-" + index.to_string())
    index = index + 1
  }
  match builder.build() {
    Err(error) => assert_eq(error.message(), "built")
    Ok(bytes) => {
      let sizes = mb_bin_sizes(bytes)
      assert_eq(sizes.length() > 1, true)
      let mut total = 0
      let mut bin = 0
      while bin < sizes.length() {
        total = total + sizes[bin]
        bin = bin + 1
      }
      assert_eq(base_block_size + total, bytes.length())
      match parse_header(bytes) {
        Err(error) => assert_eq(error.message(), "header")
        Ok(header) => {
          assert_eq(header.hive_bins_data_size.reinterpret_as_int(), total)
          match parse_key_node(bytes, header.root_cell_offset) {
            Err(error) => assert_eq(error.message(), "key")
            Ok(root) =>
              match list_subkeys(bytes, root) {
                Err(error) => assert_eq(error.message(), "children")
                Ok(children) => assert_eq(children.length(), 400)
              }
          }
        }
      }
    }
  }
}

///|
test "keeps each big data segment inside one bin" {
  let builder = HiveBuilder::new()
  let blob = bw_blob(40000)
  builder.set_value(0, "Big", Binary, blob)
  match builder.build() {
    Err(error) => assert_eq(error.message(), "built")
    Ok(bytes) => {
      let sizes = mb_bin_sizes(bytes)
      let mut largest = 0
      let mut bin = 0
      while bin < sizes.length() {
        if sizes[bin] > largest {
          largest = sizes[bin]
        }
        bin = bin + 1
      }
      assert_eq(largest >= 16384, true)
      match parse_header(bytes) {
        Err(error) => assert_eq(error.message(), "header")
        Ok(header) =>
          match parse_key_node(bytes, header.root_cell_offset) {
            Err(error) => assert_eq(error.message(), "key")
            Ok(key) =>
              match list_values(bytes, key) {
                Err(error) => assert_eq(error.message(), "values")
                Ok(values) => {
                  assert_eq(values.length(), 1)
                  assert_eq(values[0].data.length(), 40000)
                  assert_eq(Bytes::equal(values[0].data, blob), true)
                }
              }
          }
      }
    }
  }
}
