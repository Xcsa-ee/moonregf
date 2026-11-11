///|
test "finds no orphan record in a healthy hive" {
  let builder = HiveBuilder::new()
  let _ = builder.add_key(0, "Software")
  builder.set_dword(0, "Count", 1)
  match builder.build() {
    Err(error) => assert_eq(error.message(), "built")
    Ok(bytes) =>
      match scan_orphan_records(bytes) {
        Err(error) => assert_eq(error.message(), "scanned")
        Ok(records) => assert_eq(records.length(), 0)
      }
  }
}

///|
test "reports an nk cell that the parent list no longer points at" {
  let builder = HiveBuilder::new()
  let child = builder.add_key(0, "Ghost")
  builder.set_dword(child, "Count", 3)
  match builder.build() {
    Err(error) => assert_eq(error.message(), "built")
    Ok(bytes) =>
      match parse_header(bytes) {
        Err(error) => assert_eq(error.message(), "header")
        Ok(header) =>
          match parse_key_node(bytes, header.root_cell_offset) {
            Err(error) => assert_eq(error.message(), "key")
            Ok(root) => {
              let patched = bytes.to_array()
              let list = hive_bins_base +
                root.subkey_list_offset.reinterpret_as_int() +
                4
              w_i32(patched, list + 4, 0)
              match scan_orphan_records(Bytes::from_array(patched)) {
                Err(error) => assert_eq(error.message(), "scanned")
                Ok(records) => {
                  assert_eq(records.length(), 1)
                  assert_eq(records[0].name, "Ghost")
                  assert_eq(records[0].deleted, false)
                }
              }
            }
          }
      }
  }
}
