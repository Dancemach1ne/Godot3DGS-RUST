//! CPU collision baking for Gaussian splats.
//!
//! This mirrors the reference project's object-collision path: validate and
//! regularize covariance matrices, accumulate Gaussian density into a voxel
//! grid, remove isolated noise, then greedily mesh the exposed voxel surface.

use crate::splat::{BYTES_PER_SPLAT, FLOATS_PER_SPLAT};

const MAX_SPLATS: usize = 2_000_000;
const HARD_MAX_SPLATS: usize = 20_000_000;
const AUTO_VOXELS_ON_LONGEST_AXIS: f32 = 128.0;
const MIN_VOXEL_SIZE: f32 = 0.01;
const MAX_VOXEL_SIZE: f32 = 0.5;
const MAX_GRID_AXIS: usize = 4096;
const MAX_GRID_VOXELS: usize = 16_777_216;
const MAX_VOXEL_EVALUATIONS: u64 = 64_000_000;
const MAX_QUADS: usize = 2_000_000;
const MAX_SIGMA: f32 = 7.0;
const REGULARIZATION_RELATIVE: f32 = 1.0e-6;
const REGULARIZATION_ABSOLUTE: f32 = 1.0e-12;
const ROBUST_BOUNDS_MIN_SPLATS: usize = 1_000;
const ROBUST_BOUNDS_MAX_SAMPLES: usize = 65_536;
const ROBUST_BOUNDS_QUANTILE: f32 = 0.001;
const ROBUST_BOUNDS_PADDING: f32 = 0.25;
const OUTLIER_SPAN_RATIO: f32 = 8.0;

#[derive(Clone, Copy)]
struct PreparedSplat {
    position: [f32; 3],
    inverse: [f32; 6],
    extent: [f32; 3],
    opacity: f32,
}

#[derive(Debug)]
pub struct CollisionStats {
    pub input_splats: usize,
    pub sample_stride: usize,
    pub valid_splats: usize,
    pub skipped_splats: usize,
    pub position_outliers: usize,
    pub voxel_size: f32,
    pub grid_dimensions: [usize; 3],
    pub occupied_voxels: usize,
    pub removed_voxels: usize,
    pub quads: usize,
    pub triangles: usize,
}

#[derive(Debug)]
pub struct CollisionOutput {
    /// Three consecutive positions form one triangle, ready for
    /// ConcavePolygonShape3D.set_faces().
    pub faces: Vec<[f32; 3]>,
    pub stats: CollisionStats,
}

pub fn generate_collision(
    point_data: &[u8],
    point_count: i64,
    requested_voxel_size: f32,
    opacity_cutoff: f32,
) -> Result<CollisionOutput, String> {
    if point_count <= 0 {
        return Err("Gaussian resource contains no splats.".into());
    }
    let point_count = usize::try_from(point_count).map_err(|_| "Invalid point_count.")?;
    if point_count > HARD_MAX_SPLATS {
        return Err(format!(
            "Gaussian resource has {point_count} splats; the safety limit is {HARD_MAX_SPLATS}."
        ));
    }
    let expected_bytes = point_count
        .checked_mul(BYTES_PER_SPLAT)
        .ok_or("Gaussian byte count overflowed.")?;
    if point_data.len() != expected_bytes {
        return Err(format!(
            "point_data has {} bytes; expected {point_count} x {BYTES_PER_SPLAT} = {expected_bytes}.",
            point_data.len()
        ));
    }
    if !requested_voxel_size.is_finite() || requested_voxel_size < 0.0 {
        return Err("voxel_size must be zero (auto) or a finite positive number.".into());
    }
    if !opacity_cutoff.is_finite() || !(0.0..1.0).contains(&opacity_cutoff) || opacity_cutoff == 0.0
    {
        return Err("opacity_cutoff must be greater than 0 and less than 1.".into());
    }

    let sample_stride = point_count.div_ceil(MAX_SPLATS).max(1);
    let opacity_scale = sample_stride as f32;
    let mut splats = Vec::with_capacity(point_count.div_ceil(sample_stride));
    let mut skipped_splats = 0;

    for source_index in (0..point_count).step_by(sample_stride) {
        match prepare_splat(point_data, source_index, opacity_scale) {
            Some(splat) => splats.push(splat),
            None => skipped_splats += 1,
        }
    }
    if splats.is_empty() {
        return Err("No usable splats remain after covariance and opacity validation.".into());
    }

    // Some trained scenes contain a few finite but extremely distant points.
    // They are harmless to rendering but can enlarge a collision grid by
    // hundreds of times. Only activate robust clipping when the full span is
    // at least eight times a central 99.8% span, then retain a generous 25%
    // margin. Normal assets therefore keep every valid splat unchanged.
    let position_outliers = filter_extreme_position_outliers(&mut splats);
    skipped_splats += position_outliers;
    if splats.is_empty() {
        return Err("No splats remain after position-outlier filtering.".into());
    }

    let mut bounds_min = [f32::INFINITY; 3];
    let mut bounds_max = [f32::NEG_INFINITY; 3];
    for splat in &splats {
        for axis in 0..3 {
            bounds_min[axis] = bounds_min[axis].min(splat.position[axis] - splat.extent[axis]);
            bounds_max[axis] = bounds_max[axis].max(splat.position[axis] + splat.extent[axis]);
        }
    }

    let longest_axis = (0..3)
        .map(|axis| bounds_max[axis] - bounds_min[axis])
        .fold(0.0_f32, f32::max);
    if !longest_axis.is_finite() || longest_axis <= 0.0 {
        return Err("Gaussian 3-sigma bounds are empty or invalid.".into());
    }
    let voxel_size = if requested_voxel_size == 0.0 {
        (longest_axis / AUTO_VOXELS_ON_LONGEST_AXIS).clamp(MIN_VOXEL_SIZE, MAX_VOXEL_SIZE)
    } else {
        requested_voxel_size
    };
    if voxel_size <= 0.0 {
        return Err("voxel_size must be positive.".into());
    }

    let block_world_size = voxel_size * 4.0;
    let mut origin = [0.0; 3];
    let mut dimensions = [0_usize; 3];
    for axis in 0..3 {
        origin[axis] = (bounds_min[axis] / block_world_size).floor() * block_world_size;
        let end = (bounds_max[axis] / block_world_size).ceil() * block_world_size;
        dimensions[axis] = (((end - origin[axis]) / voxel_size).round() as usize).max(4);
        if dimensions[axis] > MAX_GRID_AXIS {
            return Err(format!(
                "Voxel grid axis {:?} exceeds the safety limit {MAX_GRID_AXIS}; increase voxel_size.",
                dimensions
            ));
        }
    }
    let grid_len = dimensions
        .into_iter()
        .try_fold(1_usize, |value, axis| value.checked_mul(axis))
        .ok_or("Voxel grid size overflowed.")?;
    if grid_len > MAX_GRID_VOXELS {
        return Err(format!(
            "Voxel grid {:?} contains {grid_len} voxels; the safety limit is {MAX_GRID_VOXELS}. Increase voxel_size.",
            dimensions
        ));
    }

    let mut density = vec![0.0_f32; grid_len];
    let mut evaluations = 0_u64;
    for splat in &splats {
        let mut voxel_min = [0_usize; 3];
        let mut voxel_max = [0_usize; 3];
        for axis in 0..3 {
            voxel_min[axis] = (((splat.position[axis] - splat.extent[axis] - origin[axis])
                / voxel_size)
                .floor() as isize)
                .clamp(0, dimensions[axis] as isize - 1) as usize;
            voxel_max[axis] = (((splat.position[axis] + splat.extent[axis] - origin[axis])
                / voxel_size)
                .floor() as isize)
                .clamp(0, dimensions[axis] as isize - 1) as usize;
        }
        let range_len = (voxel_max[0] - voxel_min[0] + 1) as u64
            * (voxel_max[1] - voxel_min[1] + 1) as u64
            * (voxel_max[2] - voxel_min[2] + 1) as u64;
        evaluations = evaluations.saturating_add(range_len);
        if evaluations > MAX_VOXEL_EVALUATIONS {
            return Err(format!(
                "Gaussian-to-voxel evaluations exceed the safety limit ({MAX_VOXEL_EVALUATIONS}); increase voxel_size."
            ));
        }

        for z in voxel_min[2]..=voxel_max[2] {
            let dz = closest_delta(
                splat.position[2],
                origin[2] + z as f32 * voxel_size,
                voxel_size,
            );
            for y in voxel_min[1]..=voxel_max[1] {
                let dy = closest_delta(
                    splat.position[1],
                    origin[1] + y as f32 * voxel_size,
                    voxel_size,
                );
                for x in voxel_min[0]..=voxel_max[0] {
                    let index = grid_index(x, y, z, dimensions);
                    if density[index] >= MAX_SIGMA {
                        continue;
                    }
                    let dx = closest_delta(
                        splat.position[0],
                        origin[0] + x as f32 * voxel_size,
                        voxel_size,
                    );
                    let inv = splat.inverse;
                    let mut distance_squared = inv[0] * dx * dx
                        + inv[3] * dy * dy
                        + inv[5] * dz * dz
                        + 2.0 * (inv[1] * dx * dy + inv[2] * dx * dz + inv[4] * dy * dz);
                    if distance_squared < 0.0 && distance_squared > -1.0e-5 {
                        distance_squared = 0.0;
                    }
                    if distance_squared >= 0.0 && distance_squared.is_finite() {
                        density[index] = (density[index]
                            + splat.opacity * (-0.5 * distance_squared).exp())
                        .min(MAX_SIGMA);
                    }
                }
            }
        }
    }

    let sigma_threshold = -(1.0 - opacity_cutoff).ln();
    let occupied: Vec<u8> = density
        .into_iter()
        .map(|value| u8::from(value >= sigma_threshold))
        .collect();
    let (occupied, removed_voxels) = cleanup_isolated(&occupied, dimensions);
    let occupied_voxels = occupied.iter().map(|&value| value as usize).sum();
    if occupied_voxels == 0 {
        return Err(
            "Voxelization produced no connected solid voxels; lower opacity_cutoff or voxel_size."
                .into(),
        );
    }

    let (faces, quads) = greedy_mesh(&occupied, dimensions, origin, voxel_size)?;
    let triangles = faces.len() / 3;
    Ok(CollisionOutput {
        faces,
        stats: CollisionStats {
            input_splats: point_count,
            sample_stride,
            valid_splats: splats.len(),
            skipped_splats,
            position_outliers,
            voxel_size,
            grid_dimensions: dimensions,
            occupied_voxels,
            removed_voxels,
            quads,
            triangles,
        },
    })
}

fn filter_extreme_position_outliers(splats: &mut Vec<PreparedSplat>) -> usize {
    if splats.len() < ROBUST_BOUNDS_MIN_SPLATS {
        return 0;
    }

    let sample_stride = splats.len().div_ceil(ROBUST_BOUNDS_MAX_SAMPLES).max(1);
    let mut samples = [Vec::new(), Vec::new(), Vec::new()];
    let mut raw_min = [f32::INFINITY; 3];
    let mut raw_max = [f32::NEG_INFINITY; 3];
    for (index, splat) in splats.iter().enumerate() {
        for axis in 0..3 {
            raw_min[axis] = raw_min[axis].min(splat.position[axis]);
            raw_max[axis] = raw_max[axis].max(splat.position[axis]);
            if index % sample_stride == 0 {
                samples[axis].push(splat.position[axis]);
            }
        }
    }
    for values in &mut samples {
        values.sort_unstable_by(f32::total_cmp);
    }

    let sample_count = samples[0].len();
    let lower_index = ((sample_count - 1) as f32 * ROBUST_BOUNDS_QUANTILE).floor() as usize;
    let upper_index = ((sample_count - 1) as f32 * (1.0 - ROBUST_BOUNDS_QUANTILE)).ceil() as usize;
    let mut filter_min = [0.0; 3];
    let mut filter_max = [0.0; 3];
    let mut has_extreme_span = false;
    for axis in 0..3 {
        let lower = samples[axis][lower_index];
        let upper = samples[axis][upper_index];
        let robust_span = (upper - lower).max(1.0e-3);
        let raw_span = raw_max[axis] - raw_min[axis];
        has_extreme_span |= raw_span > robust_span * OUTLIER_SPAN_RATIO;
        let padding = robust_span * ROBUST_BOUNDS_PADDING;
        filter_min[axis] = lower - padding;
        filter_max[axis] = upper + padding;
    }
    if !has_extreme_span {
        return 0;
    }

    let original_len = splats.len();
    splats.retain(|splat| {
        (0..3).all(|axis| {
            splat.position[axis] >= filter_min[axis] && splat.position[axis] <= filter_max[axis]
        })
    });
    original_len - splats.len()
}

fn prepare_splat(bytes: &[u8], index: usize, opacity_scale: f32) -> Option<PreparedSplat> {
    let base = index * FLOATS_PER_SPLAT;
    let read = |float_index: usize| -> f32 {
        let byte_index = (base + float_index) * 4;
        f32::from_le_bytes(bytes[byte_index..byte_index + 4].try_into().unwrap())
    };
    let position = [read(0), read(1), read(2)];
    let xx = read(4);
    let xy = read(5);
    let xz = read(6);
    let yy = read(7);
    let yz = read(8);
    let zz = read(9);
    let opacity = read(10);
    let values = [
        position[0],
        position[1],
        position[2],
        xx,
        xy,
        xz,
        yy,
        yz,
        zz,
        opacity,
    ];
    if values.iter().any(|value| !value.is_finite())
        || xx < 0.0
        || yy < 0.0
        || zz < 0.0
        || opacity <= 0.0
    {
        return None;
    }

    let extent = [3.0 * xx.sqrt(), 3.0 * yy.sqrt(), 3.0 * zz.sqrt()];
    let covariance_scale = xx.max(yy).max(zz).max(REGULARIZATION_ABSOLUTE);
    let epsilon = covariance_scale * REGULARIZATION_RELATIVE + REGULARIZATION_ABSOLUTE;
    let a = xx + epsilon;
    let d = yy + epsilon;
    let f = zz + epsilon;
    let determinant = a * (d * f - yz * yz) - xy * (xy * f - xz * yz) + xz * (xy * yz - xz * d);
    let determinant_scale = (covariance_scale * covariance_scale * covariance_scale).max(1.0e-36);
    if a * d - xy * xy <= 0.0
        || !determinant.is_finite()
        || determinant <= determinant_scale * 1.0e-12
    {
        return None;
    }
    let inverse = [
        (d * f - yz * yz) / determinant,
        (xz * yz - xy * f) / determinant,
        (xy * yz - xz * d) / determinant,
        (a * f - xz * xz) / determinant,
        (xy * xz - a * yz) / determinant,
        (a * d - xy * xy) / determinant,
    ];
    if inverse.iter().any(|value| !value.is_finite()) {
        return None;
    }
    Some(PreparedSplat {
        position,
        inverse,
        extent,
        opacity: opacity.clamp(0.0, 1.0) * opacity_scale,
    })
}

fn closest_delta(center: f32, voxel_min: f32, voxel_size: f32) -> f32 {
    center.clamp(voxel_min, voxel_min + voxel_size) - center
}

fn grid_index(x: usize, y: usize, z: usize, dimensions: [usize; 3]) -> usize {
    x + y * dimensions[0] + z * dimensions[0] * dimensions[1]
}

fn solid(grid: &[u8], x: isize, y: isize, z: isize, dimensions: [usize; 3]) -> bool {
    if x < 0
        || y < 0
        || z < 0
        || x >= dimensions[0] as isize
        || y >= dimensions[1] as isize
        || z >= dimensions[2] as isize
    {
        return false;
    }
    grid[grid_index(x as usize, y as usize, z as usize, dimensions)] != 0
}

fn cleanup_isolated(grid: &[u8], dimensions: [usize; 3]) -> (Vec<u8>, usize) {
    let neighbors = [
        [-1, 0, 0],
        [1, 0, 0],
        [0, -1, 0],
        [0, 1, 0],
        [0, 0, -1],
        [0, 0, 1],
    ];
    let mut cleaned = vec![0_u8; grid.len()];
    let mut removed = 0;
    for z in 0..dimensions[2] {
        for y in 0..dimensions[1] {
            for x in 0..dimensions[0] {
                let index = grid_index(x, y, z, dimensions);
                let was_solid = grid[index] != 0;
                let mut any_neighbor = false;
                let mut all_neighbors = true;
                for offset in neighbors {
                    let neighbor = solid(
                        grid,
                        x as isize + offset[0],
                        y as isize + offset[1],
                        z as isize + offset[2],
                        dimensions,
                    );
                    any_neighbor |= neighbor;
                    all_neighbors &= neighbor;
                }
                let is_solid = (was_solid && any_neighbor) || (!was_solid && all_neighbors);
                cleaned[index] = u8::from(is_solid);
                removed += usize::from(was_solid && !is_solid);
            }
        }
    }
    (cleaned, removed)
}

fn greedy_mesh(
    grid: &[u8],
    dimensions: [usize; 3],
    origin: [f32; 3],
    voxel_size: f32,
) -> Result<(Vec<[f32; 3]>, usize), String> {
    let mut faces = Vec::new();
    let mut quads = 0_usize;
    for axis in 0..3 {
        let u_axis = (axis + 1) % 3;
        let v_axis = (axis + 2) % 3;
        let u_len = dimensions[u_axis];
        let v_len = dimensions[v_axis];
        let mut mask = vec![0_i8; u_len * v_len];
        for plane in 0..=dimensions[axis] {
            for v in 0..v_len {
                for u in 0..u_len {
                    let mut negative = [0_isize; 3];
                    negative[axis] = plane as isize - 1;
                    negative[u_axis] = u as isize;
                    negative[v_axis] = v as isize;
                    let mut positive = negative;
                    positive[axis] += 1;
                    let negative_solid =
                        solid(grid, negative[0], negative[1], negative[2], dimensions);
                    let positive_solid =
                        solid(grid, positive[0], positive[1], positive[2], dimensions);
                    mask[u + v * u_len] = match (negative_solid, positive_solid) {
                        (true, false) => 1,
                        (false, true) => -1,
                        _ => 0,
                    };
                }
            }

            let mut v = 0;
            while v < v_len {
                let mut u = 0;
                while u < u_len {
                    let sign = mask[u + v * u_len];
                    if sign == 0 {
                        u += 1;
                        continue;
                    }
                    let mut width = 1;
                    while u + width < u_len && mask[u + width + v * u_len] == sign {
                        width += 1;
                    }
                    let mut height = 1;
                    'grow: while v + height < v_len {
                        for du in 0..width {
                            if mask[u + du + (v + height) * u_len] != sign {
                                break 'grow;
                            }
                        }
                        height += 1;
                    }
                    for dv in 0..height {
                        for du in 0..width {
                            mask[u + du + (v + dv) * u_len] = 0;
                        }
                    }
                    quads += 1;
                    if quads > MAX_QUADS {
                        return Err(format!(
                            "Greedy collision surface exceeds {MAX_QUADS} quads; increase voxel_size."
                        ));
                    }
                    append_quad(
                        &mut faces, axis, u_axis, v_axis, plane, u, v, width, height, sign, origin,
                        voxel_size,
                    );
                    u += width;
                }
                v += 1;
            }
        }
    }
    if faces.is_empty() {
        return Err("Voxelization produced no exposed collision surface.".into());
    }
    Ok((faces, quads))
}

#[allow(clippy::too_many_arguments)]
fn append_quad(
    faces: &mut Vec<[f32; 3]>,
    axis: usize,
    u_axis: usize,
    v_axis: usize,
    plane: usize,
    u: usize,
    v: usize,
    width: usize,
    height: usize,
    sign: i8,
    origin: [f32; 3],
    voxel_size: f32,
) {
    let mut a = [0.0_f32; 3];
    let mut b = [0.0_f32; 3];
    let mut c = [0.0_f32; 3];
    let mut d = [0.0_f32; 3];
    for point in [&mut a, &mut b, &mut c, &mut d] {
        point[axis] = plane as f32;
    }
    a[u_axis] = u as f32;
    a[v_axis] = v as f32;
    b[u_axis] = (u + width) as f32;
    b[v_axis] = v as f32;
    c[u_axis] = (u + width) as f32;
    c[v_axis] = (v + height) as f32;
    d[u_axis] = u as f32;
    d[v_axis] = (v + height) as f32;
    for point in [&mut a, &mut b, &mut c, &mut d] {
        for component in 0..3 {
            point[component] = origin[component] + point[component] * voxel_size;
        }
    }
    if sign > 0 {
        faces.extend_from_slice(&[a, b, c, a, c, d]);
    } else {
        faces.extend_from_slice(&[a, d, c, a, c, b]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::splat::{SH_FLOATS_PER_SPLAT, SplatRecord};

    #[test]
    fn one_gaussian_builds_a_non_empty_collision_surface() {
        let record = SplatRecord::from_components(
            [0.0, 0.0, 0.0],
            [0.04, 0.0, 0.0, 0.04, 0.0, 0.04],
            1.0,
            [0.0; SH_FLOATS_PER_SPLAT],
        );
        let output = generate_collision(&record.to_le_bytes(), 1, 0.1, 0.1).unwrap();
        assert!(output.stats.occupied_voxels > 0);
        assert!(output.stats.triangles > 0);
        assert_eq!(output.faces.len(), output.stats.triangles * 3);
    }

    #[test]
    fn collision_rejects_an_inconsistent_byte_count() {
        let error = generate_collision(&[], 1, 0.1, 0.1).unwrap_err();
        assert!(error.contains("expected"));
    }

    #[test]
    fn collision_ignores_a_tiny_population_of_extreme_position_outliers() {
        let mut bytes = Vec::new();
        for index in 0..2_000 {
            let x = -10.0 + index as f32 * 0.01;
            bytes.extend_from_slice(
                &SplatRecord::from_components(
                    [x, 0.0, 0.0],
                    [0.04, 0.0, 0.0, 0.04, 0.0, 0.04],
                    1.0,
                    [0.0; SH_FLOATS_PER_SPLAT],
                )
                .to_le_bytes(),
            );
        }
        bytes.extend_from_slice(
            &SplatRecord::from_components(
                [20_000.0, 0.0, 0.0],
                [0.04, 0.0, 0.0, 0.04, 0.0, 0.04],
                1.0,
                [0.0; SH_FLOATS_PER_SPLAT],
            )
            .to_le_bytes(),
        );

        let output = generate_collision(&bytes, 2_001, 0.2, 0.1).unwrap();
        assert_eq!(output.stats.position_outliers, 1);
        assert!(output.stats.grid_dimensions[0] < 4096);
    }
}
