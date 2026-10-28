"""A tiny Blender add-on script: the case for Blender Python checks."""

import bpy


def nudge_all(dx: float) -> int:
    count = 0
    for obj in bpy.data.objects:
        obj.location.x += dx
        count += 1
    return count


def rename_all(prefix: str) -> None:
    for obj in bpy.data.objects:
        obj.name = prefix + obj.name
