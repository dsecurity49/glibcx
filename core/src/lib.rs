//! Bounds-checked ELF inspection for the glibcx Bash frontend.
//!
//! Protocol 1 deliberately owns parsing only. Resolver policy and all mutable
//! state remain in Bash until the schema-4 migration.

use std::fs;
use std::path::Path;

pub const PROTOCOL: u32 = 1;
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Target,
    Dso,
}

impl Mode {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "target" => Some(Self::Target),
            "dso" => Some(Self::Dso),
            _ => None,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Target => "target",
            Self::Dso => "dso",
        }
    }
}

#[derive(Debug, Default)]
struct Parsed {
    class: String,
    data: String,
    elf_type: String,
    machine: String,
    interpreter: Option<String>,
    interpreter_count: usize,
    has_dynamic: bool,
    gnu_stack_flags: Option<String>,
    wx_load: bool,
    needed: Vec<String>,
    soname: Option<String>,
    rpath: Vec<String>,
    runpath: Vec<String>,
    flags: Vec<String>,
    audit_tags: Vec<String>,
    text_relocations: bool,
    build_id: Option<String>,
    abi: Option<String>,
    versions: Vec<String>,
}

fn read_u16(data: &[u8], offset: usize) -> Result<u16, String> {
    let bytes = data
        .get(offset..offset + 2)
        .ok_or("truncated ELF structure")?;
    Ok(u16::from_le_bytes([bytes[0], bytes[1]]))
}

fn read_u32(data: &[u8], offset: usize) -> Result<u32, String> {
    let bytes = data
        .get(offset..offset + 4)
        .ok_or("truncated ELF structure")?;
    Ok(u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
}

fn read_u64(data: &[u8], offset: usize) -> Result<u64, String> {
    let bytes = data
        .get(offset..offset + 8)
        .ok_or("truncated ELF structure")?;
    Ok(u64::from_le_bytes(
        bytes.try_into().expect("slice length is checked"),
    ))
}

fn to_usize(value: u64) -> Result<usize, String> {
    usize::try_from(value).map_err(|_| "ELF offset does not fit this platform".to_owned())
}

fn range(data: &[u8], offset: u64, size: u64) -> Result<&[u8], String> {
    let start = to_usize(offset)?;
    let len = to_usize(size)?;
    let end = start.checked_add(len).ok_or("ELF range overflows")?;
    data.get(start..end)
        .ok_or("ELF range is outside the file".to_owned())
}

fn c_string(data: &[u8], offset: u64) -> Result<String, String> {
    let start = to_usize(offset)?;
    let rest = data
        .get(start..)
        .ok_or("string offset is outside the string table")?;
    let end = rest
        .iter()
        .position(|byte| *byte == 0)
        .ok_or("unterminated ELF string")?;
    Ok(String::from_utf8_lossy(&rest[..end]).into_owned())
}

fn align4(value: usize) -> Result<usize, String> {
    value
        .checked_add(3)
        .map(|v| v & !3)
        .ok_or("ELF note alignment overflows".to_owned())
}

fn json_string(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len() + 2);
    escaped.push('"');
    for ch in value.chars() {
        match ch {
            '"' => escaped.push_str("\\\""),
            '\\' => escaped.push_str("\\\\"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            c if c.is_control() => escaped.push_str(&format!("\\u{:04x}", c as u32)),
            c => escaped.push(c),
        }
    }
    escaped.push('"');
    escaped
}

fn json_array(values: &[String]) -> String {
    format!(
        "[{}]",
        values
            .iter()
            .map(|value| json_string(value))
            .collect::<Vec<_>>()
            .join(",")
    )
}

fn json_optional(value: &Option<String>) -> String {
    value
        .as_deref()
        .map(json_string)
        .unwrap_or_else(|| "null".to_owned())
}

fn invalid(path: &str, error: &str) -> String {
    format!(
        "{{\"path\":{},\"valid\":false,\"errors\":[{}]}}",
        json_string(path),
        json_string(error)
    )
}

fn split_path(value: String) -> Vec<String> {
    value.split(':').map(ToOwned::to_owned).collect()
}

fn decode_type(value: u16) -> String {
    match value {
        2 => "EXEC".to_owned(),
        3 => "DYN".to_owned(),
        other => format!("0x{other:x}"),
    }
}

fn parse_notes(data: &[u8], segment: &[u8], parsed: &mut Parsed) -> Result<(), String> {
    let mut offset = 0usize;
    while offset < segment.len() {
        let namesz = read_u32(segment, offset)? as usize;
        let descsz = read_u32(segment, offset + 4)? as usize;
        let note_type = read_u32(segment, offset + 8)?;
        let name_start = offset.checked_add(12).ok_or("ELF note offset overflows")?;
        let name_end = name_start
            .checked_add(namesz)
            .ok_or("ELF note name overflows")?;
        let desc_start = align4(name_end)?;
        let desc_end = desc_start
            .checked_add(descsz)
            .ok_or("ELF note payload overflows")?;
        let name = segment
            .get(name_start..name_end)
            .ok_or("truncated ELF note name")?;
        let desc = segment
            .get(desc_start..desc_end)
            .ok_or("truncated ELF note payload")?;
        if name.strip_suffix(&[0]).unwrap_or(name) == b"GNU" {
            if note_type == 3 {
                parsed.build_id = Some(desc.iter().map(|byte| format!("{byte:02x}")).collect());
            } else if note_type == 1 && desc.len() >= 16 {
                let os = read_u32(desc, 0)?;
                let major = read_u32(desc, 4)?;
                let minor = read_u32(desc, 8)?;
                let subminor = read_u32(desc, 12)?;
                let os_name = match os {
                    0 => "Linux",
                    1 => "GNU",
                    2 => "Solaris",
                    3 => "FreeBSD",
                    _ => "unknown",
                };
                parsed.abi = Some(format!("OS: {os_name}, ABI: {major}.{minor}.{subminor}"));
            }
        }
        offset = align4(desc_end)?;
    }
    let _ = data;
    Ok(())
}

fn parse_versions(
    data: &[u8],
    section_offset: u64,
    section_size: u64,
    dynstr: &[u8],
) -> Result<Vec<String>, String> {
    let section = range(data, section_offset, section_size)?;
    let mut offset = 0usize;
    let mut result = Vec::new();
    while offset < section.len() {
        if section.len() - offset < 16 {
            return Err("truncated GNU version-need entry".to_owned());
        }
        let count = read_u16(section, offset + 2)? as usize;
        let aux_offset = read_u32(section, offset + 8)? as usize;
        let next = read_u32(section, offset + 12)? as usize;
        let mut aux = offset
            .checked_add(aux_offset)
            .ok_or("GNU version-need offset overflows")?;
        for _ in 0..count {
            if section.len().saturating_sub(aux) < 16 {
                return Err("truncated GNU version auxiliary entry".to_owned());
            }
            let name = read_u32(section, aux + 8)? as u64;
            let value = c_string(dynstr, name)?;
            if matches!(value.as_str(), v if v.starts_with("GLIBC_") || v.starts_with("GLIBCXX_") || v.starts_with("CXXABI_") || v.starts_with("GCC_") || v.starts_with("GLIBC_ABI_"))
            {
                result.push(value);
            }
            let aux_next = read_u32(section, aux + 12)? as usize;
            if aux_next == 0 {
                break;
            }
            aux = aux
                .checked_add(aux_next)
                .ok_or("GNU version auxiliary offset overflows")?;
        }
        if next == 0 {
            break;
        }
        offset = offset
            .checked_add(next)
            .ok_or("GNU version-need chain overflows")?;
    }
    result.sort();
    result.dedup();
    Ok(result)
}

fn parse(data: &[u8]) -> Result<Parsed, String> {
    if data.len() < 64 || &data[..4] != b"\x7fELF" {
        return Err("not a readable ELF file".to_owned());
    }
    if data[4] != 2 {
        return Err("unsupported ELF class".to_owned());
    }
    if data[5] != 1 {
        return Err("unsupported ELF data encoding".to_owned());
    }
    let phoff = read_u64(data, 32)?;
    let shoff = read_u64(data, 40)?;
    let phentsize = read_u16(data, 54)? as usize;
    let phnum = read_u16(data, 56)? as usize;
    let shentsize = read_u16(data, 58)? as usize;
    let shnum = read_u16(data, 60)? as usize;
    if phentsize < 56 || (phnum > 0 && range(data, phoff, (phentsize * phnum) as u64).is_err()) {
        return Err("invalid program-header table".to_owned());
    }
    if shnum > 0 && (shentsize < 64 || range(data, shoff, (shentsize * shnum) as u64).is_err()) {
        return Err("invalid section-header table".to_owned());
    }
    let mut parsed = Parsed {
        class: "ELF64".to_owned(),
        data: "2's complement, little endian".to_owned(),
        elf_type: decode_type(read_u16(data, 16)?),
        machine: if read_u16(data, 18)? == 183 {
            "AArch64".to_owned()
        } else {
            format!("0x{:x}", read_u16(data, 18)?)
        },
        ..Parsed::default()
    };
    let mut dynamic_segment = None;
    let mut dynstr_segment = None;
    for index in 0..phnum {
        let entry = range(data, phoff + (index * phentsize) as u64, phentsize as u64)?;
        let kind = read_u32(entry, 0)?;
        let flags = read_u32(entry, 4)?;
        let offset = read_u64(entry, 8)?;
        let size = read_u64(entry, 32)?;
        match kind {
            1 if flags & 2 != 0 && flags & 1 != 0 => parsed.wx_load = true,
            2 => {
                parsed.has_dynamic = true;
                dynamic_segment = Some((offset, size));
            }
            3 => {
                let value = range(data, offset, size)?;
                parsed.interpreter_count += 1;
                if parsed.interpreter.is_none() {
                    parsed.interpreter = Some(
                        String::from_utf8_lossy(value)
                            .trim_end_matches('\0')
                            .to_owned(),
                    );
                }
            }
            4 => parse_notes(data, range(data, offset, size)?, &mut parsed)?,
            0x6474_e551 => {
                let mut text = String::new();
                if flags & 4 != 0 {
                    text.push('R');
                }
                if flags & 2 != 0 {
                    text.push('W');
                }
                if flags & 1 != 0 {
                    text.push('E');
                }
                parsed.gnu_stack_flags = (!text.is_empty()).then_some(text);
            }
            _ => {}
        }
    }
    let mut sections = Vec::with_capacity(shnum);
    let mut dynamic_string_index = None;
    let mut version_section = None;
    for index in 0..shnum {
        let entry = range(data, shoff + (index * shentsize) as u64, shentsize as u64)?;
        let kind = read_u32(entry, 4)?;
        let offset = read_u64(entry, 24)?;
        let size = read_u64(entry, 32)?;
        let link = read_u32(entry, 40)? as usize;
        sections.push((offset, size));
        if kind == 6 {
            dynamic_string_index = Some(link);
        }
        if kind == 0x6fff_fffe {
            version_section = Some((offset, size, link));
        }
    }
    if let Some(index) = dynamic_string_index {
        dynstr_segment = sections.get(index).copied();
    }
    if let Some((offset, size)) = dynamic_segment {
        let dynamic = range(data, offset, size)?;
        if dynamic.len() % 16 != 0 {
            return Err("truncated dynamic section".to_owned());
        }
        let dynstr = dynstr_segment
            .map(|(offset, size)| range(data, offset, size))
            .transpose()?;
        for entry in dynamic.chunks_exact(16) {
            let tag = read_u64(entry, 0)? as i64;
            let value = read_u64(entry, 8)?;
            match tag {
                0 => break,
                1 => {
                    if let Some(table) = dynstr {
                        parsed.needed.push(c_string(table, value)?);
                    }
                }
                14 => {
                    if let Some(table) = dynstr {
                        parsed.soname = Some(c_string(table, value)?);
                    }
                }
                15 => {
                    if let Some(table) = dynstr {
                        parsed.rpath = split_path(c_string(table, value)?);
                    }
                }
                29 => {
                    if let Some(table) = dynstr {
                        parsed.runpath = split_path(c_string(table, value)?);
                    }
                }
                22 => parsed.text_relocations = true,
                30 | 0x6fff_fffb => parsed.flags.push(format!("DT_FLAGS: 0x{value:x}")),
                0x6fff_fefc | 0x6fff_fefd | 0x7fff_fffd | 0x7fff_ffff => parsed
                    .audit_tags
                    .push(format!("dynamic tag 0x{tag:x}: 0x{value:x}")),
                _ => {}
            }
        }
        if let (Some((offset, size, _)), Some(table)) = (version_section, dynstr) {
            parsed.versions = parse_versions(data, offset, size, table)?;
        }
    }
    Ok(parsed)
}

fn inspect_json(path: &str, mode: Mode, parsed: Parsed) -> String {
    let mut errors = Vec::new();
    let mut warnings = Vec::new();
    let mut valid = true;
    if parsed.class != "ELF64" {
        errors.push(format!("unsupported ELF class: {}", parsed.class));
        valid = false;
    }
    if !parsed.data.contains("little endian") {
        errors.push(format!("unsupported ELF data encoding: {}", parsed.data));
        valid = false;
    }
    if parsed.machine != "AArch64" {
        errors.push(format!("unsupported ELF machine: {}", parsed.machine));
        valid = false;
    }
    if parsed.elf_type != "DYN" && parsed.elf_type != "EXEC" {
        errors.push(format!("unsupported ELF type: {}", parsed.elf_type));
        valid = false;
    }
    if !parsed.has_dynamic {
        errors.push("target has no PT_DYNAMIC segment".to_owned());
        valid = false;
    }
    match mode {
        Mode::Target => match parsed.interpreter_count {
            1 => {
                if !matches!(
                    parsed
                        .interpreter
                        .as_deref()
                        .and_then(|value| Path::new(value).file_name())
                        .and_then(|name| name.to_str()),
                    Some("ld-linux-aarch64.so.1" | "ld.so")
                ) {
                    errors.push(format!(
                        "unsupported dynamic interpreter: {}",
                        parsed.interpreter.as_deref().unwrap_or("")
                    ));
                    valid = false;
                }
            }
            count => {
                errors.push(format!(
                    "target must contain exactly one PT_INTERP entry (found {count})"
                ));
                valid = false;
            }
        },
        Mode::Dso if parsed.elf_type != "DYN" => {
            errors.push("shared library must have ELF type DYN".to_owned());
            valid = false;
        }
        Mode::Dso => {}
    }
    if parsed.needed.iter().any(|value| value.contains('/')) {
        errors.push("DT_NEEDED entry contains a path".to_owned());
        valid = false;
    }
    if parsed.needed.iter().any(|value| value == "libc.so")
        || parsed.soname.as_deref() == Some("libc.so")
    {
        errors.push("target links Android/Bionic libc.so instead of glibc libc.so.6".to_owned());
        valid = false;
    }
    for entry in parsed.rpath.iter().chain(parsed.runpath.iter()) {
        if entry.is_empty() {
            errors.push("RPATH/RUNPATH contains an empty current-directory entry".to_owned());
            valid = false;
        } else if entry.starts_with('/') || entry == "$ORIGIN" || entry == "${ORIGIN}" {
        } else if entry.starts_with("$ORIGIN/") || entry.starts_with("${ORIGIN}/") {
            if entry.contains("/../") || entry.ends_with("/..") {
                errors.push(format!(
                    "ORIGIN RPATH/RUNPATH escapes the declaring object directory: {entry}"
                ));
                valid = false;
            }
        } else {
            errors.push(format!(
                "relative or unsupported RPATH/RUNPATH entry: {entry}"
            ));
            valid = false;
        }
    }
    if parsed.wx_load {
        warnings.push("target contains a writable-executable PT_LOAD segment".to_owned());
    }
    if parsed
        .gnu_stack_flags
        .as_deref()
        .is_some_and(|flags| flags.contains('E'))
    {
        warnings.push("target requests an executable GNU stack".to_owned());
    }
    if parsed.text_relocations {
        warnings.push("target declares text relocations".to_owned());
    }
    if !parsed.audit_tags.is_empty() {
        warnings.push("target declares dynamic audit or filter tags".to_owned());
    }
    format!(
        "{{\"path\":{},\"inspection_mode\":{},\"valid\":{},\"errors\":{},\"warnings\":{},\"header\":{{\"class\":{},\"data\":{},\"type\":{},\"machine\":{}}},\"program_headers\":{{\"interpreter\":{},\"interpreter_count\":{},\"has_dynamic\":{},\"gnu_stack_flags\":{},\"writable_executable_load\":{}}},\"dynamic\":{{\"needed\":{},\"soname\":{},\"rpath\":{},\"runpath\":{},\"flags\":{},\"audit_filter_tags\":{},\"text_relocations\":{}}},\"notes\":{{\"build_id\":{},\"abi\":{},\"gnu_properties\":[]}},\"version_requirements\":{}}}",
        json_string(path),
        json_string(mode.as_str()),
        valid,
        json_array(&errors),
        json_array(&warnings),
        json_string(&parsed.class),
        json_string(&parsed.data),
        json_string(&parsed.elf_type),
        json_string(&parsed.machine),
        json_optional(&parsed.interpreter),
        parsed.interpreter_count,
        parsed.has_dynamic,
        json_optional(&parsed.gnu_stack_flags),
        parsed.wx_load,
        json_array(&parsed.needed),
        json_optional(&parsed.soname),
        json_array(&parsed.rpath),
        json_array(&parsed.runpath),
        json_array(&parsed.flags),
        json_array(&parsed.audit_tags),
        parsed.text_relocations,
        json_optional(&parsed.build_id),
        json_optional(&parsed.abi),
        json_array(&parsed.versions)
    )
}

pub fn inspect(path: &str, mode: Mode) -> String {
    let resolved = match fs::canonicalize(path) {
        Ok(value) => value,
        Err(_) => return invalid(path, "not a readable ELF file"),
    };
    let display = resolved.to_string_lossy().into_owned();
    let bytes = match fs::read(&resolved) {
        Ok(value) => value,
        Err(_) => return invalid(&display, "not a readable ELF file"),
    };
    match parse(&bytes) {
        Ok(parsed) => inspect_json(&display, mode, parsed),
        Err(error) => invalid(&display, &error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_non_elf_input() {
        assert_eq!(parse(b"not an elf").unwrap_err(), "not a readable ELF file");
    }

    #[test]
    fn escapes_json_strings() {
        assert_eq!(json_string("quote\" newline\n"), "\"quote\\\" newline\\n\"");
    }
}
