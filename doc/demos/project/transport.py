from time import sleep

import requests
from requests.exceptions import Timeout


class HttpTransport:
    def __init__(self, base_url):
        self.base_url = base_url

    def get(self, path):
        for attempt in range(3):
            try:
                response = requests.get(
                    self.base_url + path, timeout=5
                )
                response.raise_for_status()
                return response.json()
            except Timeout:
                if attempt == 2:
                    raise
                sleep(0.1 * (attempt + 1))
