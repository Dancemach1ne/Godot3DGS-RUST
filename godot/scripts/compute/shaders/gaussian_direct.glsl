#[compute]
#version 460

// Compute smoke renderer: one invocation per pixel. It deliberately performs
// an O(pixels * splats) direct loop so that the CompositorEffect/RenderingDevice
// path is proved before the tile/sort pipeline is introduced.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D scene_color;
layout(std430, set = 0, binding = 1) readonly buffer SplatBuffer { vec4 records[]; };
layout(std140, set = 0, binding = 2) uniform CameraData {
	mat4 view_matrix;
	mat4 projection_matrix;
	vec4 camera_world;
	ivec4 params; // width, height, point_count, padding
};

const int TEXELS_PER_SPLAT = 15;
const float SH_C0 = 0.28209479177387814;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (pixel.x >= params.x || pixel.y >= params.y) { return; }
	vec4 original = imageLoad(scene_color, pixel);
	vec3 color = vec3(0.0);
	float transmittance = 1.0;

	for (int index = 0; index < params.z && transmittance > 0.003; index++) {
		int base = index * TEXELS_PER_SPLAT;
		vec4 t0 = records[base];
		vec4 t1 = records[base + 1];
		vec4 t2 = records[base + 2];
		vec4 dc = records[base + 3];
		vec4 clip = projection_matrix * view_matrix * vec4(t0.xyz, 1.0);
		if (clip.w <= 0.0) { continue; }
		vec2 center = (clip.xy / clip.w * 0.5 + 0.5) * vec2(params.xy);
		// Conservative isotropic screen radius for the baseline. The tile pass
		// will replace this with the full projected 2D covariance ellipse.
		float variance = max(1e-6, (t1.x + t1.w + t2.y) / 3.0);
		float radius = max(1.0, sqrt(variance) * abs(projection_matrix[1][1]) * float(params.y) * 0.5 / max(0.001, clip.w));
		vec2 delta = (vec2(pixel) + vec2(0.5) - center) / radius;
		float alpha = clamp(t2.z, 0.0, 1.0) * exp(-0.5 * dot(delta, delta));
		if (alpha < 1.0 / 255.0) { continue; }
		vec3 splat_color = max(vec3(0.0), vec3(0.5) + dc.rgb * SH_C0);
		color += splat_color * alpha * transmittance;
		transmittance *= 1.0 - alpha;
	}
	float alpha = 1.0 - transmittance;
	imageStore(scene_color, pixel, vec4(mix(original.rgb, color, alpha), original.a));
}
