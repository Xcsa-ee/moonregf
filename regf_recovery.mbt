///|
/// One record found inside the bins that the live key tree cannot reach.
pub(all) struct OrphanRecord {
  offset : Int32
  signature : String
  name : String
  deleted : Bool
}

///|
/// Reads the key name out of an nk or del payload.
fn orphan_name(bytes : Bytes, payload : Int32) -> String {
  let flags = read_u16_le(bytes, payload + 2).reinterpret_as_int()
  let length = read_u16_le(bytes, payload + 72).reinterpret_as_int()
  if length <= 0 || payload + 76 + length > bytes.length() {
    return ""
  }
  if (flags & 0x20) != 0 {
    decode_single_byte(bytes, payload + 76, length)
  } else {
    decode_utf16le(bytes, payload + 76, length / 2)
  }
}

///|
/// True when offset appears in the reachable set.
fn is_reachable(reachable : Array[Int32], offset : Int32) -> Bool {
  let mut index = 0
  while index < reachable.length() {
    if reachable[index] == offset {
      return true
    }
    index = index + 1
  }
  false
}

///|
/// Walks every allocated cell and reports the nk and del records that the
/// live tree does not reach.
///
/// Cells are walked from the first cell after each bin header: a bin starts
/// with a 32 byte hbin header, so the very first 32 bytes of every 4096 byte
/// bin are skipped instead of being read as a cell size.
pub fn scan_orphan_records(
  bytes : Bytes,
) -> Result[Array[OrphanRecord], RegfError] {
  let header = match parse_header(bytes) {
    Err(error) => return Err(error)
    Ok(parsed) => parsed
  }
  let reachable : Array[Int32] = []
  let entries = walk_key_tree(bytes, header.root_cell_offset, 64)
  let mut index = 0
  while index < entries.length() {
    reachable.push(entries[index].offset.reinterpret_as_int())
    index = index + 1
  }
  let out : Array[OrphanRecord] = []
  let limit = hive_bins_base + header.hive_bins_data_size.reinterpret_as_int()
  let stop = if limit > bytes.length() { bytes.length() } else { limit }
  let mut cursor = hive_bins_base
  while cursor + 8 <= stop {
    if (cursor - hive_bins_base) % 4096 == 0 {
      cursor = cursor + 32
    } else {
      let raw = read_u32_le(bytes, cursor).reinterpret_as_int()
      let total = if raw < 0 { -raw } else { raw }
      if raw == 0 || total < 8 || cursor + total > stop {
        cursor = stop
      } else {
        let payload = cursor + 4
        let relative = cursor - hive_bins_base
        if raw < 0 && payload + 76 <= cursor + total {
          let first = bytes[payload].to_int()
          let second = bytes[payload + 1].to_int()
          let live = first == 0x6E && second == 0x6B
          let deleted = first == 0x64 &&
            second == 0x65 &&
            bytes[payload + 2].to_int() == 0x6C
          if (live || deleted) && !is_reachable(reachable, relative) {
            let record : OrphanRecord = {
              offset: relative,
              signature: if live {
                "nk"
              } else {
                "del"
              },
              name: orphan_name(bytes, payload),
              deleted,
            }
            out.push(record)
          }
        }
        cursor = cursor + total
      }
    }
  }
  Ok(out)
}
