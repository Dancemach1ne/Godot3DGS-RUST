//! Persistent CPU-side position cache and back-to-front sorter for Raster.

use godot::prelude::*;

#[derive(GodotClass)]
#[class(init, base = RefCounted)]
pub struct GdgsSortState {
    base: Base<RefCounted>,
    positions: Vec<[f32; 3]>,
}

#[godot_api]
impl GdgsSortState {
    /// Copies positions once when a GaussianResource is assigned. Subsequent
    /// sorts receive only a camera direction.
    #[func]
    fn set_positions(&mut self, positions: PackedVector3Array) {
        self.positions = positions
            .as_slice()
            .iter()
            .map(|point| [point.x, point.y, point.z])
            .collect();
    }

    #[func]
    fn point_count(&self) -> i64 {
        self.positions.len() as i64
    }

    /// Stable far-to-near order for ordinary alpha blending.
    #[func]
    fn sort_back_to_front(&self, view_direction_local: Vector3) -> PackedFloat32Array {
        let mut indices: Vec<usize> = (0..self.positions.len()).collect();
        indices.sort_by(|&left, &right| {
            let a = dot(self.positions[left], view_direction_local);
            let b = dot(self.positions[right], view_direction_local);
            b.total_cmp(&a)
        });
        PackedFloat32Array::from(indices.into_iter().map(|index| index as f32).collect::<Vec<_>>())
    }
}

fn dot(position: [f32; 3], direction: Vector3) -> f32 {
    position[0] * direction.x + position[1] * direction.y + position[2] * direction.z
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ordering_math_is_far_to_near() {
        let direction = Vector3::new(0.0, 0.0, -1.0);
        // A more negative Z is farther along the camera forward direction.
        assert!(dot([0.0, 0.0, -5.0], direction) > dot([0.0, 0.0, -1.0], direction));
    }
}
