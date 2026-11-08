///|
/// Kind of subkey list record stored in a hive.
pub(all) enum SubkeyListKind {
  // lf: leaf list, 8-byte entries of key offset plus a name hint
  FastLeaf
  // lh: hash leaf list, same layout as lf but the hint is a real hash
  HashLeaf
  // li: index list, 4-byte key offsets
  IndexLeaf
  // ri: root index, 4-byte offsets of nested lf/lh/li lists
  RootIndex
  // Anything else, keeping the raw signature for diagnostics
  Unknown(String)
}

///|
/// Short label for a subkey list kind.
pub fn SubkeyListKind::label(self : SubkeyListKind) -> String {
  match self {
    FastLeaf => "lf"
    HashLeaf => "lh"
    IndexLeaf => "li"
    RootIndex => "ri"
    Unknown(name) => name
  }
}

///|
/// A subkey list record: the direct children of one key.
///
/// For root index (ri) records the child offsets of the nested lists are
/// flattened, so key_offsets always holds key node offsets in stored order.
pub(all) struct HiveSubkeyList {
  offset : UInt32
  kind : SubkeyListKind
  count : Int32
  key_offsets : Array[UInt32]
}

///|
/// One entry of a flattened key tree.
pub(all) struct HiveKeyEntry {
  path : String
  offset : UInt32
  subkey_count : Int32
  value_count : Int32
}

///|
/// Renders the two bytes at start as lowercase hex, for diagnostics.
fn signature_hex_at(bytes : Bytes, start : Int32) -> String {
  "0x" +
  bytes[start].to_uint().to_string(radix=16) +
  bytes[start + 1].to_uint().to_string(radix=16)
}

///|
/// Reads the subkey list stored at offset, expanding nested ri records.
pub fn read_subkey_list(
  bytes : Bytes,
  offset : UInt32,
) -> Result[HiveSubkeyList, RegfError] {
  read_subkey_list_at(bytes, offset, 0)
}

///|
/// Recursive worker for read_subkey_list; depth guards nested ri records.
fn read_subkey_list_at(
  bytes : Bytes,
  offset : UInt32,
  depth : Int32,
) -> Result[HiveSubkeyList, RegfError] {
  if depth > 8 {
    return Err(BadSubkeyList(offset.reinterpret_as_int()))
  }
  let cell = match read_cell(bytes, offset) {
    Err(error) => return Err(error)
    Ok(value) => value
  }
  let relative = cell.offset.reinterpret_as_int()
  if cell.payload_size < 4 {
    return Err(BadSubkeyList(relative))
  }
  let start = hive_bins_base + relative + 4
  let first = bytes[start].to_int()
  let second = bytes[start + 1].to_int()
  let mut kind : SubkeyListKind = Unknown(signature_hex_at(bytes, start))
  let mut width = 0
  let mut is_root = false
  if first == 0x6C && second == 0x66 {
    kind = FastLeaf
    width = 8
  } else if first == 0x6C && second == 0x68 {
    kind = HashLeaf
    width = 8
  } else if first == 0x6C && second == 0x69 {
    kind = IndexLeaf
    width = 4
  } else if first == 0x72 && second == 0x69 {
    kind = RootIndex
    width = 4
    is_root = true
  }
  if width == 0 {
    return Err(BadSubkeyList(relative))
  }
  let count = read_u16_le(bytes, start + 2).reinterpret_as_int()
  if 4 + count * width > cell.payload_size {
    return Err(BadSubkeyList(relative))
  }
  let key_offsets : Array[UInt32] = []
  let mut index = 0
  while index < count {
    let raw = read_u32_le(bytes, start + 4 + index * width)
    if is_root {
      match read_subkey_list_at(bytes, raw, depth + 1) {
        Err(error) => return Err(error)
        Ok(nested) => {
          let mut inner = 0
          while inner < nested.key_offsets.length() {
            key_offsets.push(nested.key_offsets[inner])
            inner = inner + 1
          }
        }
      }
    } else {
      key_offsets.push(raw)
    }
    index = index + 1
  }
  let list : HiveSubkeyList = { offset, kind, count, key_offsets, }
  Ok(list)
}

///|
/// Reads the direct children of a key.
///
/// This is the strict view: any unreadable child record fails the whole call.
pub fn list_subkeys(
  bytes : Bytes,
  key : HiveKeyNode,
) -> Result[Array[HiveKeyNode], RegfError] {
  let children : Array[HiveKeyNode] = []
  if key.subkey_count.reinterpret_as_int() <= 0 {
    return Ok(children)
  }
  if key.subkey_list_offset.reinterpret_as_int() == -1 {
    return Ok(children)
  }
  let offsets = match read_subkey_list(bytes, key.subkey_list_offset) {
    Err(error) => return Err(error)
    Ok(list) => list.key_offsets
  }
  let mut index = 0
  while index < offsets.length() {
    match parse_key_node(bytes, offsets[index]) {
      Err(error) => return Err(error)
      Ok(child) => children.push(child)
    }
    index = index + 1
  }
  Ok(children)
}

///|
/// Walks the key tree rooted at root_offset, descending max_depth levels.
///
/// The lenient view used for offline hives: children whose records cannot be
/// parsed are skipped, because hives can reference volatile or freed cells
/// that are absent from the file on disk.
pub fn walk_key_tree(
  bytes : Bytes,
  root_offset : UInt32,
  max_depth : Int32,
) -> Array[HiveKeyEntry] {
  let entries : Array[HiveKeyEntry] = []
  match parse_key_node(bytes, root_offset) {
    Err(_) => ()
    Ok(root) => walk_into(bytes, root, root.name, 0, max_depth, entries)
  }
  entries
}

///|
/// Depth first worker for walk_key_tree.
fn walk_into(
  bytes : Bytes,
  key : HiveKeyNode,
  path : String,
  depth : Int32,
  max_depth : Int32,
  entries : Array[HiveKeyEntry],
) -> Unit {
  let entry : HiveKeyEntry = {
    path,
    offset: key.offset,
    subkey_count: key.subkey_count.reinterpret_as_int(),
    value_count: key.value_count.reinterpret_as_int(),
  }
  entries.push(entry)
  if depth >= max_depth {
    return
  }
  if key.subkey_count.reinterpret_as_int() <= 0 {
    return
  }
  if key.subkey_list_offset.reinterpret_as_int() == -1 {
    return
  }
  let offsets = match read_subkey_list(bytes, key.subkey_list_offset) {
    Err(_) => return
    Ok(list) => list.key_offsets
  }
  let mut index = 0
  while index < offsets.length() {
    match parse_key_node(bytes, offsets[index]) {
      Err(_) => ()
      Ok(child) => {
        let child_path = if path == "" {
          child.name
        } else {
          path + "/" + child.name
        }
        walk_into(bytes, child, child_path, depth + 1, max_depth, entries)
      }
    }
    index = index + 1
  }
}
