"""Living-background drift for the minimal hero language.

Three motions, all on closed circles so any loop length is mathematically
seamless:

1. Translation drift: the noise field slides slowly (two layers,
   counter-rotating circles in texture space).
2. Evolution churn: each noise layer's sample point also moves on a circle
   through the card's unused dimensions (generated-Y and 4D W), so the
   PATTERN morphs organically in place — this is what reads as "alive".
3. Breathing: a very large-scale 4D noise layer slowly modulates overall
   backdrop luminance a few percent, like darkness gently rolling.
"""

from __future__ import annotations

import math

import bpy


def animate_backdrop_drift(
    loop_frames: int,
    radius: float,
    loops: float,
    contrast: float,
    evolve_radius: float = 0.6,
    breathe_amount: float = 0.15,
    key_step: int = 5,
) -> None:
    mat = bpy.data.materials["NB_BackdropMat"]
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    tex_coord = next(n for n in nodes if n.type == "TEX_COORD")
    noise = next(n for n in nodes if n.type == "TEX_NOISE")
    mixf = next(n for n in nodes if n.type == "MIX" and n.data_type == "FLOAT")
    emit = next(n for n in nodes if n.type == "EMISSION")
    zfade = next(
        n for n in nodes
        if n.type == "MAP_RANGE" and abs(n.inputs["From Max"].default_value - 0.22) < 1e-4
    )

    mixf.inputs["Factor"].default_value = min(0.85, 0.55 * contrast)

    # Layer 2 (finer counter-drifting noise).
    noise2 = nodes.new("ShaderNodeTexNoise")
    noise2.inputs["Scale"].default_value = 3.6
    noise2.inputs["Detail"].default_value = 5.0
    layer_mix = nodes.new("ShaderNodeMix")
    layer_mix.data_type = "FLOAT"
    layer_mix.inputs["Factor"].default_value = 0.4
    links.new(noise.outputs["Fac"], layer_mix.inputs["A"])
    links.new(noise2.outputs["Fac"], layer_mix.inputs["B"])
    links.new(layer_mix.outputs["Result"], mixf.inputs["B"])

    # 4D evolution on both layers.
    for n in (noise, noise2):
        n.noise_dimensions = "4D"

    drift1 = nodes.new("ShaderNodeMapping")
    links.new(tex_coord.outputs["Generated"], drift1.inputs["Vector"])
    links.new(drift1.outputs["Vector"], noise.inputs["Vector"])
    drift2 = nodes.new("ShaderNodeMapping")
    links.new(tex_coord.outputs["Generated"], drift2.inputs["Vector"])
    links.new(drift2.outputs["Vector"], noise2.inputs["Vector"])

    # Breathing layer: huge, slow, modulates emission strength via zfade.
    breathe = nodes.new("ShaderNodeTexNoise")
    breathe.noise_dimensions = "4D"
    breathe.inputs["Scale"].default_value = 0.9
    breathe.inputs["Detail"].default_value = 2.0
    breathe_drift = nodes.new("ShaderNodeMapping")
    breathe_map = nodes.new("ShaderNodeMapRange")
    breathe_map.inputs["To Min"].default_value = 1.0 - breathe_amount
    breathe_map.inputs["To Max"].default_value = 1.0 + breathe_amount
    breathe_mul = nodes.new("ShaderNodeMath")
    breathe_mul.operation = "MULTIPLY"
    links.new(tex_coord.outputs["Generated"], breathe_drift.inputs["Vector"])
    links.new(breathe_drift.outputs["Vector"], breathe.inputs["Vector"])
    links.new(breathe.outputs["Fac"], breathe_map.inputs["Value"])
    links.new(zfade.outputs["Result"], breathe_mul.inputs[0])
    links.new(breathe_map.outputs["Result"], breathe_mul.inputs[1])
    links.new(breathe_mul.outputs["Value"], emit.inputs["Strength"])

    def key_circle(socket_owner, w_socket, mapping, rad, ev_rad, phase, direction, cycles):
        # Circles only close at the loop boundary for INTEGER cycle counts;
        # state energy is expressed through radius, not fractional speed.
        cycles = max(1, round(cycles))
        for frame in range(1, loop_frames + 2, key_step):
            t = direction * 2 * math.pi * cycles * (frame - 1) / loop_frames + phase
            if mapping is not None:
                mapping.inputs["Location"].default_value = (
                    rad * math.cos(t),
                    ev_rad * math.cos(t * 1.0 + 1.3),  # unused card dim: evolution
                    rad * math.sin(t),
                )
                mapping.inputs["Location"].keyframe_insert("default_value", frame=frame)
            if w_socket is not None:
                w_socket.default_value = ev_rad * math.sin(t + 1.3)
                w_socket.keyframe_insert("default_value", frame=frame)

    key_circle(noise, noise.inputs["W"], drift1, radius, evolve_radius, 0.0, 1.0, max(loops, 0.05))
    key_circle(noise2, noise2.inputs["W"], drift2, radius * 0.6, evolve_radius * 0.75, 2.1, -1.0, max(loops, 0.05))
    # Breathing: two slow cycles per loop regardless of state energy.
    key_circle(breathe, breathe.inputs["W"], breathe_drift, 0.0, evolve_radius * 0.4, 0.7, 1.0, 2.0)
