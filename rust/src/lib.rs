use godot::prelude::*;

mod splat;
mod ply;
mod sort;

struct Godot3DgsExtension;

#[gdextension]
unsafe impl ExtensionLibrary for Godot3DgsExtension {}

/// Small native service used as the first GDExtension smoke test.
///
/// Later phases will add binary decoders, cached sort state and bake jobs here.
#[derive(GodotClass)]
#[class(init, base = RefCounted)]
struct GdgsNative {
    base: Base<RefCounted>,
}

#[godot_api]
impl GdgsNative {
    #[func]
    fn get_build_info(&self) -> GString {
        "Rust GDExtension loaded successfully".into()
    }

    #[func]
    fn sum_i64(&self, left: i64, right: i64) -> i64 {
        left + right
    }

    /// Returns the fixed number of float32 values stored for one splat.
    #[func]
    fn splat_floats_per_record(&self) -> i64 {
        splat::FLOATS_PER_SPLAT as i64
    }

    /// Returns the fixed byte size of one GPU-ready splat record.
    #[func]
    fn splat_bytes_per_record(&self) -> i64 {
        splat::BYTES_PER_SPLAT as i64
    }

    /// Creates one deterministic record entirely in Rust and reports its
    /// decoded position. This is a bridge smoke test for Milestone 1.
    #[func]
    fn test_splat_summary(&self) -> GString {
        let record = splat::SplatRecord::from_components(
            [1.0, 2.0, 3.0],
            [1.0, 0.0, 0.0, 1.0, 0.0, 1.0],
            0.75,
            [0.0; splat::SH_FLOATS_PER_SPLAT],
        );
        let bytes = record.to_le_bytes();
        let decoded = splat::SplatRecord::from_le_bytes(&bytes)
            .expect("a record serialized by SplatRecord must decode");
        let summary = format!(
            "SplatRecord: {} floats, {} bytes, position=({}, {}, {}), opacity={}",
            splat::FLOATS_PER_SPLAT,
            splat::BYTES_PER_SPLAT,
            decoded.position()[0],
            decoded.position()[1],
            decoded.position()[2],
            decoded.opacity(),
        );
        (&summary).into()
    }

    /// Decodes a standard binary-little-endian 3DGS PLY into the shared GPU
    /// record layout. The GDScript importer owns resource creation and saving.
    #[func]
    fn decode_standard_ply(&self, absolute_path: GString) -> VarDictionary {
        match ply::decode_standard_ply_file(&absolute_path.to_string()) {
            Ok(decoded) => {
                let mut result = VarDictionary::new();
                result.set("ok", true);
                result.set("point_count", decoded.point_count as i64);
                result.set("point_data", PackedByteArray::from(decoded.point_data));
                result.set(
                    "positions",
                    PackedVector3Array::from(
                        decoded.positions.into_iter().map(|position| Vector3::new(position[0], position[1], position[2])).collect::<Vec<_>>(),
                    ),
                );
                result
            }
            Err(message) => {
                let mut result = VarDictionary::new();
                result.set("ok", false);
                result.set("message", message);
                result
            }
        }
    }
}
