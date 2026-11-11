///|
/// Largest payload the writer stores in a single data cell.
let max_value_size : Int32 = 16344

///|
/// Largest number of children one leaf index holds before it is split.
let max_leaf_entries : Int32 = 500

///|
/// How the writer serializes a key subkey index.
pub(all) enum IndexKind {
  Auto
  FastLeaf
  HashLeaf
  IndexLeaf
  RootIndex
}

///|
/// Numeric writer code for an index kind: -1 auto, 1 lf, 2 lh, 3 li, 4 ri.
fn index_kind_code(kind : IndexKind) -> Int32 {
  match kind {
    Auto => -1
    FastLeaf => 1
    HashLeaf => 2
    IndexLeaf => 3
    RootIndex => 4
  }
}

///|
/// A value waiting to be written into a hive.
struct BuildValue {
  name : String
  data_type : HiveValueType
  data : Bytes
}

///|
/// A tree of keys and values that build() turns into a REGF hive.
///
/// Nodes are addressed by index; node 0 is the root key.
pub struct HiveBuilder {
  names : Array[String]
  parents : Array[Int32]
  children : Array[Array[Int32]]
  values : Array[Array[BuildValue]]
  kinds : Array[Int32]
  securities : Array[Bytes]
  highs : Array[UInt32]
  lows : Array[UInt32]
  access : Array[UInt32]
  extras : Array[UInt32]
  classes : Array[Bytes]
  mut file_name : String
  mut sequence : Int32
  mut stamp_low : Int32
  mut stamp_high : Int32
}

///|
/// Number of segments a big value of length bytes needs.
fn big_segment_count(length : Int32) -> Int32 {
  (length + max_value_size - 1) / max_value_size
}

///|
/// Rounds a byte count up to the next multiple of eight.
fn align8(value : Int32) -> Int32 {
  (value + 7) / 8 * 8
}

///|
/// Total size of a cell whose payload holds payload_size bytes.
fn cell_size(payload_size : Int32) -> Int32 {
  let total = align8(4 + payload_size)
  if total < 8 {
    8
  } else {
    total
  }
}

///|
/// Writes a signed 32-bit value as four little-endian bytes.
fn w_i32(bytes : Array[Byte], offset : Int32, value : Int32) -> Unit {
  bytes[offset] = (value & 0xFF).to_byte()
  bytes[offset + 1] = ((value >> 8) & 0xFF).to_byte()
  bytes[offset + 2] = ((value >> 16) & 0xFF).to_byte()
  bytes[offset + 3] = ((value >> 24) & 0xFF).to_byte()
}

///|
/// Writes a 16-bit value as two little-endian bytes.
fn w_u16(bytes : Array[Byte], offset : Int32, value : Int32) -> Unit {
  bytes[offset] = (value & 0xFF).to_byte()
  bytes[offset + 1] = ((value >> 8) & 0xFF).to_byte()
}

///|
/// Copies raw bytes to offset.
fn w_bytes(bytes : Array[Byte], offset : Int32, source : Bytes) -> Unit {
  let mut index = 0
  while index < source.length() {
    bytes[offset + index] = source[index]
    index = index + 1
  }
}

///|
/// True when every byte is ASCII.
fn is_ascii(bytes : Bytes) -> Bool {
  let mut index = 0
  while index < bytes.length() {
    if bytes[index].to_int() >= 0x80 {
      return false
    }
    index = index + 1
  }
  true
}

///|
/// A name encoded the way the hive stores it: ASCII stays one byte per
/// character, any other script becomes UTF-16LE.
priv struct EncodedName {
  bytes : Bytes
  compressed : Bool
}

///|
/// Encodes a name for storage, keeping ASCII compressed and everything else in
/// UTF-16LE so CJK and other scripts survive the round trip.
fn encode_name(text : String) -> EncodedName {
  let raw = @utf8.encode(text)
  if is_ascii(raw) {
    let out : EncodedName = { bytes: raw, compressed: true, }
    out
  } else {
    let out : EncodedName = { bytes: encode_utf16le(text), compressed: false, }
    out
  }
}

///|
/// Builds an array holding count zeros.
fn zero_ints(count : Int32) -> Array[Int32] {
  let out : Array[Int32] = []
  let mut index = 0
  while index < count {
    out.push(0)
    index = index + 1
  }
  out
}

///|
/// XOR checksum over the first 508 bytes of a byte array.
fn array_checksum(bytes : Array[Byte]) -> UInt32 {
  let mut acc : UInt32 = 0
  let mut offset = 0
  while offset < 508 {
    let b0 = bytes[offset].to_uint()
    let b1 = bytes[offset + 1].to_uint()
    let b2 = bytes[offset + 2].to_uint()
    let b3 = bytes[offset + 3].to_uint()
    acc = acc ^ (b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
    offset = offset + 4
  }
  acc
}

///|
/// Uppercases up to four ASCII bytes into a little-endian lf hint.
fn name_hint(name : Bytes) -> Int32 {
  let mut hint = 0
  let mut index = 0
  while index < name.length() && index < 4 {
    let mut byte = name[index].to_int()
    if byte >= 0x61 && byte <= 0x7A {
      byte = byte - 0x20
    }
    hint = hint | (byte << (index * 8))
    index = index + 1
  }
  hint
}

///|
/// Hash Windows stores beside each entry of an lh list: 37 times the running
/// value plus the upper cased code unit, wrapping at 32 bits.
fn lh_hash(name : Bytes, compressed : Bool) -> Int32 {
  let mut hash = 0
  let mut index = 0
  if compressed {
    while index < name.length() {
      let mut byte = name[index].to_int()
      if byte >= 0x61 && byte <= 0x7A {
        byte = byte - 0x20
      }
      hash = hash * 37 + byte
      index = index + 1
    }
  } else {
    while index + 1 < name.length() {
      let mut unit = name[index].to_int() | (name[index + 1].to_int() << 8)
      if unit >= 0x61 && unit <= 0x7A {
        unit = unit - 0x20
      }
      hash = hash * 37 + unit
      index = index + 2
    }
  }
  hash
}

///|
/// Picks the serialized index for a key: 0 none, 1 lf, 2 lh, 3 li, 4 ri.
fn choose_index_kind(
  requested : Int32,
  child_count : Int32,
  all_compressed : Bool,
) -> Int32 {
  if child_count == 0 {
    return 0
  }
  if requested >= 1 && requested <= 4 {
    return requested
  }
  if child_count > max_leaf_entries {
    return 4
  }
  if all_compressed {
    1
  } else {
    2
  }
}

///|
/// Numeric type code stored in a vk record.
fn value_type_code(data_type : HiveValueType) -> Int32 {
  match data_type {
    Nil => 0
    Sz => 1
    ExpandSz => 2
    Binary => 3
    Dword => 4
    DwordBigEndian => 5
    Link => 6
    MultiSz => 7
    ResourceList => 8
    FullResourceDescriptor => 9
    ResourceRequirementsList => 10
    Qword => 11
    Unknown(code) => code.reinterpret_as_int()
  }
}

///|
/// Longest key name among the given children.
fn longest_child_name(names : Array[Bytes], children : Array[Int32]) -> Int32 {
  let mut longest = 0
  let mut index = 0
  while index < children.length() {
    let length = names[children[index]].length()
    if length > longest {
      longest = length
    }
    index = index + 1
  }
  longest
}

///|
/// Longest value name of one key.
fn longest_value_name(names : Array[Bytes]) -> Int32 {
  let mut longest = 0
  let mut index = 0
  while index < names.length() {
    if names[index].length() > longest {
      longest = names[index].length()
    }
    index = index + 1
  }
  longest
}

///|
/// Largest value payload of one key.
fn largest_value_size(values : Array[BuildValue]) -> Int32 {
  let mut largest = 0
  let mut index = 0
  while index < values.length() {
    if values[index].data.length() > largest {
      largest = values[index].data.length()
    }
    index = index + 1
  }
  largest
}

///|
/// Creates a builder holding a single root key called ROOT.
pub fn HiveBuilder::new() -> HiveBuilder {
  HiveBuilder::new_named("ROOT")
}

///|
/// Creates a builder whose root key uses root_name.
pub fn HiveBuilder::new_named(root_name : String) -> HiveBuilder {
  let names : Array[String] = [root_name]
  let parents : Array[Int32] = [-1]
  let children : Array[Array[Int32]] = []
  children.push([])
  let values : Array[Array[BuildValue]] = []
  values.push([])
  let kinds : Array[Int32] = [-1]
  let empty : Bytes = Bytes::new(0)
  let securities : Array[Bytes] = [empty]
  let highs : Array[UInt32] = [0]
  let lows : Array[UInt32] = [0]
  let access : Array[UInt32] = [0]
  let extras : Array[UInt32] = [0]
  let classes : Array[Bytes] = [empty]
  {
    file_name: root_name,
    sequence: 1,
    stamp_low: 0,
    stamp_high: 0,
    names,
    parents,
    children,
    values,
    kinds,
    securities,
    highs,
    lows,
    access,
    extras,
    classes,
  }
}

///|
/// Number of keys in the tree.
pub fn HiveBuilder::key_count(self : HiveBuilder) -> Int32 {
  self.names.length()
}

///|
/// Adds a child key under parent and returns its index.
pub fn HiveBuilder::add_key(
  self : HiveBuilder,
  parent : Int32,
  name : String,
) -> Int32 {
  let index = self.names.length()
  self.names.push(name)
  self.parents.push(parent)
  self.children.push([])
  self.values.push([])
  self.kinds.push(-1)
  let empty : Bytes = Bytes::new(0)
  self.securities.push(empty)
  self.highs.push(0)
  self.lows.push(0)
  self.access.push(0)
  self.extras.push(0)
  self.classes.push(empty)
  self.children[parent].push(index)
  index
}

///|
/// Stores one value under the key at key_index.
pub fn HiveBuilder::set_value(
  self : HiveBuilder,
  key_index : Int32,
  name : String,
  data_type : HiveValueType,
  data : Bytes,
) -> Unit {
  let value : BuildValue = { name, data_type, data, }
  self.values[key_index].push(value)
}

///|
/// Stores a REG_SZ value holding text.
pub fn HiveBuilder::set_string(
  self : HiveBuilder,
  key_index : Int32,
  name : String,
  text : String,
) -> Unit {
  let encoded = encode_utf16le(text)
  let terminated : Array[Byte] = []
  let mut cursor = 0
  while cursor < encoded.length() {
    terminated.push(encoded[cursor])
    cursor = cursor + 1
  }
  terminated.push((0).to_byte())
  terminated.push((0).to_byte())
  self.set_value(key_index, name, Sz, Bytes::from_array(terminated))
}

///|
/// Stores a REG_DWORD value.
pub fn HiveBuilder::set_dword(
  self : HiveBuilder,
  key_index : Int32,
  name : String,
  value : Int32,
) -> Unit {
  let out : Array[Byte] = []
  out.push((value & 0xFF).to_byte())
  out.push(((value >> 8) & 0xFF).to_byte())
  out.push(((value >> 16) & 0xFF).to_byte())
  out.push(((value >> 24) & 0xFF).to_byte())
  self.set_value(key_index, name, Dword, Bytes::from_array(out))
}

///|
/// Attaches a self-relative security descriptor to a key.
///
/// The bytes become the payload of an sk record. Pass the output of
/// security_descriptor_with_owner_group() when only an owner and a group are
/// needed.
pub fn HiveBuilder::set_security(
  self : HiveBuilder,
  key_index : Int32,
  descriptor : Bytes,
) -> Unit {
  self.securities[key_index] = descriptor
}

///|
/// Overrides the file name written into the base block.
pub fn HiveBuilder::set_file_name(self : HiveBuilder, text : String) -> Unit {
  self.file_name = text
}

///|
/// Overrides the sequence numbers and the write timestamp of the base block.
pub fn HiveBuilder::set_header_metadata(
  self : HiveBuilder,
  sequence : Int32,
  stamp_low : Int32,
  stamp_high : Int32,
) -> Unit {
  self.sequence = sequence
  self.stamp_low = stamp_low
  self.stamp_high = stamp_high
}

///|
/// Copies the metadata of an existing key: the two halves of its last write
/// timestamp, its access bits and any nk flag bit the caller wants kept.
pub fn HiveBuilder::set_key_metadata(
  self : HiveBuilder,
  key_index : Int32,
  high : UInt32,
  low : UInt32,
  access : UInt32,
  extra_flags : UInt32,
) -> Unit {
  self.highs[key_index] = high
  self.lows[key_index] = low
  self.access[key_index] = access
  self.extras[key_index] = extra_flags
}

///|
/// Attaches a class name to a key. The bytes are stored as is, in UTF-16LE.
pub fn HiveBuilder::set_class_name(
  self : HiveBuilder,
  key_index : Int32,
  bytes : Bytes,
) -> Unit {
  self.classes[key_index] = bytes
}

///|
/// Forces the index kind of one key instead of letting build() choose.
pub fn HiveBuilder::set_index_kind(
  self : HiveBuilder,
  key_index : Int32,
  kind : IndexKind,
) -> Unit {
  self.kinds[key_index] = index_kind_code(kind)
}

///|
/// Bumps a cursor through contiguous bins.
///
/// A bin is at least 4096 bytes and always a multiple of 4096. Its first 32
/// bytes are the hbin header, so a cell offset is never a multiple of 4096.
/// Every cell stays inside one bin: when a cell does not fit, the tail of the
/// bin becomes one free cell and the next bin is started.
priv struct BinCursor {
  mut cursor : Int32
  mut bin_start : Int32
  mut bin_bytes : Int32
  bins_at : Array[Int32]
  bins_len : Array[Int32]
  pads_at : Array[Int32]
  pads_size : Array[Int32]
}

///|
/// Smallest bin that fits a cell of size bytes next to its 32 byte header.
fn cell_bins_size(size : Int32) -> Int32 {
  let needed = size + 32
  let mut capacity = 4096
  while capacity < needed {
    capacity = capacity + 4096
  }
  capacity
}

///|
/// Reserves size bytes and returns the cell offset inside the bins region.
///
/// The returned offset is never a multiple of 4096 because every bin starts
/// with a 32 byte header that cells must not overlap.
fn allocate(bins : BinCursor, size : Int32) -> Int32 {
  if bins.cursor == bins.bin_start + 32 {
    bins.bin_bytes = cell_bins_size(size)
    bins.bins_at.push(bins.bin_start)
    bins.bins_len.push(bins.bin_bytes)
  } else if bins.cursor + size > bins.bin_start + bins.bin_bytes {
    let pad = bins.bin_start + bins.bin_bytes - bins.cursor
    if pad > 0 {
      bins.pads_at.push(bins.cursor)
      bins.pads_size.push(pad)
    }
    bins.bin_start = bins.bin_start + bins.bin_bytes
    bins.cursor = bins.bin_start + 32
    bins.bin_bytes = cell_bins_size(size)
    bins.bins_at.push(bins.bin_start)
    bins.bins_len.push(bins.bin_bytes)
  }
  let at = bins.cursor
  bins.cursor = at + size
  at
}

///|
/// Serializes the tree into a REGF hive file.
///
/// The layout is the one Windows uses: a 4096-byte base block, then one or
/// more hive bins whose cells carry the nk, vk and lf records. Key names must
/// be ASCII and a value payload must fit in one data cell (16344 bytes).
pub fn HiveBuilder::build(self : HiveBuilder) -> Result[Bytes, RegfError] {
  let count = self.names.length()
  let names : Array[Bytes] = []
  let name_flags : Array[Bool] = []
  let mut index = 0
  while index < count {
    let encoded = encode_name(self.names[index])
    names.push(encoded.bytes)
    name_flags.push(encoded.compressed)
    index = index + 1
  }
  let value_names : Array[Array[Bytes]] = []
  let value_flags : Array[Array[Bool]] = []
  index = 0
  while index < count {
    let per_key : Array[Bytes] = []
    let per_flag : Array[Bool] = []
    let mut inner = 0
    while inner < self.values[index].length() {
      let encoded = encode_name(self.values[index][inner].name)
      per_key.push(encoded.bytes)
      per_flag.push(encoded.compressed)
      inner = inner + 1
    }
    value_names.push(per_key)
    value_flags.push(per_flag)
    index = index + 1
  }
  let nk_offsets = zero_ints(count)
  let value_list_offsets = zero_ints(count)
  let subkey_list_offsets = zero_ints(count)
  let subkey_kinds = zero_ints(count)
  let sk_offsets = zero_ints(count)
  let class_offsets = zero_ints(count)
  let chunk_offsets : Array[Array[Int32]] = []
  let vk_offsets : Array[Array[Int32]] = []
  let data_offsets : Array[Array[Int32]] = []
  let db_offsets : Array[Array[Int32]] = []
  let segment_offsets : Array[Array[Array[Int32]]] = []
  index = 0
  while index < count {
    vk_offsets.push([])
    data_offsets.push([])
    db_offsets.push([])
    segment_offsets.push([])
    chunk_offsets.push([])
    index = index + 1
  }
  index = 0
  while index < count {
    let child_count = self.children[index].length()
    let mut all_compressed = true
    let mut probe = 0
    while probe < child_count {
      if !name_flags[self.children[index][probe]] {
        all_compressed = false
      }
      probe = probe + 1
    }
    subkey_kinds[index] = choose_index_kind(
      self.kinds[index],
      child_count,
      all_compressed,
    )
    index = index + 1
  }
  let bins : BinCursor = {
    cursor: 32,
    bin_start: 0,
    bin_bytes: 4096,
    bins_at: [],
    bins_len: [],
    pads_at: [],
    pads_size: [],
  }
  index = 0
  while index < count {
    nk_offsets[index] = allocate(bins, cell_size(76 + names[index].length()))
    if self.securities[index].length() > 0 {
      sk_offsets[index] = allocate(
        bins,
        cell_size(20 + self.securities[index].length()),
      )
    } else {
      sk_offsets[index] = -1
    }
    if self.classes[index].length() > 0 {
      class_offsets[index] = allocate(
        bins,
        cell_size(self.classes[index].length()),
      )
    } else {
      class_offsets[index] = -1
    }
    let value_count = self.values[index].length()
    if value_count > 0 {
      value_list_offsets[index] = allocate(bins, cell_size(value_count * 4))
    } else {
      value_list_offsets[index] = -1
    }
    let mut inner = 0
    while inner < value_count {
      vk_offsets[index].push(
        allocate(bins, cell_size(20 + value_names[index][inner].length())),
      )
      let length = self.values[index][inner].data.length()
      if length > max_value_size {
        let segments = big_segment_count(length)
        data_offsets[index].push(-1)
        db_offsets[index].push(allocate(bins, cell_size(4 + 4 * segments)))
        let offsets : Array[Int32] = []
        let mut segment = 0
        while segment < segments {
          let remaining = length - segment * max_value_size
          let size = if remaining > max_value_size {
            max_value_size
          } else {
            remaining
          }
          offsets.push(allocate(bins, cell_size(size)))
          segment = segment + 1
        }
        segment_offsets[index].push(offsets)
      } else if length > 4 {
        data_offsets[index].push(allocate(bins, cell_size(length)))
        db_offsets[index].push(-1)
        segment_offsets[index].push([])
      } else {
        data_offsets[index].push(-1)
        db_offsets[index].push(-1)
        segment_offsets[index].push([])
      }
      inner = inner + 1
    }
    let child_count = self.children[index].length()
    if child_count > 0 {
      if subkey_kinds[index] == 4 {
        let chunks = (child_count + max_leaf_entries - 1) / max_leaf_entries
        subkey_list_offsets[index] = allocate(bins, cell_size(4 + 4 * chunks))
        let mut chunk = 0
        while chunk < chunks {
          let start = chunk * max_leaf_entries
          let mut stop = start + max_leaf_entries
          if stop > child_count {
            stop = child_count
          }
          chunk_offsets[index].push(
            allocate(bins, cell_size(4 + 8 * (stop - start))),
          )
          chunk = chunk + 1
        }
      } else {
        let entry_size = if subkey_kinds[index] == 3 { 4 } else { 8 }
        subkey_list_offsets[index] = allocate(
          bins,
          cell_size(4 + entry_size * child_count),
        )
      }
    } else {
      subkey_list_offsets[index] = -1
    }
    index = index + 1
  }
  let tail = bins.bin_start + bins.bin_bytes
  if bins.cursor < tail {
    bins.pads_at.push(bins.cursor)
    bins.pads_size.push(tail - bins.cursor)
  }
  let bins_size = tail
  let file = Bytes::new(base_block_size + bins_size).to_array()
  w_i32(file, 0, 0x66676572)
  w_i32(file, 0x04, self.sequence)
  w_i32(file, 0x08, self.sequence)
  w_i32(file, 0x0C, self.stamp_low)
  w_i32(file, 0x10, self.stamp_high)
  w_i32(file, 0x14, 1)
  w_i32(file, 0x18, 5)
  w_i32(file, 0x1C, 0)
  w_i32(file, 0x20, 1)
  w_i32(file, 0x24, nk_offsets[0])
  w_i32(file, 0x28, bins_size)
  w_i32(file, 0x2C, 1)
  let label = encode_utf16le(self.file_name)
  let mut unit = 0
  while unit < 32 && unit * 2 + 1 < label.length() {
    file[0x30 + unit * 2] = label[unit * 2]
    file[0x30 + unit * 2 + 1] = label[unit * 2 + 1]
    unit = unit + 1
  }
  let checksum = array_checksum(file)
  w_i32(file, 0x1FC, checksum.reinterpret_as_int())
  let mut bin = 0
  while bin < bins.bins_at.length() {
    let head = base_block_size + bins.bins_at[bin]
    w_i32(file, head, 0x6E696268)
    w_i32(file, head + 4, bins.bins_at[bin])
    w_i32(file, head + 8, bins.bins_len[bin])
    bin = bin + 1
  }
  bin = 0
  while bin < bins.pads_at.length() {
    w_i32(file, base_block_size + bins.pads_at[bin], bins.pads_size[bin])
    bin = bin + 1
  }
  index = 0
  while index < count {
    let offset = nk_offsets[index]
    let name = names[index]
    let total = cell_size(76 + name.length())
    w_i32(file, base_block_size + offset, -total)
    let head = base_block_size + offset + 4
    w_u16(file, head, 0x6B6E)
    let mut flags = 0
    if name_flags[index] {
      flags = 0x20
    }
    flags = flags | self.extras[index].reinterpret_as_int()
    if index == 0 {
      flags = flags | 0x0C
    }
    w_u16(file, head + 2, flags)
    w_i32(file, head + 4, self.highs[index].reinterpret_as_int())
    w_i32(file, head + 8, self.lows[index].reinterpret_as_int())
    w_i32(file, head + 12, self.access[index].reinterpret_as_int())
    let parent = if index == 0 { -1 } else { nk_offsets[self.parents[index]] }
    w_i32(file, head + 16, parent)
    w_i32(file, head + 20, self.children[index].length())
    w_i32(file, head + 24, 0)
    w_i32(file, head + 28, subkey_list_offsets[index])
    w_i32(file, head + 32, -1)
    w_i32(file, head + 36, self.values[index].length())
    w_i32(file, head + 40, value_list_offsets[index])
    w_i32(file, head + 44, sk_offsets[index])
    w_i32(file, head + 48, class_offsets[index])
    w_i32(file, head + 52, longest_child_name(names, self.children[index]))
    w_i32(file, head + 56, 0)
    w_i32(file, head + 60, longest_value_name(value_names[index]))
    w_i32(file, head + 64, largest_value_size(self.values[index]))
    w_i32(file, head + 68, 0)
    w_u16(file, head + 72, name.length())
    w_u16(file, head + 74, self.classes[index].length())
    w_bytes(file, head + 76, name)
    if class_offsets[index] >= 0 {
      let class_bytes = self.classes[index]
      let class_total = cell_size(class_bytes.length())
      w_i32(file, base_block_size + class_offsets[index], -class_total)
      w_bytes(file, base_block_size + class_offsets[index] + 4, class_bytes)
    }
    if sk_offsets[index] >= 0 {
      let descriptor = self.securities[index]
      let sk_total = cell_size(20 + descriptor.length())
      w_i32(file, base_block_size + sk_offsets[index], -sk_total)
      let sk_head = base_block_size + sk_offsets[index] + 4
      w_u16(file, sk_head, 0x6B73)
      w_u16(file, sk_head + 2, 0)
      w_i32(file, sk_head + 4, -1)
      w_i32(file, sk_head + 8, -1)
      w_i32(file, sk_head + 12, 1)
      w_i32(file, sk_head + 16, descriptor.length())
      w_bytes(file, sk_head + 20, descriptor)
    }
    let value_count = self.values[index].length()
    if value_list_offsets[index] >= 0 {
      let list_total = cell_size(value_count * 4)
      w_i32(file, base_block_size + value_list_offsets[index], -list_total)
      let list_head = base_block_size + value_list_offsets[index] + 4
      let mut inner = 0
      while inner < value_count {
        w_i32(file, list_head + inner * 4, vk_offsets[index][inner])
        inner = inner + 1
      }
    }
    let mut inner = 0
    while inner < value_count {
      let value = self.values[index][inner]
      let value_name = value_names[index][inner]
      let vk = vk_offsets[index][inner]
      let total_vk = cell_size(20 + value_name.length())
      w_i32(file, base_block_size + vk, -total_vk)
      let vk_head = base_block_size + vk + 4
      w_u16(file, vk_head, 0x6B76)
      w_u16(file, vk_head + 2, value_name.length())
      let length = value.data.length()
      if length == 0 {
        w_i32(file, vk_head + 4, 0)
        w_i32(file, vk_head + 8, -1)
      } else if length <= 4 {
        w_i32(file, vk_head + 4, -length)
        let mut packed = 0
        let mut byte = 0
        while byte < length {
          packed = packed | (value.data[byte].to_int() << (byte * 8))
          byte = byte + 1
        }
        w_i32(file, vk_head + 8, packed)
      } else if length > max_value_size {
        w_i32(file, vk_head + 4, length)
        w_i32(file, vk_head + 8, db_offsets[index][inner])
      } else {
        w_i32(file, vk_head + 4, length)
        w_i32(file, vk_head + 8, data_offsets[index][inner])
      }
      w_i32(file, vk_head + 12, value_type_code(value.data_type))
      let name_flag = if value_flags[index][inner] { 1 } else { 0 }
      w_u16(file, vk_head + 16, name_flag)
      w_u16(file, vk_head + 18, 0)
      w_bytes(file, vk_head + 20, value_name)
      if length > max_value_size {
        let segments = big_segment_count(length)
        let db_offset = db_offsets[index][inner]
        let db_total = cell_size(4 + 4 * segments)
        w_i32(file, base_block_size + db_offset, -db_total)
        let db_head = base_block_size + db_offset + 4
        w_u16(file, db_head, 0x6264)
        w_u16(file, db_head + 2, segments)
        let mut segment = 0
        while segment < segments {
          let target = segment_offsets[index][inner][segment]
          w_i32(file, db_head + 4 + segment * 4, target)
          let remaining = length - segment * max_value_size
          let size = if remaining > max_value_size {
            max_value_size
          } else {
            remaining
          }
          let segment_total = cell_size(size)
          w_i32(file, base_block_size + target, -segment_total)
          let mut byte = 0
          while byte < size {
            file[base_block_size + target + 4 + byte] = value.data[segment *
              max_value_size +
              byte]
            byte = byte + 1
          }
          segment = segment + 1
        }
      } else if length > 4 {
        let data_total = cell_size(length)
        let data_offset = data_offsets[index][inner]
        w_i32(file, base_block_size + data_offset, -data_total)
        w_bytes(file, base_block_size + data_offset + 4, value.data)
      }
      inner = inner + 1
    }
    let child_count = self.children[index].length()
    if subkey_list_offsets[index] >= 0 {
      if subkey_kinds[index] == 4 {
        let chunks = (child_count + max_leaf_entries - 1) / max_leaf_entries
        let ri_total = cell_size(4 + 4 * chunks)
        w_i32(file, base_block_size + subkey_list_offsets[index], -ri_total)
        let ri_head = base_block_size + subkey_list_offsets[index] + 4
        w_u16(file, ri_head, 0x6972)
        w_u16(file, ri_head + 2, chunks)
        let mut chunk = 0
        while chunk < chunks {
          w_i32(file, ri_head + 4 + chunk * 4, chunk_offsets[index][chunk])
          chunk = chunk + 1
        }
        chunk = 0
        while chunk < chunks {
          let start = chunk * max_leaf_entries
          let mut stop = start + max_leaf_entries
          if stop > child_count {
            stop = child_count
          }
          let entries = stop - start
          let chunk_total = cell_size(4 + 8 * entries)
          w_i32(
            file,
            base_block_size + chunk_offsets[index][chunk],
            -chunk_total,
          )
          let chunk_head = base_block_size + chunk_offsets[index][chunk] + 4
          w_u16(file, chunk_head, 0x686C)
          w_u16(file, chunk_head + 2, entries)
          let mut entry = 0
          while entry < entries {
            let child_index = self.children[index][start + entry]
            w_i32(file, chunk_head + 4 + entry * 8, nk_offsets[child_index])
            w_i32(
              file,
              chunk_head + 8 + entry * 8,
              lh_hash(names[child_index], name_flags[child_index]),
            )
            entry = entry + 1
          }
          chunk = chunk + 1
        }
      } else if subkey_kinds[index] == 3 {
        let li_total = cell_size(4 + 4 * child_count)
        w_i32(file, base_block_size + subkey_list_offsets[index], -li_total)
        let li_head = base_block_size + subkey_list_offsets[index] + 4
        w_u16(file, li_head, 0x696C)
        w_u16(file, li_head + 2, child_count)
        let mut child = 0
        while child < child_count {
          let child_index = self.children[index][child]
          w_i32(file, li_head + 4 + child * 4, nk_offsets[child_index])
          child = child + 1
        }
      } else {
        let hashed = subkey_kinds[index] == 2
        let list_total = cell_size(4 + 8 * child_count)
        w_i32(file, base_block_size + subkey_list_offsets[index], -list_total)
        let list_head = base_block_size + subkey_list_offsets[index] + 4
        let signature = if hashed { 0x686C } else { 0x666C }
        w_u16(file, list_head, signature)
        w_u16(file, list_head + 2, child_count)
        let mut child = 0
        while child < child_count {
          let child_index = self.children[index][child]
          w_i32(file, list_head + 4 + child * 8, nk_offsets[child_index])
          let hint = if hashed {
            lh_hash(names[child_index], name_flags[child_index])
          } else {
            name_hint(names[child_index])
          }
          w_i32(file, list_head + 8 + child * 8, hint)
          child = child + 1
        }
      }
    }
    index = index + 1
  }
  Ok(Bytes::from_array(file))
}

///|
/// Index of the child of parent whose name matches exactly, if any.
pub fn HiveBuilder::child_index(
  self : HiveBuilder,
  parent : Int32,
  name : String,
) -> Int32? {
  let children = self.children[parent]
  let mut index = 0
  while index < children.length() {
    let candidate = children[index]
    if self.names[candidate] == name {
      return Some(candidate)
    }
    index = index + 1
  }
  None
}
