///|
/// One value inside an editable tree.
pub(all) struct EditableValue {
  name : String
  data_type : HiveValueType
  data : Bytes
}

///|
/// One key inside an editable tree, carrying the metadata the writer needs to
/// reproduce the original key bit for bit.
pub(all) struct EditableKey {
  name : String
  parent : Int32
  children : Array[Int32]
  values : Array[EditableValue]
  high : UInt32
  low : UInt32
  access : UInt32
  flags : UInt32
  class_bytes : Bytes
  security : Bytes
}

///|
/// A hive loaded into memory so that it can be modified and written back.
pub struct HiveEditor {
  keys : Array[EditableKey]
  file_name : String
  sequence : Int32
  stamp_low : Int32
  stamp_high : Int32
}

///|
/// Reads the bytes of a class name the key points at.
fn class_bytes_of(bytes : Bytes, key : HiveKeyNode) -> Bytes {
  let relative = key.class_name_offset.reinterpret_as_int()
  let length = key.class_name_length.reinterpret_as_int()
  if relative < 0 || length <= 0 {
    return Bytes::new(0)
  }
  match read_cell(bytes, key.class_name_offset) {
    Err(_) => Bytes::new(0)
    Ok(cell) => {
      let available = if length > cell.payload_size {
        cell.payload_size
      } else {
        length
      }
      let start = hive_bins_base + relative + 4
      copy_range(bytes, start, available)
    }
  }
}

///|
/// Builds an editable key from a parsed nk record.
fn editable_from(
  bytes : Bytes,
  key : HiveKeyNode,
  parent : Int32,
) -> EditableKey {
  let values : Array[EditableValue] = []
  let offsets = match value_offsets(bytes, key) {
    Err(_) => []
    Ok(parsed) => parsed
  }
  let mut index = 0
  while index < offsets.length() {
    match parse_value(bytes, offsets[index]) {
      Err(_) => ()
      Ok(value) => {
        let entry : EditableValue = {
          name: value.name,
          data_type: value.data_type,
          data: value.data,
        }
        values.push(entry)
      }
    }
    index = index + 1
  }
  {
    name: key.name,
    parent,
    children: [],
    values,
    high: key.last_written_high,
    low: key.last_written_low,
    access: key.access_bits,
    flags: key.flags,
    class_bytes: class_bytes_of(bytes, key),
    security: security_bytes_of(bytes, key),
  }
}

///|
/// Loads every key, value and metadata field of a hive into memory.
pub fn HiveEditor::open(bytes : Bytes) -> Result[HiveEditor, RegfError] {
  let header = match parse_header(bytes) {
    Err(error) => return Err(error)
    Ok(parsed) => parsed
  }
  let root = match parse_key_node(bytes, header.root_cell_offset) {
    Err(error) => return Err(error)
    Ok(parsed) => parsed
  }
  let keys : Array[EditableKey] = [editable_from(bytes, root, -1)]
  let offsets : Array[UInt32] = [header.root_cell_offset]
  let mut index = 0
  while index < keys.length() {
    match parse_key_node(bytes, offsets[index]) {
      Err(_) => ()
      Ok(parent_node) =>
        match list_subkeys(bytes, parent_node) {
          Err(_) => ()
          Ok(children) => {
            let mut child = 0
            while child < children.length() {
              match parse_key_node(bytes, children[child].offset) {
                Err(_) => ()
                Ok(node) => {
                  let new_index = keys.length()
                  keys.push(editable_from(bytes, node, index))
                  offsets.push(children[child].offset)
                  keys[index].children.push(new_index)
                }
              }
              child = child + 1
            }
          }
        }
    }
    index = index + 1
  }
  let editor : HiveEditor = {
    keys,
    file_name: header.file_name,
    sequence: header.primary_sequence.reinterpret_as_int(),
    stamp_low: header.last_written_low.reinterpret_as_int(),
    stamp_high: header.last_written_high.reinterpret_as_int(),
  }
  Ok(editor)
}

///|
/// Splits a slash separated path into its segments.
fn editor_split_path(path : String) -> Array[String] {
  let raw = @utf8.encode(path)
  let out : Array[String] = []
  let mut start = 0
  let mut index = 0
  while index <= raw.length() {
    if index == raw.length() || raw[index].to_int() == 0x2F {
      if index > start {
        out.push(@utf8.decode_lossy(raw.clamped_view(start~, end=index)))
      }
      start = index + 1
    }
    index = index + 1
  }
  out
}

///|
/// Number of keys in the tree.
pub fn HiveEditor::key_count(self : HiveEditor) -> Int32 {
  self.keys.length()
}

///|
/// Name of the key at index.
pub fn HiveEditor::key_name(self : HiveEditor, index : Int32) -> String {
  self.keys[index].name
}

///|
/// Finds a key by a path such as ROOT/Software/Vendor.
pub fn HiveEditor::find(self : HiveEditor, path : String) -> Int32? {
  let segments = editor_split_path(path)
  let mut cursor = 0
  if segments.length() > 0 && segments[0] == self.keys[0].name {
    cursor = 1
  }
  let mut index = 0
  while cursor < segments.length() {
    let children = self.keys[index].children
    let mut found = -1
    let mut child = 0
    while child < children.length() {
      let candidate = children[child]
      if self.keys[candidate].name == segments[cursor] {
        found = candidate
      }
      child = child + 1
    }
    if found < 0 {
      return None
    }
    index = found
    cursor = cursor + 1
  }
  Some(index)
}

///|
/// Replaces a value by name, or appends it when the name is new.
pub fn HiveEditor::set_value(
  self : HiveEditor,
  key : Int32,
  name : String,
  data_type : HiveValueType,
  data : Bytes,
) -> Unit {
  let values = self.keys[key].values
  let mut index = 0
  while index < values.length() {
    if values[index].name == name {
      let replacement : EditableValue = { name, data_type, data, }
      values[index] = replacement
      return
    }
    index = index + 1
  }
  let appended : EditableValue = { name, data_type, data, }
  values.push(appended)
}

///|
/// Stores a REG_SZ value holding text as UTF-16LE with a terminating NUL.
pub fn HiveEditor::set_string(
  self : HiveEditor,
  key : Int32,
  name : String,
  text : String,
) -> Unit {
  let encoded = encode_utf16le(text)
  let terminated : Array[Byte] = []
  let mut index = 0
  while index < encoded.length() {
    terminated.push(encoded[index])
    index = index + 1
  }
  terminated.push((0).to_byte())
  terminated.push((0).to_byte())
  self.set_value(key, name, Sz, Bytes::from_array(terminated))
}

///|
/// Stores a REG_DWORD value.
pub fn HiveEditor::set_dword(
  self : HiveEditor,
  key : Int32,
  name : String,
  value : Int32,
) -> Unit {
  let out : Array[Byte] = []
  out.push((value & 0xFF).to_byte())
  out.push(((value >> 8) & 0xFF).to_byte())
  out.push(((value >> 16) & 0xFF).to_byte())
  out.push(((value >> 24) & 0xFF).to_byte())
  self.set_value(key, name, Dword, Bytes::from_array(out))
}

///|
/// Removes a value by name, reporting whether it existed.
pub fn HiveEditor::delete_value(
  self : HiveEditor,
  key : Int32,
  name : String,
) -> Bool {
  let old = self.keys[key]
  let kept : Array[EditableValue] = []
  let mut found = false
  let mut index = 0
  while index < old.values.length() {
    if old.values[index].name == name {
      found = true
    } else {
      kept.push(old.values[index])
    }
    index = index + 1
  }
  if found {
    let updated : EditableKey = {
      name: old.name,
      parent: old.parent,
      children: old.children,
      values: kept,
      high: old.high,
      low: old.low,
      access: old.access,
      flags: old.flags,
      class_bytes: old.class_bytes,
      security: old.security,
    }
    self.keys[key] = updated
  }
  found
}

///|
/// Adds a child key and returns its index.
pub fn HiveEditor::add_key(
  self : HiveEditor,
  parent : Int32,
  name : String,
) -> Int32 {
  let index = self.keys.length()
  let empty : Bytes = Bytes::new(0)
  let key : EditableKey = {
    name,
    parent,
    children: [],
    values: [],
    high: 0,
    low: 0,
    access: 0,
    flags: 0,
    class_bytes: empty,
    security: empty,
  }
  self.keys.push(key)
  self.keys[parent].children.push(index)
  index
}

///|
/// Removes a key together with everything below it.
pub fn HiveEditor::delete_key(self : HiveEditor, index : Int32) -> Bool {
  if index <= 0 || index >= self.keys.length() {
    return false
  }
  let removed : Array[Bool] = []
  let mut fill = 0
  while fill < self.keys.length() {
    removed.push(false)
    fill = fill + 1
  }
  removed[index] = true
  let mut scan = index
  while scan < self.keys.length() {
    if removed[scan] {
      let children = self.keys[scan].children
      let mut child = 0
      while child < children.length() {
        removed[children[child]] = true
        child = child + 1
      }
    }
    scan = scan + 1
  }
  let mapping = zero_ints(self.keys.length())
  let mut next = 0
  let mut walk = 0
  while walk < self.keys.length() {
    if removed[walk] {
      mapping[walk] = -1
    } else {
      mapping[walk] = next
      next = next + 1
    }
    walk = walk + 1
  }
  let kept : Array[EditableKey] = []
  walk = 0
  while walk < self.keys.length() {
    if !removed[walk] {
      let old = self.keys[walk]
      let children : Array[Int32] = []
      let mut child = 0
      while child < old.children.length() {
        if !removed[old.children[child]] {
          children.push(mapping[old.children[child]])
        }
        child = child + 1
      }
      let parent = if old.parent < 0 { -1 } else { mapping[old.parent] }
      let key : EditableKey = {
        name: old.name,
        parent,
        children,
        values: old.values,
        high: old.high,
        low: old.low,
        access: old.access,
        flags: old.flags,
        class_bytes: old.class_bytes,
        security: old.security,
      }
      kept.push(key)
    }
    walk = walk + 1
  }
  self.keys.clear()
  walk = 0
  while walk < kept.length() {
    self.keys.push(kept[walk])
    walk = walk + 1
  }
  true
}

///|
/// Copies the values of one editable key into the builder.
fn copy_values(
  builder : HiveBuilder,
  key : Int32,
  values : Array[EditableValue],
) -> Unit {
  let mut index = 0
  while index < values.length() {
    builder.set_value(
      key,
      values[index].name,
      values[index].data_type,
      values[index].data,
    )
    index = index + 1
  }
}

///|
/// Copies the metadata of one editable key into the builder.
fn copy_metadata(
  builder : HiveBuilder,
  key : Int32,
  source : EditableKey,
) -> Unit {
  builder.set_key_metadata(
    key,
    source.high,
    source.low,
    source.access,
    source.flags & 0xFFFFFFD3U,
  )
  if source.class_bytes.length() > 0 {
    builder.set_class_name(key, source.class_bytes)
  }
  if source.security.length() > 0 {
    builder.set_security(key, source.security)
  }
}

///|
/// Builds a writer that reproduces this tree, including its metadata.
pub fn HiveEditor::to_builder(self : HiveEditor) -> HiveBuilder {
  let builder = HiveBuilder::new_named(self.keys[0].name)
  builder.set_file_name(self.file_name)
  builder.set_header_metadata(self.sequence, self.stamp_low, self.stamp_high)
  copy_metadata(builder, 0, self.keys[0])
  copy_values(builder, 0, self.keys[0].values)
  let mut index = 0
  while index < self.keys.length() {
    let children = self.keys[index].children
    let mut child = 0
    while child < children.length() {
      let source = self.keys[children[child]]
      let added = builder.add_key(index, source.name)
      copy_metadata(builder, added, source)
      copy_values(builder, added, source.values)
      child = child + 1
    }
    index = index + 1
  }
  builder
}

///|
/// Writes the edited tree back into hive bytes.
pub fn HiveEditor::build(self : HiveEditor) -> Result[Bytes, RegfError] {
  self.to_builder().build()
}
