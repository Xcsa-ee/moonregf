///|
/// Offset of the first hive bin relative to the start of a hive file.
let hive_bins_base : Int32 = base_block_size

///|
/// A cell inside the hive bins region.
///
/// A cell starts with a signed 32-bit size that covers the size field itself:
/// negative sizes mark allocated cells, positive sizes mark free cells.
pub(all) struct HiveCell {
  offset : UInt32
  payload_size : Int32
  allocated : Bool
}

///|
/// Reads the cell header at offset, which is relative to the bins region.
pub fn read_cell(bytes : Bytes, offset : UInt32) -> Result[HiveCell, RegfError] {
  let relative = offset.reinterpret_as_int()
  let head = hive_bins_base + relative
  if relative < 0 || head + 4 > bytes.length() {
    return Err(BadCellOffset(relative))
  }
  let raw = read_u32_le(bytes, head).reinterpret_as_int()
  if raw == 0 || raw == -2147483648 {
    return Err(BadCellSize(relative))
  }
  let allocated = raw < 0
  let total = if allocated { -raw } else { raw }
  if total < 4 {
    return Err(BadCellSize(relative))
  }
  let payload_size = total - 4
  if head + 4 + payload_size > bytes.length() {
    return Err(BadCellSize(relative))
  }
  Ok({ offset, payload_size, allocated, })
}
