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
  let limit = bytes.length() - hive_bins_base - 4
  if relative < 0 || limit < 0 || relative > limit {
    return Err(BadCellOffset(relative))
  }
  let head = hive_bins_base + relative
  let raw = read_u32_le(bytes, head).reinterpret_as_int()
  if raw == 0 || raw == -2147483648 {
    return Err(BadCellSize(relative))
  }
  let allocated = raw < 0
  let total = if allocated { -raw } else { raw }
  if total < 4 || total > bytes.length() - head {
    return Err(BadCellSize(relative))
  }
  let payload_size = total - 4
  Ok({ offset, payload_size, allocated, })
}
