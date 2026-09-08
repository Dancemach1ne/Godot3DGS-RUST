//! The shared, GPU-ready 3D Gaussian Splatting record contract.
//!
//! The field order deliberately matches the reference Godot plugin's
//! `GaussianResourceBuilder`: position/padding, symmetric 3D covariance,
//! opacity/padding, then 48 degree-3 spherical-harmonics coefficients.

/// Number of f32 values in one GPU record.
pub const FLOATS_PER_SPLAT: usize = 60;
/// Number of bytes in one GPU record.
pub const BYTES_PER_SPLAT: usize = FLOATS_PER_SPLAT * std::mem::size_of::<f32>();
pub const SH_FLOATS_PER_SPLAT: usize = 48;

const POSITION_OFFSET: usize = 0;
const COVARIANCE_OFFSET: usize = 4;
const OPACITY_OFFSET: usize = 10;
const SH_OFFSET: usize = 12;

/// A fixed-layout splat record, represented as f32 values so it can be
/// converted to Godot PackedByteArray data without changing its GPU layout.
#[derive(Clone, Debug, PartialEq)]
pub struct SplatRecord {
    values: [f32; FLOATS_PER_SPLAT],
}

impl SplatRecord {
    pub fn from_components(
        position: [f32; 3],
        covariance_upper_triangle: [f32; 6],
        opacity: f32,
        sh_coefficients: [f32; SH_FLOATS_PER_SPLAT],
    ) -> Self {
        let mut values = [0.0; FLOATS_PER_SPLAT];
        values[POSITION_OFFSET..POSITION_OFFSET + 3].copy_from_slice(&position);
        values[COVARIANCE_OFFSET..COVARIANCE_OFFSET + 6]
            .copy_from_slice(&covariance_upper_triangle);
        values[OPACITY_OFFSET] = opacity.clamp(0.0, 1.0);
        values[SH_OFFSET..SH_OFFSET + SH_FLOATS_PER_SPLAT].copy_from_slice(&sh_coefficients);
        Self { values }
    }

    pub fn position(&self) -> [f32; 3] {
        self.values[POSITION_OFFSET..POSITION_OFFSET + 3]
            .try_into()
            .expect("position layout is fixed")
    }

    pub fn opacity(&self) -> f32 {
        self.values[OPACITY_OFFSET]
    }

    pub fn to_le_bytes(&self) -> [u8; BYTES_PER_SPLAT] {
        let mut bytes = [0_u8; BYTES_PER_SPLAT];
        for (index, value) in self.values.iter().enumerate() {
            let start = index * std::mem::size_of::<f32>();
            bytes[start..start + 4].copy_from_slice(&value.to_le_bytes());
        }
        bytes
    }

    pub fn from_le_bytes(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() != BYTES_PER_SPLAT {
            return Err(format!(
                "expected {BYTES_PER_SPLAT} bytes for one splat, received {}",
                bytes.len()
            ));
        }
        let mut values = [0.0; FLOATS_PER_SPLAT];
        for (index, value) in values.iter_mut().enumerate() {
            let start = index * std::mem::size_of::<f32>();
            *value = f32::from_le_bytes(
                bytes[start..start + 4]
                    .try_into()
                    .expect("slice is exactly four bytes"),
            );
        }
        Ok(Self { values })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_has_the_reference_layout_size() {
        assert_eq!(FLOATS_PER_SPLAT, 60);
        assert_eq!(BYTES_PER_SPLAT, 240);
    }

    #[test]
    fn round_trip_preserves_position_and_opacity() {
        let record = SplatRecord::from_components(
            [1.0, -2.0, 3.5],
            [1.0, 0.1, 0.2, 2.0, 0.3, 3.0],
            1.5,
            [0.25; SH_FLOATS_PER_SPLAT],
        );
        let decoded = SplatRecord::from_le_bytes(&record.to_le_bytes()).unwrap();
        assert_eq!(decoded.position(), [1.0, -2.0, 3.5]);
        assert_eq!(decoded.opacity(), 1.0);
        assert_eq!(decoded, record);
    }

    #[test]
    fn decoder_rejects_the_wrong_size() {
        assert!(SplatRecord::from_le_bytes(&[0_u8; BYTES_PER_SPLAT - 1]).is_err());
    }
}
