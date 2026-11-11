///|
/// How one access control entry grants, denies or audits access.
pub(all) enum AceType {
  AccessAllowed
  AccessDenied
  SystemAudit
  SystemAlarm
  AccessAllowedObject
  AccessDeniedObject
  SystemAuditObject
  SystemAlarmObject
  Unknown(Int32)
}

///|
/// Maps the numeric ACE type to the enumeration.
fn ace_type_from_code(code : Int32) -> AceType {
  match code {
    0 => AccessAllowed
    1 => AccessDenied
    2 => SystemAudit
    3 => SystemAlarm
    5 => AccessAllowedObject
    6 => AccessDeniedObject
    7 => SystemAuditObject
    8 => SystemAlarmObject
    other => Unknown(other)
  }
}

///|
/// Human readable label of an ACE type.
pub fn AceType::label(self : AceType) -> String {
  match self {
    AccessAllowed => "ACCESS_ALLOWED"
    AccessDenied => "ACCESS_DENIED"
    SystemAudit => "SYSTEM_AUDIT"
    SystemAlarm => "SYSTEM_ALARM"
    AccessAllowedObject => "ACCESS_ALLOWED_OBJECT"
    AccessDeniedObject => "ACCESS_DENIED_OBJECT"
    SystemAuditObject => "SYSTEM_AUDIT_OBJECT"
    SystemAlarmObject => "SYSTEM_ALARM_OBJECT"
    Unknown(code) => "ACE_TYPE_" + code.to_string()
  }
}

///|
/// One parsed access control entry.
pub(all) struct Ace {
  ace_type : AceType
  flags : Int32
  mask : UInt32
  sid : String
}

///|
/// Parses the ACL stored at offset: revision, size, entry count, then the
/// entries. Object entries carry one or two GUIDs before their SID, which the
/// object flags announce; anything that does not fit stops the walk instead of
/// inventing an entry.
pub fn parse_acl(
  bytes : Bytes,
  offset : Int32,
) -> Result[Array[Ace], RegfError] {
  if offset < 0 || offset + 8 > bytes.length() {
    return Err(BadSecurityDescriptor("the ACL is truncated"))
  }
  let revision = bytes[offset].to_int()
  let size = read_u16_le(bytes, offset + 2).reinterpret_as_int()
  let count = read_u16_le(bytes, offset + 4).reinterpret_as_int()
  if revision < 2 || revision > 4 {
    return Err(BadSecurityDescriptor("unknown ACL revision"))
  }
  if size < 8 || offset + size > bytes.length() {
    return Err(BadSecurityDescriptor("the ACL size is out of bounds"))
  }
  let aces : Array[Ace] = []
  let stop = offset + size
  let mut cursor = offset + 8
  let mut index = 0
  while index < count && cursor + 4 <= stop {
    let code = bytes[cursor].to_int()
    let ace_flags = bytes[cursor + 1].to_int()
    let ace_size = read_u16_le(bytes, cursor + 2).reinterpret_as_int()
    if ace_size < 8 || cursor + ace_size > stop {
      break
    }
    let mask = read_u32_le(bytes, cursor + 4)
    let mut sid_offset = cursor + 8
    if code >= 5 && code <= 8 && cursor + 12 <= stop {
      let object_flags = read_u32_le(bytes, cursor + 8).reinterpret_as_int()
      sid_offset = cursor + 12
      if (object_flags & 0x1) != 0 {
        sid_offset = sid_offset + 16
      }
      if (object_flags & 0x2) != 0 {
        sid_offset = sid_offset + 16
      }
    }
    let sid = if sid_offset + 8 <= cursor + ace_size {
      sid_to_string(bytes, sid_offset)
    } else {
      ""
    }
    let entry : Ace = {
      ace_type: ace_type_from_code(code),
      flags: ace_flags,
      mask,
      sid,
    }
    aces.push(entry)
    cursor = cursor + ace_size
    index = index + 1
  }
  Ok(aces)
}
