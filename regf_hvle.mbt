///|
/// Offset of the entry size field inside an HvLE entry header.
let log_entry_size_offset : Int32 = 0x04

///|
/// Offset of the sequence number inside an HvLE entry header.
let log_entry_sequence_offset : Int32 = 0x0C

///|
/// Offset of the hive bins data size inside an HvLE entry header.
let log_entry_bins_offset : Int32 = 0x10

///|
/// Offset of the dirty page count inside an HvLE entry header.
let log_entry_page_count_offset : Int32 = 0x14

///|
/// Size of an HvLE entry header, up to its page reference array.
let log_entry_header_size : Int32 = 0x28

///|
/// Alignment of every transaction log entry.
let log_entry_alignment : Int32 = 512

///|
/// Offset of the first entry, past the 512-byte compatibility header.
let log_first_entry_offset : Int32 = 512

///|
/// Largest number of dirty pages a single entry may describe.
let log_max_pages : Int32 = 65536

///|
/// Largest dirty page a single entry may describe.
let log_max_page_size : Int32 = 0x100000

///|
/// One dirty page reference inside a log entry.
pub(all) struct LogPageRef {
  offset : UInt32
  size : Int32
}

///|
/// One transaction log entry: dirty page references plus their bytes.
pub(all) struct LogEntry {
  sequence : UInt32
  bins_data_size : UInt32
  size : Int32
  pages : Array[LogPageRef]
  data : Bytes
}

///|
/// A parsed transaction log file.
pub(all) struct LogFile {
  primary_sequence : UInt32
  secondary_sequence : UInt32
  entries : Array[LogEntry]
}

///|
/// Outcome of replaying a log onto a hive.
pub(all) struct LogReplay {
  bytes : Bytes
  applied : Int32
  final_sequence : UInt32
}

///|
/// Number of entries in the log.
pub fn LogFile::entry_count(self : LogFile) -> Int32 {
  self.entries.length()
}

///|
/// Total number of dirty pages across every entry.
pub fn LogFile::page_count(self : LogFile) -> Int32 {
  let mut total = 0
  let mut index = 0
  while index < self.entries.length() {
    total = total + self.entries[index].pages.length()
    index = index + 1
  }
  total
}

///|
/// True when the four bytes at start are the HvLE entry signature.
fn log_signature_matches(bytes : Bytes, start : Int32) -> Bool {
  bytes[start].to_int() == 0x48 &&
  bytes[start + 1].to_int() == 0x76 &&
  bytes[start + 2].to_int() == 0x4C &&
  bytes[start + 3].to_int() == 0x45
}

///|
/// Parses the log entry whose header starts at position.
fn parse_log_entry(
  bytes : Bytes,
  position : Int32,
) -> Result[LogEntry, RegfError] {
  let size = bytes.length()
  if position + log_entry_header_size > size {
    return Err(BadLogEntry(position))
  }
  let entry_size = read_u32_le(bytes, position + log_entry_size_offset).reinterpret_as_int()
  if entry_size < log_entry_header_size || entry_size % log_entry_alignment != 0 {
    return Err(BadLogEntry(position))
  }
  if position + entry_size > size {
    return Err(BadLogEntry(position))
  }
  let count = read_u32_le(bytes, position + log_entry_page_count_offset).reinterpret_as_int()
  if count <= 0 || count > log_max_pages {
    return Err(BadLogEntry(position))
  }
  let refs_end = position + log_entry_header_size + count * 8
  if refs_end > position + entry_size {
    return Err(BadLogEntry(position))
  }
  let pages : Array[LogPageRef] = []
  let mut total = 0
  let mut index = 0
  while index < count {
    let ref_at = position + log_entry_header_size + index * 8
    let page_offset = read_u32_le(bytes, ref_at)
    let page_size = read_u32_le(bytes, ref_at + 4).reinterpret_as_int()
    if page_size <= 0 || page_size > log_max_page_size {
      return Err(BadLogEntry(position))
    }
    let reference : LogPageRef = { offset: page_offset, size: page_size, }
    pages.push(reference)
    total = total + page_size
    index = index + 1
  }
  if refs_end + total > position + entry_size {
    return Err(BadLogEntry(position))
  }
  let entry : LogEntry = {
    sequence: read_u32_le(bytes, position + log_entry_sequence_offset),
    bins_data_size: read_u32_le(bytes, position + log_entry_bins_offset),
    size: entry_size,
    pages,
    data: copy_range(bytes, refs_end, total),
  }
  Ok(entry)
}

///|
/// Parses a transaction log file.
///
/// Windows 8.1 and newer write a REGF base block with file type 6 followed by
/// HvLE entries on 512-byte boundaries; the parser only accepts that layout and
/// reports older formats as UnsupportedLogVersion instead of guessing.
pub fn parse_log(bytes : Bytes) -> Result[LogFile, RegfError] {
  let size = bytes.length()
  if size < base_block_size {
    return Err(TooShort(size))
  }
  if !signature_matches(bytes) {
    return Err(BadSignature(signature_hex(bytes)))
  }
  let raw_type = read_u32_le(bytes, 0x1C)
  if raw_type == 1 {
    return Err(UnsupportedLogVersion(raw_type))
  }
  if raw_type != 6 {
    return Err(NotALogFile(raw_type))
  }
  if size < log_first_entry_offset + log_entry_header_size {
    return Err(BadLogEntry(log_first_entry_offset))
  }
  let mut position = log_first_entry_offset
  let mut first = -1
  while first < 0 && position + log_entry_header_size <= size {
    if log_signature_matches(bytes, position) {
      first = position
    } else {
      position = position + log_entry_alignment
    }
  }
  let entries : Array[LogEntry] = []
  let mut cursor = first
  let mut running = true
  while running {
    if cursor < 0 || cursor + log_entry_header_size > size {
      running = false
    } else if !log_signature_matches(bytes, cursor) {
      running = false
    } else {
      let entry = match parse_log_entry(bytes, cursor) {
        Err(error) => return Err(error)
        Ok(parsed) => parsed
      }
      entries.push(entry)
      cursor = cursor + entry.size
    }
  }
  let log : LogFile = {
    primary_sequence: read_u32_le(bytes, 0x04),
    secondary_sequence: read_u32_le(bytes, 0x08),
    entries,
  }
  Ok(log)
}

///|
/// Replays a transaction log onto a copy of a hive.
///
/// Entries are applied in stored order and only when their sequence is newer
/// than the secondary sequence of the hive, so replaying a stale log leaves the
/// hive untouched. Dirty page offsets are relative to the hive bins data, and
/// the base block sequence numbers plus checksum are rewritten after the last
/// applied entry.
pub fn replay_log(hive : Bytes, log : Bytes) -> Result[LogReplay, RegfError] {
  let header = match parse_header(hive) {
    Err(error) => return Err(error)
    Ok(parsed) => parsed
  }
  let parsed_log = match parse_log(log) {
    Err(error) => return Err(error)
    Ok(parsed) => parsed
  }
  let out = copy_range(hive, 0, hive.length()).to_array()
  let size = out.length()
  let mut applied = 0
  let mut final_sequence = header.secondary_sequence
  let mut index = 0
  while index < parsed_log.entries.length() {
    let entry = parsed_log.entries[index]
    if entry.sequence > header.secondary_sequence {
      let mut source = 0
      let mut page_index = 0
      while page_index < entry.pages.length() {
        let page = entry.pages[page_index]
        let target = hive_bins_base + page.offset.reinterpret_as_int()
        if target < 0 || target + page.size > size {
          return Err(BadLogPage(page.offset.reinterpret_as_int()))
        }
        let mut copied = 0
        while copied < page.size {
          out[target + copied] = entry.data[source + copied]
          copied = copied + 1
        }
        source = source + page.size
        page_index = page_index + 1
      }
      applied = applied + 1
      final_sequence = entry.sequence
    }
    index = index + 1
  }
  if applied > 0 {
    w_i32(out, 0x04, final_sequence.reinterpret_as_int())
    w_i32(out, 0x08, final_sequence.reinterpret_as_int())
    let checksum = array_checksum(out)
    w_i32(out, 0x1FC, checksum.reinterpret_as_int())
  }
  let replay : LogReplay = {
    bytes: Bytes::from_array(out),
    applied,
    final_sequence,
  }
  Ok(replay)
}

///|
/// Replays a log and returns only the patched hive bytes.
pub fn apply_log(hive : Bytes, log : Bytes) -> Result[Bytes, RegfError] {
  match replay_log(hive, log) {
    Err(error) => Err(error)
    Ok(replay) => Ok(replay.bytes)
  }
}
