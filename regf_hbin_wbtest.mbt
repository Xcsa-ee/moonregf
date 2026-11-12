///|
test "reads the root cell of a built hive" {
  let builder = HiveBuilder::new()
  builder.set_dword(0, "Count", 1)
  match builder.build() {
    Err(error) => assert_eq(error.message(), "built")
    Ok(bytes) =>
      match parse_header(bytes) {
        Err(error) => assert_eq(error.message(), "header")
        Ok(header) =>
          match read_cell(bytes, header.root_cell_offset) {
            Err(error) => assert_eq(error.message(), "cell")
            Ok(cell) => {
              assert_eq(cell.allocated, true)
              assert_eq(cell.payload_size > 0, true)
            }
          }
      }
  }
}

///|
test "rejects an offset that would overflow the bins region" {
  let bytes = Bytes::new(8192)
  match read_cell(bytes, (2147483632 : UInt32)) {
    Err(_) => assert_eq("rejected", "rejected")
    Ok(_) => assert_eq("rejected", "accepted")
  }
}

///|
test "rejects a cell whose size runs past the file" {
  let raw = Bytes::new(8192).to_array()
  w_i32(raw, 0, 2147483647)
  match read_cell(Bytes::from_array(raw), (0 : UInt32)) {
    Err(_) => assert_eq("rejected", "rejected")
    Ok(_) => assert_eq("rejected", "accepted")
  }
}

///|
test "rejects a zero sized cell" {
  let bytes = Bytes::new(8192)
  match read_cell(bytes, (0 : UInt32)) {
    Err(_) => assert_eq("rejected", "rejected")
    Ok(_) => assert_eq("rejected", "accepted")
  }
}

///|
test "rejects an offset with the sign bit set" {
  let bytes = Bytes::new(8192)
  match read_cell(bytes, (4294967295 : UInt32)) {
    Err(_) => assert_eq("rejected", "rejected")
    Ok(_) => assert_eq("rejected", "accepted")
  }
}
