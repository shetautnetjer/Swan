"""match_path, as SolidLSP's ls.py calls it: is this path matched by the ignore spec?"""
import os


def match_path(relative_path, path_spec, root_path="", is_dir=None):
    path = str(relative_path).replace(os.sep, "/")
    if is_dir is None:
        is_dir = os.path.isdir(os.path.join(root_path, path))
    if is_dir and not path.endswith("/"):
        path += "/"
    return bool(path_spec.match_file(path))
