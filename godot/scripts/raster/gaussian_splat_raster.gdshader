shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled, fog_disabled, specular_disabled, ambient_light_disabled;

uniform sampler2D splat_data : filter_nearest, repeat_disable;
uniform int data_width = 15;
uniform int point_count = 0;
uniform sampler2D order_data : filter_nearest, repeat_disable;
uniform int order_width = 1;
uniform bool use_order = false;
uniform float quad_extent = 3.0;
uniform float alpha_cutoff = 0.00392;

const int TEXELS_PER_SPLAT = 15;
const float SH_C0 = 0.28209479177387814;
const float SH_C1 = 0.4886025119029199;
const float SH_C2_0 = 1.0925484305920792;
const float SH_C2_2 = 0.31539156525252005;
const float SH_C2_4 = 0.5462742152960396;
const float SH_C3_0 = 0.5900435899266435;
const float SH_C3_1 = 2.890611442640554;
const float SH_C3_2 = 0.4570457994644658;
const float SH_C3_3 = 0.3731763325901154;
const float SH_C3_4 = 0.4570457994644658;
const float SH_C3_5 = 1.445305721320277;
const float SH_C3_6 = 0.5900435899266435;
varying flat vec4 v_color;
varying vec2 v_t;

vec4 fetch_data(int texel) {
	return texelFetch(splat_data, ivec2(texel % data_width, texel / data_width), 0);
}

// 16 SH bases x RGB. The PLY decoder has already rearranged f_rest values
// into this RGB-interleaved order.
vec3 eval_sh(vec3 direction, float c[48]) {
	float x = direction.x, y = direction.y, z = direction.z;
	float xx = x * x, yy = y * y, zz = z * z;
	float xy = x * y, yz = y * z, xz = x * z;
	vec3 rgb = vec3(0.5)
		+ vec3(c[0], c[1], c[2]) * SH_C0
		- vec3(c[3], c[4], c[5]) * SH_C1 * y
		+ vec3(c[6], c[7], c[8]) * SH_C1 * z
		- vec3(c[9], c[10], c[11]) * SH_C1 * x
		+ vec3(c[12], c[13], c[14]) * SH_C2_0 * xy
		- vec3(c[15], c[16], c[17]) * SH_C2_0 * yz
		+ vec3(c[18], c[19], c[20]) * SH_C2_2 * (2.0 * zz - xx - yy)
		- vec3(c[21], c[22], c[23]) * SH_C2_0 * xz
		+ vec3(c[24], c[25], c[26]) * SH_C2_4 * (xx - yy)
		- vec3(c[27], c[28], c[29]) * SH_C3_0 * y * (3.0 * xx - yy)
		+ vec3(c[30], c[31], c[32]) * SH_C3_1 * x * yz
		- vec3(c[33], c[34], c[35]) * SH_C3_2 * y * (4.0 * zz - xx - yy)
		+ vec3(c[36], c[37], c[38]) * SH_C3_3 * z * (2.0 * zz - 3.0 * xx - 3.0 * yy)
		- vec3(c[39], c[40], c[41]) * SH_C3_4 * x * (4.0 * zz - xx - yy)
		+ vec3(c[42], c[43], c[44]) * SH_C3_5 * z * (xx - yy)
		- vec3(c[45], c[46], c[47]) * SH_C3_6 * x * (xx - 3.0 * yy);
	return max(vec3(0.0), rgb);
}

void vertex() {
	POSITION = vec4(2.0, 2.0, 2.0, 1.0);
	v_color = vec4(0.0);
	v_t = vec2(0.0);
	int index = INSTANCE_ID;
	if (index < point_count) {
		int splat_index = index;
		if (use_order) {
			splat_index = int(texelFetch(order_data, ivec2(index % order_width, index / order_width), 0).r + 0.5);
		}
		int base = splat_index * TEXELS_PER_SPLAT;
		vec4 t0 = fetch_data(base);
		vec4 t1 = fetch_data(base + 1);
		vec4 t2 = fetch_data(base + 2);
		vec4 dc = fetch_data(base + 3);
		float opacity = clamp(t2.z, 0.0, 1.0);
		vec4 world_pos = MODEL_MATRIX * vec4(t0.xyz, 1.0);
		vec4 view_pos = VIEW_MATRIX * world_pos;
		vec4 clip_pos = PROJECTION_MATRIX * view_pos;
		if (view_pos.z < -0.0001 && clip_pos.w > 0.0 && opacity > alpha_cutoff) {
			mat3 cov3d = mat3(vec3(t1.x, t1.y, t1.z), vec3(t1.y, t1.w, t2.x), vec3(t1.z, t2.x, t2.y));
			mat3 object_linear = mat3(MODEL_MATRIX[0].xyz, MODEL_MATRIX[1].xyz, MODEL_MATRIX[2].xyz);
			mat3 world_cov = object_linear * cov3d * transpose(object_linear);
			vec2 fov_inv = vec2(PROJECTION_MATRIX[0][0], PROJECTION_MATRIX[1][1]);
			vec2 focal = (VIEWPORT_SIZE - 1.0) * 0.5 * fov_inv * (-1.0 / view_pos.z);
			vec2 tan_fov = 1.0 / abs(fov_inv);
			vec2 m = clamp(view_pos.xy * (-1.0 / view_pos.z), -tan_fov * 1.3, tan_fov * 1.3);
			mat3 view_linear = mat3(VIEW_MATRIX[0].xyz, VIEW_MATRIX[1].xyz, VIEW_MATRIX[2].xyz);
			mat3 jacobian = mat3(vec3(focal.x, 0.0, 0.0), vec3(0.0, focal.y, 0.0), vec3(focal.x * m.x, focal.y * m.y, 0.0));
			mat3 screen = jacobian * view_linear;
			mat3 cov2d_m = screen * world_cov * transpose(screen);
			vec3 cov2d = vec3(cov2d_m[0][0] + 0.3, cov2d_m[0][1], cov2d_m[1][1] + 0.3);
			float det = cov2d.x * cov2d.z - cov2d.y * cov2d.y;
			if (det > 0.0) {
				float mid = 0.5 * (cov2d.x + cov2d.z);
				float delta = sqrt(max(0.0, mid * mid - det));
				float lambda1 = mid + delta;
				float lambda2 = max(mid - delta, 0.0);
				vec2 e1 = abs(cov2d.y) < 1e-6 ? (cov2d.x >= cov2d.z ? vec2(1.0, 0.0) : vec2(0.0, 1.0)) : normalize(vec2(cov2d.y, lambda1 - cov2d.x));
				vec2 e2 = vec2(-e1.y, e1.x);
				float extent = min(quad_extent, sqrt(2.0 * log(max(opacity, alpha_cutoff) / alpha_cutoff)));
				vec2 offset = VERTEX.x * extent * sqrt(lambda1) * e1 + VERTEX.y * extent * sqrt(lambda2) * e2;
				vec4 result = clip_pos;
				result.xy += offset * 2.0 / VIEWPORT_SIZE * clip_pos.w;
				POSITION = result;
				v_t = VERTEX.xy * extent;
				float c[48];
				for (int texel = 0; texel < 12; texel++) {
					vec4 coefficients = fetch_data(base + 3 + texel);
					c[texel * 4] = coefficients.x;
					c[texel * 4 + 1] = coefficients.y;
					c[texel * 4 + 2] = coefficients.z;
					c[texel * 4 + 3] = coefficients.w;
				}
				vec3 view_direction = normalize(inverse(object_linear) * (world_pos.xyz - CAMERA_POSITION_WORLD));
				v_color = vec4(eval_sh(view_direction, c), opacity);
			}
		}
	}
}

void fragment() {
	float alpha = v_color.a * exp(-0.5 * dot(v_t, v_t));
	if (alpha < alpha_cutoff) { discard; }
	ALBEDO = v_color.rgb;
	ALPHA = alpha;
}
