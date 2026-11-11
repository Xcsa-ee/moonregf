///|
/// True when haystack contains needle.
fn lg_contains(haystack : String, needle : String) -> Bool {
  let hay = @utf8.encode(haystack)
  let key = @utf8.encode(needle)
  hay.find(key.clamped_view(start=0, end=key.length())) != None
}

///|
/// Builds a log with one entry that carries a single dirty page.
fn lg_make_log(
  sequence : Int32,
  page_offset : Int32,
  page_data : Array[Byte],
) -> Bytes {
  let raw_size = log_entry_header_size + 8 + page_data.length()
  let entry_size = (raw_size + log_entry_alignment - 1) /
    log_entry_alignment *
    log_entry_alignment
  let bytes : Array[Byte] = Bytes::new(base_block_size + entry_size).to_array()
  w_i32(bytes, 0, 0x66676572)
  w_i32(bytes, 0x04, 1)
  w_i32(bytes, 0x08, 1)
  w_i32(bytes, 0x14, 1)
  w_i32(bytes, 0x18, 5)
  w_i32(bytes, 0x1C, 6)
  w_i32(bytes, 0x20, 1)
  w_i32(bytes, 0x28, 4096)
  w_i32(bytes, 0x2C, 1)
  let checksum = array_checksum(bytes)
  w_i32(bytes, 0x1FC, checksum.reinterpret_as_int())
  let at = base_block_size
  w_i32(bytes, at, 0x454C7648)
  w_i32(bytes, at + log_entry_size_offset, entry_size)
  w_i32(bytes, at + log_entry_sequence_offset, sequence)
  w_i32(bytes, at + log_entry_bins_offset, 4096)
  w_i32(bytes, at + log_entry_page_count_offset, 1)
  w_i32(bytes, at + log_entry_header_size, page_offset)
  w_i32(bytes, at + log_entry_header_size + 4, page_data.length())
  let mut index = 0
  while index < page_data.length() {
    bytes[at + log_entry_header_size + 8 + index] = page_data[index]
    index = index + 1
  }
  Bytes::from_array(bytes)
}

///|
/// Builds the first hive bin page of a hive with one byte replaced.
fn lg_page_with_byte(hive : Bytes, index : Int32, value : Int32) -> Array[Byte] {
  let page = copy_range(hive, base_block_size, base_block_size).to_array()
  page[index] = value.to_byte()
  page
}

///|
/// Renders the parsed structure of a log.
fn lg_describe(log : Bytes) -> String {
  match parse_log(log) {
    Err(error) => "err " + error.message()
    Ok(parsed) =>
      match parsed.entry_count() {
        0 => "ok entries=0 pages=0"
        _ =>
          "ok entries=" +
          parsed.entry_count().to_string() +
          " pages=" +
          parsed.page_count().to_string() +
          " logseq=" +
          parsed.secondary_sequence.to_string() +
          " seq=" +
          parsed.entries[0].sequence.to_string() +
          " bins=" +
          parsed.entries[0].bins_data_size.to_string() +
          " data=" +
          parsed.entries[0].data.length().to_string()
      }
  }
}

///|
/// Renders the outcome of a replay.
fn lg_describe_replay(hive : Bytes, log : Bytes) -> String {
  match replay_log(hive, log) {
    Err(error) => "err " + error.message()
    Ok(replay) =>
      match parse_header(replay.bytes) {
        Err(error) => "err " + error.message()
        Ok(header) =>
          match parse_key_node(replay.bytes, header.root_cell_offset) {
            Err(error) => "err " + error.message()
            Ok(key) =>
              "ok applied=" +
              replay.applied.to_string() +
              " final=" +
              replay.final_sequence.to_string() +
              " hive_seq=" +
              header.secondary_sequence.to_string() +
              " name=" +
              key.name
          }
      }
  }
}

///|
/// Builds a one key hive and returns its bytes.
fn lg_hive() -> Bytes {
  let builder = HiveBuilder::new()
  builder.set_dword(0, "Count", 1)
  match builder.build() {
    Ok(bytes) => bytes
    Err(_) => Bytes::new(0)
  }
}

///|
test "parses a log entry" {
  let hive = lg_hive()
  let page = lg_page_with_byte(hive, 112, 0x58)
  assert_eq(
    lg_describe(lg_make_log(2, 0, page)),
    "ok entries=1 pages=1 logseq=1 seq=2 bins=4096 data=4096",
  )
}

///|
test "replays a page over the hive bins" {
  let hive = lg_hive()
  let page = lg_page_with_byte(hive, 112, 0x58)
  assert_eq(
    lg_describe_replay(hive, lg_make_log(2, 0, page)),
    "ok applied=1 final=2 hive_seq=2 name=XOOT",
  )
}

///|
test "leaves a stale log unapplied" {
  let hive = lg_hive()
  let page = lg_page_with_byte(hive, 112, 0x58)
  let replayed = match replay_log(hive, lg_make_log(1, 0, page)) {
    Err(_) => Bytes::new(0)
    Ok(replay) => replay.bytes
  }
  assert_eq(Bytes::equal(replayed, hive), true)
}

///|
test "rejects a file that is not a log" {
  match parse_log(lg_hive()) {
    Err(error) =>
      assert_eq(lg_contains(error.message(), "is not a transaction log"), true)
    Ok(_) => assert_eq("parsed", "rejected")
  }
}

///|
test "reports an unsupported log format" {
  let hive = lg_hive()
  let page = lg_page_with_byte(hive, 112, 0x58)
  let bytes = lg_make_log(2, 0, page).to_array()
  w_i32(bytes, 0x1C, 1)
  match parse_log(Bytes::from_array(bytes)) {
    Err(error) => assert_eq(error.message(), "log format 1 is not supported")
    Ok(_) => assert_eq("parsed", "rejected")
  }
}

///|
test "rejects a malformed entry" {
  let hive = lg_hive()
  let page = lg_page_with_byte(hive, 112, 0x58)
  let bytes = lg_make_log(2, 0, page).to_array()
  w_i32(bytes, base_block_size + log_entry_page_count_offset, 0xFFFF)
  match parse_log(Bytes::from_array(bytes)) {
    Err(error) => assert_eq(error.message(), "log entry at 4096 is malformed")
    Ok(_) => assert_eq("parsed", "rejected")
  }
}

///|
test "rejects a dirty page outside the bins" {
  let hive = lg_hive()
  let page = lg_page_with_byte(hive, 112, 0x58)
  match replay_log(hive, lg_make_log(2, 0x100000, page)) {
    Err(error) =>
      assert_eq(
        error.message(),
        "dirty page at 1048576 is outside the hive bins data",
      )
    Ok(_) => assert_eq("applied", "rejected")
  }
}

///|
test "applies an older log and then a newer one" {
  let hive = lg_hive()
  let first = match
    replay_log(hive, lg_make_log(2, 0, lg_page_with_byte(hive, 112, 0x41))) {
    Err(_) => Bytes::new(0)
    Ok(replay) => replay.bytes
  }
  let second = match
    replay_log(first, lg_make_log(3, 0, lg_page_with_byte(hive, 112, 0x42))) {
    Err(_) => Bytes::new(0)
    Ok(replay) => replay.bytes
  }
  assert_eq(
    lg_describe_replay(
      first,
      lg_make_log(3, 0, lg_page_with_byte(hive, 112, 0x42)),
    ),
    "ok applied=1 final=3 hive_seq=3 name=BOOT",
  )
  match parse_header(second) {
    Err(error) => assert_eq(error.message(), "header")
    Ok(header) =>
      match parse_key_node(second, header.root_cell_offset) {
        Err(error) => assert_eq(error.message(), "key")
        Ok(key) => assert_eq(key.name, "BOOT")
      }
  }
}

///|
test "does not go backwards when an older log arrives last" {
  let hive = lg_hive()
  let newer = match
    replay_log(hive, lg_make_log(5, 0, lg_page_with_byte(hive, 112, 0x42))) {
    Err(_) => Bytes::new(0)
    Ok(replay) => replay.bytes
  }
  let after = match
    replay_log(newer, lg_make_log(2, 0, lg_page_with_byte(hive, 112, 0x41))) {
    Err(_) => Bytes::new(0)
    Ok(replay) => replay.bytes
  }
  assert_eq(Bytes::equal(after, newer), true)
}
