//! Decoder for the standard binary-little-endian 3D Gaussian Splatting PLY.
//!
//! This intentionally covers one format in Milestone 2. Compressed PLY,
//! `.splat`, and `.sog` will be independent later decoders.

use std::collections::HashMap;
use std::fs;

use crate::splat::{BYTES_PER_SPLAT, SH_FLOATS_PER_SPLAT, SplatRecord};

#[derive(Debug)]
struct Property {
    offset: usize,
    kind: ScalarKind,
}

#[derive(Clone, Copy, Debug)]
enum ScalarKind {
    I8,
    U8,
    I16,
    U16,
    I32,
    U32,
    F32,
    F64,
}

impl ScalarKind {
    fn parse(name: &str) -> Option<Self> {
        match name {
            "char" | "int8" => Some(Self::I8),
            "uchar" | "uint8" => Some(Self::U8),
            "short" | "int16" => Some(Self::I16),
            "ushort" | "uint16" => Some(Self::U16),
            "int" | "int32" => Some(Self::I32),
            "uint" | "uint32" => Some(Self::U32),
            "float" | "float32" => Some(Self::F32),
            "double" | "float64" => Some(Self::F64),
            _ => None,
        }
    }

    fn size(self) -> usize {
        match self {
            Self::I8 | Self::U8 => 1,
            Self::I16 | Self::U16 => 2,
            Self::I32 | Self::U32 | Self::F32 => 4,
            Self::F64 => 8,
        }
    }

    fn read(self, bytes: &[u8]) -> Result<f32, String> {
        let exact = |n| -> Result<&[u8], String> {
            bytes
                .get(..n)
                .ok_or_else(|| "PLY record ends in the middle of a property".to_owned())
        };
        Ok(match self {
            Self::I8 => exact(1)?[0] as i8 as f32,
            Self::U8 => exact(1)?[0] as f32,
            Self::I16 => i16::from_le_bytes(exact(2)?.try_into().unwrap()) as f32,
            Self::U16 => u16::from_le_bytes(exact(2)?.try_into().unwrap()) as f32,
            Self::I32 => i32::from_le_bytes(exact(4)?.try_into().unwrap()) as f32,
            Self::U32 => u32::from_le_bytes(exact(4)?.try_into().unwrap()) as f32,
            Self::F32 => f32::from_le_bytes(exact(4)?.try_into().unwrap()),
            Self::F64 => f64::from_le_bytes(exact(8)?.try_into().unwrap()) as f32,
        })
    }
}

#[derive(Debug)]
struct Element {
    name: String,
    count: usize,
    stride: usize,
    properties: HashMap<String, Property>,
}

/// GPU-ready output plus positions retained for Godot-side resource metadata.
#[derive(Debug)]
pub struct DecodedPly {
    pub point_count: usize,
    pub point_data: Vec<u8>,
    pub positions: Vec<[f32; 3]>,
}

pub fn decode_standard_ply_file(path: &str) -> Result<DecodedPly, String> {
    let bytes = fs::read(path).map_err(|error| format!("cannot read PLY '{path}': {error}"))?;
    decode_standard_ply(&bytes)
}

pub fn decode_standard_ply(bytes: &[u8]) -> Result<DecodedPly, String> {
    let (elements, data_offset) = parse_header(bytes)?;
    let mut cursor = data_offset;
    let mut vertex_data = None;

    for element in elements {
        let byte_len = element
            .count
            .checked_mul(element.stride)
            .ok_or_else(|| "PLY element byte size overflows usize".to_owned())?;
        let data = bytes
            .get(cursor..cursor + byte_len)
            .ok_or_else(|| format!("PLY data ends before element '{}'", element.name))?;
        if element.name == "vertex" {
            vertex_data = Some((element, data));
        }
        cursor += byte_len;
    }

    let (vertex, data) = vertex_data.ok_or_else(|| "PLY has no vertex element".to_owned())?;
    for required in [
        "x", "y", "z", "f_dc_0", "f_dc_1", "f_dc_2", "opacity", "scale_0", "scale_1", "rot_0",
        "rot_1", "rot_2", "rot_3",
    ] {
        if !vertex.properties.contains_key(required) {
            return Err(format!(
                "PLY vertex element is missing required property '{required}'"
            ));
        }
    }

    let mut raw_positions = Vec::with_capacity(vertex.count);
    let mut records = Vec::with_capacity(vertex.count);
    for index in 0..vertex.count {
        let record = &data[index * vertex.stride..(index + 1) * vertex.stride];
        let position = [
            property_f32(record, &vertex.properties, "x", 0.0)?,
            property_f32(record, &vertex.properties, "y", 0.0)?,
            property_f32(record, &vertex.properties, "z", 0.0)?,
        ];
        let scales = [
            property_f32(record, &vertex.properties, "scale_0", 0.0)?.exp(),
            property_f32(record, &vertex.properties, "scale_1", 0.0)?.exp(),
            property_f32(record, &vertex.properties, "scale_2", (1e-6_f32).ln())?.exp(),
        ];
        // Standard 3DGS PLY stores W first; Godot's Quaternion constructor is XYZW.
        let rotation = normalize_quaternion([
            property_f32(record, &vertex.properties, "rot_1", 0.0)?,
            property_f32(record, &vertex.properties, "rot_2", 0.0)?,
            property_f32(record, &vertex.properties, "rot_3", 0.0)?,
            property_f32(record, &vertex.properties, "rot_0", 1.0)?,
        ]);
        let opacity = sigmoid(property_f32(record, &vertex.properties, "opacity", 0.0)?);
        let mut sh = [0.0; SH_FLOATS_PER_SPLAT];
        sh[0] = property_f32(record, &vertex.properties, "f_dc_0", 0.0)?;
        sh[1] = property_f32(record, &vertex.properties, "f_dc_1", 0.0)?;
        sh[2] = property_f32(record, &vertex.properties, "f_dc_2", 0.0)?;
        for coeff in 0..15 {
            let dst = 3 + coeff * 3;
            sh[dst] = property_f32(record, &vertex.properties, &format!("f_rest_{coeff}"), 0.0)?;
            sh[dst + 1] = property_f32(
                record,
                &vertex.properties,
                &format!("f_rest_{}", coeff + 15),
                0.0,
            )?;
            sh[dst + 2] = property_f32(
                record,
                &vertex.properties,
                &format!("f_rest_{}", coeff + 30),
                0.0,
            )?;
        }
        raw_positions.push(position);
        records.push((scales, rotation, opacity, sh));
    }

    let center = centroid(&raw_positions);
    let mut point_data = Vec::with_capacity(vertex.count * BYTES_PER_SPLAT);
    let mut positions = Vec::with_capacity(vertex.count);
    for (index, (scales, rotation, opacity, sh)) in records.into_iter().enumerate() {
        let position = subtract(raw_positions[index], center);
        let splat =
            SplatRecord::from_components(position, covariance(scales, rotation), opacity, sh);
        point_data.extend_from_slice(&splat.to_le_bytes());
        positions.push(position);
    }
    Ok(DecodedPly {
        point_count: vertex.count,
        point_data,
        positions,
    })
}

fn parse_header(bytes: &[u8]) -> Result<(Vec<Element>, usize), String> {
    let mut offset = 0;
    let first = next_line(bytes, &mut offset).ok_or_else(|| "PLY is empty".to_owned())?;
    if first.trim() != "ply" {
        return Err("PLY magic header is missing".to_owned());
    }
    let mut format_ok = false;
    let mut elements = Vec::new();
    while let Some(line) = next_line(bytes, &mut offset) {
        let parts: Vec<_> = line.split_ascii_whitespace().collect();
        if parts.is_empty() || matches!(parts[0], "comment" | "obj_info") {
            continue;
        }
        if parts[0] == "end_header" {
            break;
        }
        match parts.as_slice() {
            ["format", "binary_little_endian", _] => format_ok = true,
            ["format", format, _] => {
                return Err(format!(
                    "only binary_little_endian PLY is supported, found '{format}'"
                ));
            }
            ["element", name, count] => elements.push(Element {
                name: (*name).to_owned(),
                count: count
                    .parse()
                    .map_err(|_| format!("invalid element count '{count}'"))?,
                stride: 0,
                properties: HashMap::new(),
            }),
            ["property", "list", ..] => {
                return Err("PLY list properties are unsupported".to_owned());
            }
            ["property", kind, name] => {
                let kind = ScalarKind::parse(kind)
                    .ok_or_else(|| format!("unsupported PLY property type '{kind}'"))?;
                let element = elements
                    .last_mut()
                    .ok_or_else(|| "PLY property appears before an element".to_owned())?;
                let property = Property {
                    offset: element.stride,
                    kind,
                };
                element.stride += kind.size();
                element.properties.insert((*name).to_owned(), property);
            }
            _ => return Err(format!("unsupported PLY header line '{line}'")),
        }
    }
    if !format_ok {
        return Err("PLY format must be binary_little_endian".to_owned());
    }
    if elements.is_empty() {
        return Err("PLY contains no elements".to_owned());
    }
    Ok((elements, offset))
}

fn next_line<'a>(bytes: &'a [u8], offset: &mut usize) -> Option<&'a str> {
    if *offset >= bytes.len() {
        return None;
    }
    let start = *offset;
    while *offset < bytes.len() && bytes[*offset] != b'\n' {
        *offset += 1;
    }
    let end = *offset;
    if *offset < bytes.len() {
        *offset += 1;
    }
    std::str::from_utf8(&bytes[start..end])
        .ok()
        .map(|line| line.trim_end_matches('\r'))
}

fn property_f32(
    record: &[u8],
    properties: &HashMap<String, Property>,
    name: &str,
    default: f32,
) -> Result<f32, String> {
    let Some(property) = properties.get(name) else {
        return Ok(default);
    };
    property.kind.read(
        record
            .get(property.offset..)
            .ok_or_else(|| format!("property '{name}' offset is invalid"))?,
    )
}

fn sigmoid(value: f32) -> f32 {
    1.0 / (1.0 + (-value).exp())
}

fn centroid(points: &[[f32; 3]]) -> [f32; 3] {
    if points.is_empty() {
        return [0.0; 3];
    }
    let sum = points.iter().fold([0.0; 3], |mut total, point| {
        total[0] += point[0];
        total[1] += point[1];
        total[2] += point[2];
        total
    });
    [
        sum[0] / points.len() as f32,
        sum[1] / points.len() as f32,
        sum[2] / points.len() as f32,
    ]
}

fn subtract(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

fn normalize_quaternion([x, y, z, w]: [f32; 4]) -> [f32; 4] {
    let length = (x * x + y * y + z * z + w * w).sqrt();
    if length.is_finite() && length > 0.0 {
        [x / length, y / length, z / length, w / length]
    } else {
        [0.0, 0.0, 0.0, 1.0]
    }
}

/// Upper triangle `[xx, xy, xz, yy, yz, zz]` of `R * diag(scale²) * Rᵀ`.
fn covariance(scale: [f32; 3], [x, y, z, w]: [f32; 4]) -> [f32; 6] {
    let r = [
        [
            1.0 - 2.0 * (y * y + z * z),
            2.0 * (x * y - z * w),
            2.0 * (x * z + y * w),
        ],
        [
            2.0 * (x * y + z * w),
            1.0 - 2.0 * (x * x + z * z),
            2.0 * (y * z - x * w),
        ],
        [
            2.0 * (x * z - y * w),
            2.0 * (y * z + x * w),
            1.0 - 2.0 * (x * x + y * y),
        ],
    ];
    let s = [
        scale[0].max(1e-6).powi(2),
        scale[1].max(1e-6).powi(2),
        scale[2].max(1e-6).powi(2),
    ];
    let entry = |row: usize, col: usize| {
        (0..3)
            .map(|axis| r[row][axis] * s[axis] * r[col][axis])
            .sum::<f32>()
    };
    [
        entry(0, 0),
        entry(0, 1),
        entry(0, 2),
        entry(1, 1),
        entry(1, 2),
        entry(2, 2),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> Vec<u8> {
        let mut bytes = b"ply\nformat binary_little_endian 1.0\nelement vertex 2\nproperty float x\nproperty float y\nproperty float z\nproperty float f_dc_0\nproperty float f_dc_1\nproperty float f_dc_2\nproperty float opacity\nproperty float scale_0\nproperty float scale_1\nproperty float scale_2\nproperty float rot_0\nproperty float rot_1\nproperty float rot_2\nproperty float rot_3\nend_header\n".to_vec();
        for values in [
            [
                1.0_f32, 2.0, 3.0, 0.1, 0.2, 0.3, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0,
            ],
            [
                3.0, 4.0, 5.0, 0.4, 0.5, 0.6, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0,
            ],
        ] {
            for value in values {
                bytes.extend_from_slice(&value.to_le_bytes());
            }
        }
        bytes
    }

    #[test]
    fn decodes_and_centers_a_standard_ply() {
        let decoded = decode_standard_ply(&fixture()).unwrap();
        assert_eq!(decoded.point_count, 2);
        assert_eq!(decoded.point_data.len(), 2 * BYTES_PER_SPLAT);
        assert_eq!(decoded.positions, vec![[-1.0, -1.0, -1.0], [1.0, 1.0, 1.0]]);
        let first = SplatRecord::from_le_bytes(&decoded.point_data[..BYTES_PER_SPLAT]).unwrap();
        assert_eq!(first.position(), [-1.0, -1.0, -1.0]);
        assert!((first.opacity() - 0.5).abs() < 1e-6);
    }

    #[test]
    fn rejects_ascii_ply() {
        assert!(decode_standard_ply(b"ply\nformat ascii 1.0\n").is_err());
    }
}
