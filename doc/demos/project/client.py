from cache import MemoryCache
from transport import HttpTransport


class ApiClient:
    def __init__(self, base_url):
        self.cache = MemoryCache()
        self.transport = HttpTransport(base_url)

    def fetch(self, key):
        cached = self.cache.get(key)
        if cached is not None:
            return cached

        result = self.transport.get(key)
        self.cache.put(key, result)
        return result

    def invalidate(self, key):
        self.cache.delete(key)
