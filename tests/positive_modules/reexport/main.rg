# Re-export: qualified calls / from-import functions / from-import types are all reachable
import os
import api
from api import Point

def main() {
    if api.hello() != "hi" {
        os.exit(1)
    }
    p = Point()
    p.x = 3
    p.y = 4
    if p.x + p.y != 7 {
        os.exit(1)
    }
}
