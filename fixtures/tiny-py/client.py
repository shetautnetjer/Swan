"""Uses an outside package, so Swan must name it by package and version."""

import requests


def fetch_status(url: str) -> int:
    response: requests.Response = requests.get(url, timeout=5)
    return response.status_code
